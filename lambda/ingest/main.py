import os, csv, io, sys, json, time
import boto3
from db import get_conn

def log(msg, **kw):
    print(json.dumps({"t": time.time(), "level": "INFO", "msg": msg, **kw}))
    sys.stdout.flush()

TABLE = os.getenv("TABLE_NAME", "aggregated_city_stats")
BUCKET = os.getenv("BUCKET_NAME")
ALLOWED_CITIES = None  # or set a list if you want strict allowlist

def _clean_price(val):
    if val in (None, "", "NULL"): return None
    # handle "1,234.56" and EU decimal commas like "6,81"
    s = str(val).strip()
    if s.count(",") == 1 and s.count(".") == 0:
        s = s.replace(",", ".")
    else:
        s = s.replace(",", "")
    try:
        x = float(s)
        if x < 0 or x > 10000:  # sanity bounds
            return None
        return x
    except: 
        return None

def _normalize_city(c):
    if c is None: return None
    c = str(c).strip()
    if not c: return None
    return c.title()  # "berlin" -> "Berlin", "new york" -> "New York"

def _validate_rows(rows):
    good, bad = [], []
    for r in rows:
        city = _normalize_city(r.get("city"))
        price = _clean_price(r.get("price"))
        if city is None: 
            bad.append({"reason":"missing_city", "row":r}); continue
        if ALLOWED_CITIES and city not in ALLOWED_CITIES:
            bad.append({"reason":"city_not_allowed", "row":r}); continue
        # price is optional per your spec; it's fine if None
        good.append({"city": city, "price": price})
    return good, bad

def _aggregate(rows):
    stats = {}
    for r in rows:
        city = (r.get("city") or "").strip()
        if not city: 
            continue
        price = r.get("price")
        try:
            price = float(price) if price not in (None, "", "NULL") else None
        except:
            price = None
        acc = stats.setdefault(city, {"count":0, "sum":0.0, "n":0})
        acc["count"] += 1
        if price is not None:
            acc["sum"] += price
            acc["n"] += 1
    out = []
    for city, v in stats.items():
        avg = (v["sum"]/v["n"]) if v["n"]>0 else None
        out.append((city, v["count"], avg))
    out.sort(key=lambda x: (-x[1], x[0]))
    return out

def _upsert(conn, rows):
    with conn.cursor() as cur:
        for city, cnt, avgp in rows:
            cur.execute(f"""
                INSERT INTO {TABLE}(city, listing_count, avg_price)
                VALUES (%s,%s,%s)
                ON CONFLICT (city) DO UPDATE SET
                  listing_count=EXCLUDED.listing_count,
                  avg_price=EXCLUDED.avg_price
            """, (city, cnt, avgp))

def handler(event, context):
    log("handler_start", event_keys=list(event.keys()))
    rec = event["Records"][0]
    bucket = rec["s3"]["bucket"]["name"]
    key = rec["s3"]["object"]["key"]

    log("s3_get_object_before", bucket=bucket, key=key)
    s3 = boto3.client("s3")
    obj = s3.get_object(Bucket=bucket, Key=key)
    log("s3_get_object_after", size=int(obj.get("ContentLength", 0)))

    body = obj["Body"].read()
    text = body.decode("utf-8")
    reader = csv.DictReader(io.StringIO(text))
    rows = list(reader)
    valid, invalid = _validate_rows(rows)
    data = _aggregate(valid)

    log("csv_parsed", rows=len(valid))

    log("db_connect_before")
    conn = get_conn()
    log("db_connect_after")

    _upsert(conn, data)
    with conn.cursor() as cur:
        cur.execute("ANALYZE aggregated_city_stats;")

    conn.close()
    log("done")
    return {"status": "ok"}


# Local runner
if __name__ == "__main__":
    # For local testing with MinIO
    os.environ.setdefault("AWS_ACCESS_KEY_ID", "minio")
    os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "minio123")
    os.environ.setdefault("AWS_ENDPOINT_URL", "http://localhost:9000")
    os.environ.setdefault("BUCKET_NAME", "nanlabs")
    import pandas as pd
    rows = pd.read_csv("../../examples/airbnb_listings_sample.csv").to_dict(orient="records")
    data = _aggregate(rows)
    conn = get_conn()
    _upsert(conn, data)
    conn.close()
    print("Upserted", len(data), "rows")

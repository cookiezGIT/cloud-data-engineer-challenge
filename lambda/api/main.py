import os, sys, json, time
from fastapi import FastAPI, Response, Query
from mangum import Mangum
from db import get_conn

def log(msg, **kw):
    print(json.dumps({"t": time.time(), "level": "INFO", "msg": msg, **kw}))
    sys.stdout.flush()

TABLE = os.getenv("TABLE_NAME", "aggregated_city_stats")

app = FastAPI(title="NanLabs Aggregated API")

@app.get("/healthz")
def healthz():
    return {"ok": True}

@app.get("/aggregated-data")
def aggregated_data(
    response: Response, 
    limit: int = Query(100, ge=1, le=1000), 
    city: str | None = None
):
    response.headers["Cache-Control"] = "public, max-age=60"
    conn = get_conn()
    try:
        with conn.cursor() as cur:
            if city:
                cur.execute(f"""
                    SELECT city, listing_count, avg_price
                    FROM {TABLE}
                    WHERE lower(city) = lower(%s)
                    ORDER BY listing_count DESC, city ASC
                    LIMIT %s
                """, (city, limit))
            else:
                cur.execute(f"""
                    SELECT city, listing_count, avg_price
                    FROM {TABLE}
                    ORDER BY listing_count DESC, city ASC
                    LIMIT %s
                """, (limit,))
            rows = cur.fetchall()
        return [{"city": r[0], "listing_count": int(r[1]), "avg_price": (float(r[2]) if r[2] is not None else None)} for r in rows]
    finally:
        conn.close()

handler = Mangum(app)

# Local
if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)

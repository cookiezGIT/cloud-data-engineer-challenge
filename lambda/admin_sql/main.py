import json, os, sys, time
import boto3
import psycopg2

def log(msg, **kw):
    print(json.dumps({"t": time.time(), "msg": msg, **kw}))
    sys.stdout.flush()

# Reuse your Secrets Manager layout (host,port,dbname,username,password)
def get_conn():
    sec_arn = os.environ["DB_SECRET_ARN"]
    sm = boto3.client("secretsmanager")
    sec = json.loads(sm.get_secret_value(SecretId=sec_arn)["SecretString"])
    conn = psycopg2.connect(
        host=sec["host"], port=sec["port"], dbname=sec["dbname"],
        user=sec["username"], password=sec["password"]
    )
    conn.autocommit = False
    return conn

SQL_DEDUPE_ENFORCE = """
BEGIN;
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS citext;

-- Deduplicate: collapse casing variants into Title Case with weighted avg
CREATE TEMP TABLE agg_dedup AS
SELECT
  INITCAP(LOWER(city)) AS city,
  SUM(listing_count)   AS listing_count,
  CASE
    WHEN SUM(CASE WHEN avg_price IS NOT NULL THEN listing_count ELSE 0 END) = 0
      THEN NULL
    ELSE SUM(COALESCE(avg_price,0) * listing_count)
         / NULLIF(SUM(CASE WHEN avg_price IS NOT NULL THEN listing_count ELSE 0 END),0)
  END AS avg_price,
  NULL::geometry(Point,4326) AS geom
FROM aggregated_city_stats
GROUP BY 1;

TRUNCATE aggregated_city_stats;

INSERT INTO aggregated_city_stats (city, listing_count, avg_price, geom)
SELECT city, listing_count, avg_price, geom
FROM agg_dedup;

-- Enforce future case-insensitive uniqueness
ALTER TABLE aggregated_city_stats
  DROP CONSTRAINT IF EXISTS aggregated_city_stats_pkey;

ALTER TABLE aggregated_city_stats
  ALTER COLUMN city TYPE CITEXT;

ALTER TABLE aggregated_city_stats
  ADD PRIMARY KEY (city);

-- Helpful indexes
CREATE INDEX IF NOT EXISTS idx_agg_count_city
  ON aggregated_city_stats (listing_count DESC, city ASC);

CREATE INDEX IF NOT EXISTS idx_agg_geom
  ON aggregated_city_stats USING GIST (geom);

ANALYZE aggregated_city_stats;
COMMIT;
"""

def handler(event, context):
    action = (event or {}).get("action", "dedupe_and_enforce_citext")
    if action != "dedupe_and_enforce_citext":
        return {"ok": False, "error": f"unknown action: {action}"}
    conn = get_conn()
    try:
        with conn.cursor() as cur:
            cur.execute(SQL_DEDUPE_ENFORCE)
        conn.commit()
        log("admin_sql_complete")
        return {"ok": True}
    except Exception as e:
        conn.rollback()
        log("admin_sql_error", error=str(e))
        return {"ok": False, "error": str(e)}
    finally:
        conn.close()

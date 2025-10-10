import os, json, psycopg2, sys, time

def _conn_params_from_env():
    host = os.getenv("DB_HOST")
    db   = os.getenv("DB_NAME")
    user = os.getenv("DB_USER")
    pwd  = os.getenv("DB_PASS")
    port = int(os.getenv("DB_PORT", "5432"))
    if not host:
        import boto3
        sm = boto3.client("secretsmanager")
        val = sm.get_secret_value(SecretId=os.environ["DB_SECRET_ID"])["SecretString"]
        js = json.loads(val)
        host = js["host"]; db = js["dbname"]; user = js["username"]; pwd = js["password"]; port = int(js["port"])
    return dict(host=host, database=db, user=user, password=pwd, port=port, connect_timeout=5)

def get_conn():
    p = _conn_params_from_env()
    print(json.dumps({"level":"INFO","msg":"psql_connect_try","host":p["host"],"port":p["port"],"db":p["database"]})); sys.stdout.flush()
    conn = psycopg2.connect(**p)
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute("CREATE EXTENSION IF NOT EXISTS postgis;")
        cur.execute("""
        CREATE TABLE IF NOT EXISTS aggregated_city_stats(
            city TEXT PRIMARY KEY,
            listing_count BIGINT NOT NULL,
            avg_price DOUBLE PRECISION NULL,
            geom geometry(Point,4326) NULL
        );
        """)
    return conn

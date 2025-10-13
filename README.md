# NanLabs Cloud Data Engineer Challenge — README

**Author:** Renzo Burga (cookiezGit)  
**Region:** `us-east-1`  
**Name prefix:** `renzob-nanlabs-dev-*`

This repository delivers a free‑tier–friendly AWS data pipeline using **Terraform + Python**:

- **S3** (`incoming/`) → **Lambda (ingest)** → **RDS PostgreSQL (PostGIS)**
- **API Lambda (FastAPI + Mangum)** → **API Gateway** (`GET /aggregated-data`)
- **CloudWatch Logs** for both Lambdas
- **Networking**: VPC with public/private subnets; Lambdas in **private subnets**
- **No NAT cost**: Uses **VPC Endpoints** (S3 Gateway, Secrets/Logs Interface) instead of a NAT gateway
- **Local dev**: Docker Compose for **PostGIS**, **MinIO**, and **API (uvicorn)**

> **NAT note (challenge requirement vs. implementation):** The challenge mentions a NAT gateway. To stay within free tier and still keep Lambdas private, this project uses **VPC Endpoints** for egress to AWS services. If a NAT is strictly required by reviewers, it can be enabled with a small module without changing any application code.

---

## Repository Layout

```
.
├── README.md                        # you are here
├── docs/
├── examples/
│   ├── airbnb_listings_sample.csv   # example input
│   └── s3_put_event.json            # sample S3 PUT event
├── docker-compose.yml               # PostGIS + MinIO + API (uvicorn)
├── docker/
│   ├── initdb/01_enable_postgis.sql # CREATE EXTENSION postgis;
│   └── lambda_layer/                # optional helpers (not required)
├── lambda/
│   ├── ingest/                      # S3-triggered CSV→aggregation→upsert
│   └── api/                         # FastAPI + Mangum (GET /aggregated-data)
└── terraform/
    ├── envs/dev/main.tf             # composes modules & S3→Lambda notify
    ├── modules/{vpc,endpoints,s3,rds,iam,lambdas,apigw,backup}
    ├── providers.tf
    ├── variables.tf
    └── outputs.tf
```

---

## Architecture (high level)

- **S3** receives CSVs under `incoming/`  
- **Ingest Lambda** (private subnet) is triggered on `ObjectCreated:*` with prefix `incoming/` and suffix `.csv`  
  - Parses CSV (`city`, optional `price`), normalizes city names, computes `listing_count` and `avg_price`
  - Upserts into `aggregated_city_stats` on **RDS PostgreSQL (PostGIS)**
  - Ensures PostGIS extension, table, and indexes exist (idempotent)
- **API Lambda** serves **FastAPI** via **Mangum** → **API Gateway HTTP API** (`GET /aggregated-data?limit=&city=`)  
- **VPC Endpoints**: S3 (Gateway), Secrets Manager (Interface), CloudWatch Logs (Interface)  
- **CloudWatch** log groups with retention; optional basic alarms to SNS

**Indexes created:**  
`idx_agg_count_city (listing_count DESC, city ASC)`, `idx_agg_city (city)`, and `idx_agg_geom (GIST)`

---

## Prerequisites

- **AWS CLI v2**, **Terraform ≥ 1.6**, **Docker Desktop**
- **Python 3.10** locally (only for vendoring)  
- Windows users: `make` is optional (PowerShell alternatives below)

Authenticate:
```bash
aws configure          # set region to us-east-1
aws sts get-caller-identity
```

---

## Build — Lambda zips with Linux-compatible wheels

We vendor dependencies **inside** the Lambda Python 3.10 image to match Amazon Linux.

### Windows (PowerShell)

```powershell
# from repo root
make clean
make build-linux-all
```

If you don’t use `make`, use these one-liners (from repo root):
```powershell
# API
docker run --rm -v "${PWD}:/var/task" -w /var/task public.ecr.aws/lambda/python:3.10 `
  /bin/sh -lc "rm -rf build/api/package && mkdir -p build/api/package && pip install -r lambda/api/requirements.txt -t build/api/package && cp -r lambda/api/* build/api/package/ && cd build/api/package && zip -r ../../api.zip ."

# Ingest
docker run --rm -v "${PWD}:/var/task" -w /var/task public.ecr.aws/lambda/python:3.10 `
  /bin/sh -lc "rm -rf build/ingest/package && mkdir -p build/ingest/package && pip install -r lambda/ingest/requirements.txt -t build/ingest/package && cp -r lambda/ingest/* build/ingest/package/ && cd build/ingest/package && zip -r ../../ingest.zip ."
```

---

## Deploy — Terraform (dev)

```bash
cd terraform/envs/dev
terraform init
terraform apply -var="prefix=renzob-nanlabs" -var="env=dev" -auto-approve
```

Grab outputs:
```bash
terraform output -raw s3_bucket
terraform output -raw api_base_url
terraform output -raw db_endpoint
```

> The module sets `source_code_hash` on Lambdas so code changes re-deploy cleanly on `terraform apply`.

---

## Test — End to End

### 1) Trigger via S3 PUT (recommended)
```bash
BUCKET=$(terraform output -raw s3_bucket)
aws s3 cp ../../examples/airbnb_listings_sample.csv "s3://${BUCKET}/incoming/airbnb_listings_sample.csv" --content-type text/csv
aws logs tail "/aws/lambda/renzob-nanlabs-dev-ingest" --follow
```
Expected logs: `s3_get_object_before`, `csv_parsed`, `db_connect_*`, `done`

### 2) Query the API
```bash
API=$(terraform output -raw api_base_url)
curl "$API/healthz"
curl "$API/aggregated-data?limit=100"
curl "$API/aggregated-data?city=Berlin&limit=50"
```

### 3) Manual Lambda Test (optional)
```bash
BUCKET=$(terraform output -raw s3_bucket)
cat > event.json <<EOF
{
  "Records": [{
    "eventSource": "aws:s3",
    "awsRegion": "us-east-1",
    "eventName": "ObjectCreated:Put",
    "s3": {
      "bucket": { "name": "${BUCKET}" },
      "object": { "key": "incoming/airbnb_listings_sample.csv" }
    }
  }]
}
EOF

aws lambda invoke --function-name renzob-nanlabs-dev-ingest --payload fileb://event.json out.json
cat out.json
```

---

## Local Development (Docker Compose)

```bash
docker compose up -d --build
# MinIO: http://localhost:9001  (user: minio / pass: minio123)
# Create bucket 'nanlabs' and upload examples/airbnb_listings_sample.csv to incoming/
# API:   http://localhost:8000/aggregated-data
```

**Windows PowerShell:**
```powershell
docker compose up -d --build
# Then browse http://localhost:9001 (minio/minio123)
# Local API: Invoke-WebRequest http://localhost:8000/aggregated-data | Select-Object -ExpandProperty Content
```

---

## Configuration Notes

- **Runtime:** Python `3.10` for both Lambdas
- **Handlers:** `main.handler` (zips root contain `main.py`)
- **Secrets:** Pulled at runtime from **AWS Secrets Manager** (host, port, db, user, password)
- **Indexes:** Created on first connect (idempotent); `ANALYZE` after each ingest
- **S3 Notification:** `ObjectCreated:*` with `prefix=incoming/`, `suffix=.csv`

---

## Troubleshooting

- **No logs on upload**  
  - Verify the notification configuration:  
    `aws s3api get-bucket-notification-configuration --bucket $BUCKET`  
    Should include `ObjectCreated:*`, `prefix=incoming/`, `suffix=.csv` and your Lambda ARN.  
  - Upload with a **new key** (e.g., timestamp suffix).

- **`psycopg2` missing on Lambda**  
  - Rebuild zips inside the Lambda Docker image: `make build-linux-all`  
  - Then `terraform apply` to update code (uses `source_code_hash`).

- **API base URL empty**  
  - Run `terraform output -raw api_base_url` **in `terraform/envs/dev`**.  
  - Alternatively, discover via AWS CLI:  
    `aws apigatewayv2 get-apis --query "Items[?Name=='renzob-nanlabs-dev-api'].ApiEndpoint" --output text`

- **500 from API**  
  - Tail `/aws/lambda/renzob-nanlabs-dev-api`; ensure RDS is finished creating and Secrets are accessible.

- **S3 upload doesn’t trigger**  
  - Confirm region `us-east-1`, bucket exists, and you used `incoming/` + `.csv` suffix.

---

## Cleanup (avoid charges)

```bash
cd terraform/envs/dev
terraform destroy -var="prefix=renzob-nanlabs" -var="env=dev" -auto-approve
docker compose down -v
```

---

## Extensibility & “Nice to Have” Highlights

- **Data Quality:** City normalization, tolerant price parsing, sanity ranges; invalids skipped (no DLQ by choice).
- **Indexing:** Composite ordering index, city lookup index, and GIST on `geom` to enable spatial queries.
- **Monitoring:** Optional CloudWatch alarms (`Errors > 0`) → SNS topic.
- **Backups:** Optional **AWS Backup** daily plan for the RDS instance.
- **CI / Pre-commit:** Optional GitHub Actions and pre-commit config for fmt/validate/lint/secrets checks.

---

## Assumptions

- CSV minimal schema contains `city` and optional `price` columns; others ignored.  
- Cities aggregated case-insensitively (Title Case stored).  
- `geom` is nullable; future job can geocode and fill points.

---

## License

MIT (or per challenge repository’s default).


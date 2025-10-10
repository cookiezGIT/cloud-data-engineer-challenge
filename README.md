### Prereqs

* AWS account with admin or appropriate privileges
* Terraform ≥ 1.6, AWS CLI configured to `us-east-1`
* Python 3.11 + zip (for packaging)
* (Optional) Docker Desktop for local validation

### 1) Configure variables

Create `terraform/envs/dev/terraform.tfvars`:

```hcl
project_prefix = "renzob-nanlabs"
env            = "dev"
region         = "us-east-1"
allowed_ips    = ["YOUR.PUBLIC.IP.ADDR/32"] # Optional for psql from your laptop via SG
db_username    = "renzob_admin"
# db_password stored in Secrets Manager by Terraform; not in tfvars
```

### 2) Build Lambda layer (psycopg2) — optional if using RDS Proxy

```bash
cd docker/lambda_layer
./build_layer.sh  # builds python libs into a zip for Lambda layer compatible with Amazon Linux 2023
```

Terraform will pick up the zipped artifact from `docker/lambda_layer/dist/python.zip`.

### 3) Deploy infra

```bash
cd terraform/envs/dev
terraform init
terraform apply -auto-approve
```

Outputs will include:

* `s3_bucket`
* `api_base_url` (e.g., `https://xxxxx.execute-api.us-east-1.amazonaws.com`)
* `db_endpoint` (RDS writer endpoint)

### 4) Load sample data and trigger pipeline

```bash
aws s3 cp ./examples/airbnb_listings_sample.csv s3://$(terraform output -raw s3_bucket)/incoming/airbnb_listings_sample.csv
```

Wait for the ingest Lambda to run (few seconds). Check **CloudWatch Logs** for details.

### 5) Query API

```bash
curl "$API_BASE_URL/aggregated-data"
```

Example response (plain list):

```json
[
  {"city":"Lima","listing_count":1234,"avg_price":58.9},
  {"city":"Cusco","listing_count":987,"avg_price":47.2}
]
```

### 6) Destroy

```bash
terraform destroy
```
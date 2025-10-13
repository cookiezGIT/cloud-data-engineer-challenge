locals {
  name_prefix = "${var.prefix}-${var.env}"
}

resource "null_resource" "build_lambdas" {
  provisioner "local-exec" {
    command     = "make build-all"
    working_dir = "${path.module}/../../.."
  }
}

module "vpc" {
  source = "../../modules/vpc"
  name   = local.name_prefix
  cidr   = "10.20.0.0/16"
}

module "endpoints" {
  source                 = "../../modules/endpoints"
  vpc_id                 = module.vpc.vpc_id
  private_subnet_ids     = module.vpc.private_subnet_ids
  lambda_sg_id           = module.vpc.lambda_sg_id
  private_route_table_id = module.vpc.private_route_table_id
}


module "s3" {
  source = "../../modules/s3"
  name   = local.name_prefix
}

module "rds" {
  source     = "../../modules/rds"
  name       = local.name_prefix
  subnet_ids = module.vpc.private_subnet_ids
  rds_sg_id  = module.vpc.rds_sg_id
}

module "iam" {
  source      = "../../modules/iam"
  name        = local.name_prefix
  bucket_arn  = module.s3.bucket_arn
  bucket_name = module.s3.bucket
  secrets_arn = module.rds.secret_arn
}

module "lambdas" {
  source        = "../../modules/lambdas"
  name          = local.name_prefix
  subnet_ids    = module.vpc.private_subnet_ids
  lambda_sg_id  = module.vpc.lambda_sg_id
  role_arn      = module.iam.lambda_role_arn
  bucket_name   = module.s3.bucket
  db_secret_arn = module.rds.secret_arn
  db_secret_id  = module.rds.secret_id
  build_zip_dir = "${path.module}/../../../build"

  depends_on = [
    null_resource.build_lambdas,
    module.endpoints,
    module.iam
  ]
}

module "apigw" {
  source            = "../../modules/apigw"
  name              = local.name_prefix
  lambda_arn        = module.lambdas.api_lambda_arn
  lambda_invoke_arn = module.lambdas.api_lambda_invoke_arn
}

module "backup" {
  source       = "../../modules/backup"
  resource_arn = module.rds.instance_arn
}


# S3 → ingest Lambda notification
resource "aws_s3_bucket_notification" "s3_to_lambda" {
  bucket = module.s3.bucket

  lambda_function {
    lambda_function_arn = module.lambdas.ingest_lambda_arn
    events              = ["s3:ObjectCreated:*"] # cover Put, Copy, MPU complete, etc.
    filter_suffix       = ".csv"
    filter_prefix       = "incoming/"
  }

  depends_on = [module.lambdas, module.s3, aws_lambda_permission.allow_s3_invoke]
}

resource "aws_lambda_permission" "allow_s3_invoke" {
  statement_id  = "AllowExecutionFromS3"
  action        = "lambda:InvokeFunction"
  function_name = module.lambdas.ingest_lambda_name
  principal     = "s3.amazonaws.com"
  source_arn    = module.s3.bucket_arn
}

output "api_base_url" { value = module.apigw.base_url }
output "s3_bucket" { value = module.s3.bucket }
output "db_endpoint" { value = module.rds.endpoint }
output "ingest_lambda_name" { value = module.lambdas.ingest_lambda_name }

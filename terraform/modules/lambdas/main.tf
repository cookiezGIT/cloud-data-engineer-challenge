variable "name" { type = string }
variable "subnet_ids" { type = list(string) }
variable "lambda_sg_id" { type = string }
variable "role_arn" { type = string }
variable "bucket_name" { type = string }
variable "db_secret_arn" { type = string }
variable "db_secret_id" { type = string }
variable "build_zip_dir" { type = string }

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/lambda/${var.name}-api"
  retention_in_days = 14
}
resource "aws_cloudwatch_log_group" "ingest" {
  name              = "/aws/lambda/${var.name}-ingest"
  retention_in_days = 14
}

resource "aws_lambda_function" "api" {
  function_name = "${var.name}-api"
  role          = var.role_arn
  package_type  = "Zip"
  filename      = "${var.build_zip_dir}/api.zip"
  handler       = "main.handler"
  runtime       = "python3.10"
  timeout       = 10
  memory_size   = 512
  source_code_hash = filebase64sha256("${var.build_zip_dir}/api.zip")   # ⬅️ add this

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [var.lambda_sg_id]
  }
  environment {
    variables = {
      DB_SECRET_ID = var.db_secret_id
      TABLE_NAME   = "aggregated_city_stats"
    }
  }
  depends_on = [aws_cloudwatch_log_group.api]
}

resource "aws_lambda_function" "ingest" {
  function_name = "${var.name}-ingest"
  role          = var.role_arn
  package_type  = "Zip"
  filename      = "${var.build_zip_dir}/ingest.zip"
  handler       = "main.handler"
  runtime       = "python3.10"
  timeout       = 120
  memory_size   = 1024
  source_code_hash = filebase64sha256("${var.build_zip_dir}/ingest.zip")  # ⬅️ add this

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [var.lambda_sg_id]
  }
  environment {
    variables = {
      DB_SECRET_ID = var.db_secret_id
      TABLE_NAME   = "aggregated_city_stats"
    }
  }
  depends_on = [aws_cloudwatch_log_group.ingest]
}


output "api_lambda_arn"        { value = aws_lambda_function.api.arn }
output "api_lambda_invoke_arn" { value = aws_lambda_function.api.invoke_arn }
output "ingest_lambda_arn"     { value = aws_lambda_function.ingest.arn }
output "ingest_lambda_name"    { value = aws_lambda_function.ingest.function_name }

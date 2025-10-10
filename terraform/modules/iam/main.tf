variable "name"        { type = string }
variable "bucket_arn"  { type = string }
variable "bucket_name" { type = string }
variable "secrets_arn" { type = string }

# Trust policy: allow Lambda to assume this role
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# ── ROLE ───────────────────────────────────────────────────────────────────────
resource "aws_iam_role" "lambda" {
  name               = "${var.name}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

# Inline permissions for Logs, S3, Secrets, and VPC ENIs
data "aws_iam_policy_document" "inline" {
  statement {
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["*"]
  }

  statement {
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${var.bucket_arn}/*"]
  }

  statement {
    actions   = ["s3:ListBucket"]
    resources = [var.bucket_arn]
  }

  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.secrets_arn]
  }

  # Needed for Lambdas in a VPC
  statement {
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DeleteNetworkInterface",
      "ec2:AssignPrivateIpAddresses",
      "ec2:UnassignPrivateIpAddresses"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "lambda_policy" {
  name_prefix = "${var.name}-lambda-policy-"
  description = "Lambda inline perms for logs/S3/secrets/ENI"
  policy      = data.aws_iam_policy_document.inline.json
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role_policy_attachment" "attach_inline" {
  role       = aws_iam_role.lambda.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

resource "aws_iam_role_policy_attachment" "attach_vpc_managed" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

output "lambda_role_arn" {
  value = aws_iam_role.lambda.arn
}

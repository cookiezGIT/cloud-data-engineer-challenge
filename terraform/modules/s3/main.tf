variable "name" { type = string }

resource "random_id" "suffix" { byte_length = 3 }

resource "aws_s3_bucket" "this" {
  bucket = "${var.name}-s3-${random_id.suffix.hex}"
}
resource "aws_s3_bucket_versioning" "v" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_lifecycle_configuration" "l" {
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "expire-noncurrent"
    status = "Enabled"

    # filter required by newer provider versions
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

output "bucket" { value = aws_s3_bucket.this.bucket }
output "bucket_arn" { value = aws_s3_bucket.this.arn }

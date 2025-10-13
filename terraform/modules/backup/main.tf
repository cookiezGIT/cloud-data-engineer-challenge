variable "resource_arn" { type = string }

# Role for AWS Backup to assume
data "aws_iam_policy" "backup_service" {
  arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  name               = "aws-backup-service-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "attach" {
  role       = aws_iam_role.backup.name
  policy_arn = data.aws_iam_policy.backup_service.arn
}

resource "aws_backup_vault" "this" {
  name = "rds-backup-vault"
}

resource "aws_backup_plan" "daily" {
  name = "daily-rds-plan"

  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.this.name
    schedule          = "cron(0 6 * * ? *)" # daily 06:00 UTC
    lifecycle {
      delete_after = 14
    }
  }
}

resource "aws_backup_selection" "select" {
  name         = "rds-selection"
  plan_id      = aws_backup_plan.daily.id
  resources    = [var.resource_arn]
  iam_role_arn = aws_iam_role.backup.arn
}

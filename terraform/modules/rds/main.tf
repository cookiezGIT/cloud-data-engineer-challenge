variable "name" { type = string }
variable "subnet_ids" { type = list(string) }
variable "rds_sg_id" { type = string }

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-dbsubnet"
  subnet_ids = var.subnet_ids
}

resource "aws_db_instance" "this" {
  identifier             = "${var.name}-pg"
  engine                 = "postgres"
  engine_version         = "16.8"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  db_name                = "appdb"
  username               = "appuser"
  password               = "apppass123!"
  skip_final_snapshot    = true
  deletion_protection    = false
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.rds_sg_id]
  publicly_accessible    = false
  storage_encrypted      = true
}

resource "aws_secretsmanager_secret" "db" {
  name = "${var.name}-db-secret"
}

resource "aws_secretsmanager_secret_version" "dbv" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    host     = aws_db_instance.this.address,
    port     = 5432,
    dbname   = "appdb",
    username = "appuser",
    password = "apppass123!"
  })
}

output "endpoint" { value = aws_db_instance.this.address }
output "secret_arn" { value = aws_secretsmanager_secret.db.arn }
output "secret_id" { value = aws_secretsmanager_secret.db.id }
output "instance_arn" {
  value = aws_db_instance.this.arn
}

output "rds_endpoint" {
  description = "The connection endpoint for the RDS MySQL database"
  value       = aws_db_instance.chattingo_db.endpoint
}
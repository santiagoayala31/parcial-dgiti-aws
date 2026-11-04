###############################################################################
# outputs.tf - Datos útiles tras el despliegue (terraform output)
###############################################################################
output "app_url" {
  description = "URL pública del servicio (a través del ALB)"
  value       = "http://${aws_lb.app.dns_name}"
}

output "health_url" {
  description = "Endpoint de validación"
  value       = "http://${aws_lb.app.dns_name}/health"
}

output "status_url" {
  description = "Endpoint de estado (verifica BD primaria y réplica)"
  value       = "http://${aws_lb.app.dns_name}/status"
}

output "swagger_url" {
  description = "Documentación interactiva Swagger"
  value       = "http://${aws_lb.app.dns_name}/docs"
}

output "alb_dns_name" {
  description = "DNS del Application Load Balancer"
  value       = aws_lb.app.dns_name
}

output "app_version" {
  description = "Versión desplegada (hash del código fuente)"
  value       = local.app_version
}

output "vpc_id" {
  description = "ID de la VPC"
  value       = aws_vpc.main.id
}

output "availability_zones" {
  description = "Zonas de disponibilidad usadas"
  value       = local.azs
}

output "autoscaling_group_name" {
  description = "Nombre del Auto Scaling Group"
  value       = aws_autoscaling_group.app.name
}

output "rds_primary_endpoint" {
  description = "Endpoint privado de la BD primaria (solo accesible desde la VPC)"
  value       = aws_db_instance.primary.address
}

output "rds_replica_endpoint" {
  description = "Endpoint privado de la réplica de lectura"
  value       = aws_db_instance.replica.address
}

output "db_secret_name" {
  description = "Secreto de Secrets Manager con las credenciales de la BD"
  value       = aws_secretsmanager_secret.db.name
}

output "artifacts_bucket" {
  description = "Bucket S3 con los artefactos de despliegue"
  value       = aws_s3_bucket.artifacts.id
}

output "security_groups" {
  description = "Security Groups encadenados"
  value = {
    alb = aws_security_group.alb.id
    app = aws_security_group.app.id
    db  = aws_security_group.db.id
  }
}

output "cloudwatch_dashboard_url" {
  description = "Dashboard de CloudWatch"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards/dashboard/${aws_cloudwatch_dashboard.main.dashboard_name}"
}

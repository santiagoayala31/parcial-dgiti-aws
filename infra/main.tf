###############################################################################
# main.tf - Infraestructura completa de la evaluación final DGITI
#
#  1. Red          : VPC, 2 AZ, subredes públicas / privadas app / privadas BD,
#                    IGW, NAT Gateway, tablas de rutas, VPC Endpoint S3
#  2. Seguridad    : Security Groups encadenados ALB -> APP -> BD
#  3. Secretos     : contraseña aleatoria de la BD en AWS Secrets Manager
#  4. Almacenamiento: bucket S3 de artefactos (versionado y cifrado)
#  5. Base de datos: RDS PostgreSQL primaria + réplica de lectura en otra AZ
#  6. Cómputo      : Launch Template + Auto Scaling Group (2-4 EC2) + escalado CPU
#  7. Balanceo     : Application Load Balancer + Target Group + health checks
#  8. Monitoreo    : Dashboard de CloudWatch + alarmas + SNS
###############################################################################

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  name = "${var.project_name}-${var.environment}"
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)

  # Versión de la app = hash del código fuente. Si el código cambia, cambia el
  # Launch Template y el ASG hace un "instance refresh" (despliegue rolling).
  app_dir = "${path.module}/../app"
  app_files = sort(concat(
    tolist(fileset(local.app_dir, "*.py")),
    ["requirements.txt"]
  ))
  app_version  = substr(sha1(join("", [for f in local.app_files : filesha1("${local.app_dir}/${f}")])), 0, 12)
  artifact_key = "releases/${local.app_version}/app.zip"
}

###############################################################################
# 1. RED
###############################################################################
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-igw" }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = { Name = "${local.name}-public-${local.azs[count.index]}", Tier = "public" }
}

resource "aws_subnet" "app" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.app_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = { Name = "${local.name}-app-${local.azs[count.index]}", Tier = "private-app" }
}

resource "aws_subnet" "db" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.db_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = { Name = "${local.name}-db-${local.azs[count.index]}", Tier = "private-db" }
}

# NAT Gateway único (decisión de costo para el laboratorio): permite que las EC2
# privadas descarguen paquetes sin exponerse a Internet.
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${local.name}-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${local.name}-nat" }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${local.name}-rt-public" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "${local.name}-rt-private" }
}

resource "aws_route_table_association" "app" {
  count          = 2
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.private.id
}

# Las subredes de BD no tienen ruta a Internet (solo tráfico local de la VPC)
resource "aws_route_table" "db" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-rt-db-isolated" }
}

resource "aws_route_table_association" "db" {
  count          = 2
  subnet_id      = aws_subnet.db[count.index].id
  route_table_id = aws_route_table.db.id
}

# VPC Endpoint Gateway de S3 (gratuito): las EC2 descargan el artefacto
# sin pasar por el NAT ni por Internet.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${local.name}-vpce-s3" }
}

###############################################################################
# 2. SEGURIDAD - Security Groups encadenados (mínimo privilegio)
#    Internet --80--> ALB --8000--> EC2 --5432--> RDS
###############################################################################
resource "aws_security_group" "alb" {
  name        = "${local.name}-alb-sg"
  description = "ALB: HTTP desde Internet"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-alb-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP desde Internet"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Solo hacia las instancias de la app"
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "app" {
  name        = "${local.name}-app-sg"
  description = "EC2 app: solo trafico desde el ALB"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-app-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "Puerto de la API solo desde el ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "app_https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS saliente (paquetes, S3, Secrets Manager) via NAT/endpoint"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "app_http" {
  security_group_id = aws_security_group.app.id
  description       = "HTTP saliente (repositorios de paquetes del SO)"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "app_to_db" {
  security_group_id            = aws_security_group.app.id
  description                  = "PostgreSQL hacia RDS"
  referenced_security_group_id = aws_security_group.db.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "db" {
  name        = "${local.name}-db-sg"
  description = "RDS: PostgreSQL solo desde las EC2 de la app"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-db-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL solo desde el SG de la app"
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

###############################################################################
# 3. SECRETOS - la contraseña nunca está en el código ni en el repositorio
###############################################################################
resource "random_password" "db" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "${local.name}-db-credentials"
  description             = "Credenciales de RDS PostgreSQL para la API"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
    dbname   = var.db_name
  })
}

###############################################################################
# 4. ALMACENAMIENTO - bucket S3 de artefactos de despliegue
###############################################################################
resource "random_id" "suffix" {
  byte_length = 3
}

resource "aws_s3_bucket" "artifacts" {
  bucket        = "${local.name}-artifacts-${data.aws_caller_identity.current.account_id}-${random_id.suffix.hex}"
  force_destroy = true
  tags          = { Name = "${local.name}-artifacts" }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "archive_file" "app" {
  type        = "zip"
  source_dir  = local.app_dir
  output_path = "${path.module}/.build/app.zip"
  excludes = [
    "tests",
    "requirements-dev.txt",
    "__pycache__",
    "tests/__pycache__",
    ".pytest_cache",
    ".ruff_cache",
  ]
}

resource "aws_s3_object" "app" {
  bucket = aws_s3_bucket.artifacts.id
  key    = local.artifact_key
  source = data.archive_file.app.output_path
  etag   = data.archive_file.app.output_md5

  lifecycle {
    ignore_changes = [etag] # el zip puede variar en metadatos; la versión la define el hash del código
  }
}

###############################################################################
# 5. BASE DE DATOS - RDS PostgreSQL primaria + réplica de lectura
###############################################################################
resource "aws_db_subnet_group" "main" {
  name       = "${local.name}-db-subnets"
  subnet_ids = aws_subnet.db[*].id
  tags       = { Name = "${local.name}-db-subnets" }
}

resource "aws_db_instance" "primary" {
  identifier        = "${local.name}-db-primary"
  engine            = "postgres"
  engine_version    = var.db_engine_version
  instance_class    = var.db_instance_class
  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  availability_zone      = local.azs[0]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period      = 1 # requerido para poder crear la réplica
  monitoring_interval          = 0 # Enhanced Monitoring no está soportado en Learner Lab
  performance_insights_enabled = false
  auto_minor_version_upgrade   = true
  apply_immediately            = true
  skip_final_snapshot          = true
  deletion_protection          = false

  tags = { Name = "${local.name}-db-primary", Role = "primary" }
}

resource "aws_db_instance" "replica" {
  identifier          = "${local.name}-db-replica"
  replicate_source_db = aws_db_instance.primary.identifier
  instance_class      = var.db_instance_class
  storage_encrypted   = true

  vpc_security_group_ids = [aws_security_group.db.id]
  availability_zone      = local.azs[1]
  publicly_accessible    = false

  backup_retention_period      = 0
  monitoring_interval          = 0
  performance_insights_enabled = false
  auto_minor_version_upgrade   = true
  apply_immediately            = true
  skip_final_snapshot          = true
  deletion_protection          = false

  tags = { Name = "${local.name}-db-replica", Role = "read-replica" }
}

###############################################################################
# 6. CÓMPUTO - Launch Template + Auto Scaling Group
###############################################################################
resource "aws_launch_template" "app" {
  name_prefix   = "${local.name}-lt-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.instance_type

  # AWS Academy no permite crear roles: se usa el LabInstanceProfile existente
  iam_instance_profile {
    name = var.instance_profile_name
  }

  vpc_security_group_ids = [aws_security_group.app.id]

  # IMDSv2 obligatorio (protege contra SSRF)
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  monitoring {
    enabled = true # métricas de EC2 cada 1 minuto en CloudWatch
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 8
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh", {
    aws_region      = var.aws_region
    artifact_bucket = aws_s3_bucket.artifacts.id
    artifact_key    = aws_s3_object.app.key
    app_version     = local.app_version
    app_port        = var.app_port
    environment     = var.environment
    db_secret_arn   = aws_secretsmanager_secret.db.arn
    db_host         = aws_db_instance.primary.address
    db_replica_host = aws_db_instance.replica.address
    db_name         = var.db_name
    db_username     = var.db_username
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name       = "${local.name}-app"
      AppVersion = local.app_version
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "${local.name}-app-volume" }
  }

  depends_on = [aws_secretsmanager_secret_version.db]
}

resource "aws_autoscaling_group" "app" {
  name                      = "${local.name}-asg"
  min_size                  = var.asg_min_size
  desired_capacity          = var.asg_desired_capacity
  max_size                  = var.asg_max_size
  vpc_zone_identifier       = aws_subnet.app[*].id
  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 300
  default_instance_warmup   = 120

  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
  }

  # Despliegue rolling sin caída del servicio cuando cambia la versión de la app
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 180
    }
  }

  enabled_metrics = [
    "GroupMinSize",
    "GroupMaxSize",
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupPendingInstances",
    "GroupTerminatingInstances",
    "GroupTotalInstances",
  ]

  tag {
    key                 = "Name"
    value               = "${local.name}-app"
    propagate_at_launch = true
  }

  lifecycle {
    ignore_changes = [desired_capacity] # lo administra la política de escalado
  }
}

resource "aws_autoscaling_policy" "cpu" {
  name                      = "${local.name}-cpu-target-tracking"
  autoscaling_group_name    = aws_autoscaling_group.app.name
  policy_type               = "TargetTrackingScaling"
  estimated_instance_warmup = 120

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.cpu_target_percent
  }
}

###############################################################################
# 7. BALANCEO - Application Load Balancer
###############################################################################
resource "aws_lb" "app" {
  name                       = "${local.name}-alb"
  load_balancer_type         = "application"
  internal                   = false
  security_groups            = [aws_security_group.alb.id]
  subnets                    = aws_subnet.public[*].id
  drop_invalid_header_fields = true
  idle_timeout               = 60

  tags = { Name = "${local.name}-alb" }
}

resource "aws_lb_target_group" "app" {
  name                 = "${local.name}-tg"
  port                 = var.app_port
  protocol             = "HTTP"
  vpc_id               = aws_vpc.main.id
  target_type          = "instance"
  deregistration_delay = 30

  load_balancing_algorithm_type = "round_robin"

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = "${local.name}-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

###############################################################################
# 8. MONITOREO - SNS + alarmas + dashboard de CloudWatch
###############################################################################
resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${local.name}-alb-5xx-errors"
  alarm_description   = "Errores 5XX de los targets del ALB"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { LoadBalancer = aws_lb.app.arn_suffix }
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "${local.name}-unhealthy-hosts"
  alarm_description   = "Hay instancias que no pasan el health check del ALB"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions = {
    LoadBalancer = aws_lb.app.arn_suffix
    TargetGroup  = aws_lb_target_group.app.arn_suffix
  }
  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "latency_p95" {
  alarm_name          = "${local.name}-latency-p95"
  alarm_description   = "Latencia p95 de los targets mayor a 1 segundo"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p95"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { LoadBalancer = aws_lb.app.arn_suffix }
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${local.name}-rds-cpu-high"
  alarm_description   = "CPU de la BD primaria mayor al 80%"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.primary.identifier }
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "replica_lag" {
  alarm_name          = "${local.name}-replica-lag"
  alarm_description   = "Retraso de la réplica de lectura mayor a 30 segundos"
  namespace           = "AWS/RDS"
  metric_name         = "ReplicaLag"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 30
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.replica.identifier }
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.name}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "text", x = 0, y = 0, width = 24, height = 2
        properties = {
          markdown = "# DGITI - Desempeño y monitoreo\nALB `${aws_lb.app.dns_name}` -> ASG `${aws_autoscaling_group.app.name}` -> RDS primaria + réplica | versión app `${local.app_version}`"
        }
      },
      {
        type = "metric", x = 0, y = 2, width = 8, height = 6
        properties = {
          title  = "ALB - Solicitudes por minuto"
          region = var.aws_region
          stat   = "Sum"
          period = 60
          view   = "timeSeries"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.app.arn_suffix, { label = "Total ALB" }],
            ["AWS/ApplicationELB", "RequestCountPerTarget", "TargetGroup", aws_lb_target_group.app.arn_suffix, { label = "Por instancia (promedio)" }],
          ]
        }
      },
      {
        type = "metric", x = 8, y = 2, width = 8, height = 6
        properties = {
          title  = "ALB - Tiempo de respuesta (s)"
          region = var.aws_region
          period = 60
          view   = "timeSeries"
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.app.arn_suffix, { stat = "Average", label = "Promedio" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.app.arn_suffix, { stat = "p95", label = "p95" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.app.arn_suffix, { stat = "p99", label = "p99" }],
          ]
        }
      },
      {
        type = "metric", x = 16, y = 2, width = 8, height = 6
        properties = {
          title  = "ALB - Códigos HTTP"
          region = var.aws_region
          stat   = "Sum"
          period = 60
          view   = "timeSeries"
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_2XX_Count", "LoadBalancer", aws_lb.app.arn_suffix, { label = "2XX" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_4XX_Count", "LoadBalancer", aws_lb.app.arn_suffix, { label = "4XX" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", aws_lb.app.arn_suffix, { label = "5XX target" }],
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", aws_lb.app.arn_suffix, { label = "5XX ALB" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 8, width = 8, height = 6
        properties = {
          title  = "EC2 - CPU por instancia (%)"
          region = var.aws_region
          period = 60
          view   = "timeSeries"
          metrics = [
            [{ expression = "SEARCH('{AWS/EC2,InstanceId} MetricName=\"CPUUtilization\"', 'Average', 60)", id = "cpu", label = "" }],
          ]
          yAxis = { left = { min = 0, max = 100 } }
        }
      },
      {
        type = "metric", x = 8, y = 8, width = 8, height = 6
        properties = {
          title  = "Auto Scaling - CPU promedio vs objetivo"
          region = var.aws_region
          period = 60
          view   = "timeSeries"
          metrics = [
            ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", aws_autoscaling_group.app.name, { stat = "Average", label = "CPU promedio ASG" }],
            ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", aws_autoscaling_group.app.name, { stat = "Maximum", label = "CPU máxima ASG" }],
          ]
          annotations = { horizontal = [{ value = var.cpu_target_percent, label = "Objetivo de escalado" }] }
          yAxis       = { left = { min = 0, max = 100 } }
        }
      },
      {
        type = "metric", x = 16, y = 8, width = 8, height = 6
        properties = {
          title  = "Instancias - ASG y salud en el ALB"
          region = var.aws_region
          period = 60
          view   = "timeSeries"
          metrics = [
            ["AWS/AutoScaling", "GroupInServiceInstances", "AutoScalingGroupName", aws_autoscaling_group.app.name, { stat = "Average", label = "En servicio (ASG)" }],
            ["AWS/AutoScaling", "GroupDesiredCapacity", "AutoScalingGroupName", aws_autoscaling_group.app.name, { stat = "Average", label = "Deseadas (ASG)" }],
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", aws_lb_target_group.app.arn_suffix, "LoadBalancer", aws_lb.app.arn_suffix, { stat = "Average", label = "Sanas (ALB)" }],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "TargetGroup", aws_lb_target_group.app.arn_suffix, "LoadBalancer", aws_lb.app.arn_suffix, { stat = "Average", label = "No sanas (ALB)" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 14, width = 12, height = 6
        properties = {
          title  = "RDS - CPU y conexiones"
          region = var.aws_region
          period = 60
          view   = "timeSeries"
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.primary.identifier, { stat = "Average", label = "CPU primaria" }],
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.replica.identifier, { stat = "Average", label = "CPU réplica" }],
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", aws_db_instance.primary.identifier, { stat = "Average", label = "Conexiones primaria", yAxis = "right" }],
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", aws_db_instance.replica.identifier, { stat = "Average", label = "Conexiones réplica", yAxis = "right" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 14, width = 12, height = 6
        properties = {
          title  = "RDS - Retraso de la réplica (s)"
          region = var.aws_region
          period = 60
          view   = "timeSeries"
          metrics = [
            ["AWS/RDS", "ReplicaLag", "DBInstanceIdentifier", aws_db_instance.replica.identifier, { stat = "Maximum", label = "ReplicaLag" }],
          ]
        }
      },
      {
        type = "alarm", x = 0, y = 20, width = 24, height = 3
        properties = {
          title = "Estado de las alarmas"
          alarms = [
            aws_cloudwatch_metric_alarm.alb_5xx.arn,
            aws_cloudwatch_metric_alarm.unhealthy_hosts.arn,
            aws_cloudwatch_metric_alarm.latency_p95.arn,
            aws_cloudwatch_metric_alarm.rds_cpu.arn,
            aws_cloudwatch_metric_alarm.replica_lag.arn,
          ]
        }
      },
    ]
  })
}

###############################################################################
# variables.tf - Parámetros de la infraestructura
###############################################################################

# ---------------------------------------------------------------- General
variable "aws_region" {
  description = "Región de AWS (AWS Academy solo permite us-east-1 y us-west-2)"
  type        = string
  default     = "us-east-1"

  validation {
    condition     = contains(["us-east-1", "us-west-2"], var.aws_region)
    error_message = "AWS Academy Learner Lab solo permite us-east-1 o us-west-2."
  }
}

variable "project_name" {
  description = "Prefijo para nombrar todos los recursos"
  type        = string
  default     = "dgiti"
}

variable "environment" {
  description = "Nombre del ambiente"
  type        = string
  default     = "prod"
}

variable "owner" {
  description = "Integrante dueño de la cuenta donde se despliega (aparece en las etiquetas)"
  type        = string
  default     = "grupo-dgiti"
}

# ---------------------------------------------------------------- Red
variable "vpc_cidr" {
  description = "Bloque CIDR de la VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Subredes públicas (ALB y NAT Gateway), una por AZ"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "app_subnet_cidrs" {
  description = "Subredes privadas de aplicación (EC2), una por AZ"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "db_subnet_cidrs" {
  description = "Subredes privadas de base de datos (RDS), una por AZ"
  type        = list(string)
  default     = ["10.0.21.0/24", "10.0.22.0/24"]
}

# ---------------------------------------------------------------- Cómputo
variable "instance_type" {
  description = "Tipo de instancia EC2 (Learner Lab: nano, micro, small, medium, large)"
  type        = string
  default     = "t3.micro"
}

variable "instance_profile_name" {
  description = "Instance profile existente en AWS Academy (no se pueden crear roles IAM)"
  type        = string
  default     = "LabInstanceProfile"
}

variable "asg_min_size" {
  description = "Mínimo de instancias (>= 2 para alta disponibilidad)"
  type        = number
  default     = 2
}

variable "asg_desired_capacity" {
  description = "Instancias deseadas al iniciar"
  type        = number
  default     = 2
}

variable "asg_max_size" {
  description = "Máximo de instancias al escalar bajo carga"
  type        = number
  default     = 4
}

variable "cpu_target_percent" {
  description = "CPU promedio objetivo para el autoescalado (target tracking)"
  type        = number
  default     = 50
}

variable "app_port" {
  description = "Puerto en el que escucha la API dentro de las EC2"
  type        = number
  default     = 8000
}

# ---------------------------------------------------------------- Base de datos
variable "db_engine_version" {
  description = "Versión mayor de PostgreSQL"
  type        = string
  default     = "16"
}

variable "db_instance_class" {
  description = "Clase de instancia RDS (Learner Lab: nano, micro, small, medium)"
  type        = string
  default     = "db.t3.micro"
}

variable "db_name" {
  description = "Nombre de la base de datos"
  type        = string
  default     = "appdb"
}

variable "db_username" {
  description = "Usuario administrador de la BD (la contraseña se genera aleatoriamente)"
  type        = string
  default     = "appuser"
}

# ---------------------------------------------------------------- Monitoreo
variable "alert_email" {
  description = "Correo para recibir alarmas de CloudWatch vía SNS (vacío = sin suscripción)"
  type        = string
  default     = ""
}

# DGITI · Despliegue, automatización y validación de infraestructura AWS

Evaluación final de **Diseño y Gestión de Infraestructura Tecnológica** (UPB Bucaramanga).
Integrantes: **Jose David Soria** · **Santiago Ayala**

API en Python (FastAPI) desplegada en AWS con **Terraform** y **GitHub Actions**:
ALB → Auto Scaling Group (EC2 en 2 AZ, subredes privadas) → RDS PostgreSQL primaria + réplica de lectura.

Diagrama de arquitectura (iconos oficiales de AWS): [`docs/arquitectura.drawio`](docs/arquitectura.drawio) — abrir con https://app.diagrams.net

## Estructura

```
app/                    API FastAPI + pruebas (pytest)
infra/                  Terraform: provider.tf, variables.tf, main.tf, outputs.tf,
                        terraform.tfvars.example, user_data.sh
.github/workflows/      Pipeline CI/CD (pipeline.yml)
load-tests/             Prueba de carga k6
scripts/                tf-init, smoke test, distribución del balanceador, chaos test
docs/                   Diagrama de arquitectura (.drawio)
```

## Endpoints

| Método | Ruta | Descripción |
|---|---|---|
| GET | `/` | Página demo: distribución del tráfico entre instancias en vivo |
| GET | `/health` | Endpoint de validación (health check del ALB) |
| GET | `/status` | Verifica la BD primaria y la réplica |
| GET | `/api/info` | Instancia y AZ que atendió la solicitud |
| GET/POST | `/api/items` | Lee de la **réplica** / escribe en la **primaria** |
| GET | `/api/stress` | Carga de CPU controlada (saturación y autoescalado) |
| GET | `/docs` | Swagger UI |

## Despliegue (AWS CloudShell)

```bash
git clone https://github.com/santiagoayala31/parcial-dgiti-aws.git && cd parcial-dgiti-aws
bash scripts/install-tools.sh          # Terraform + k6
cp infra/terraform.tfvars.example infra/terraform.tfvars
bash scripts/tf-init.sh             # crea el bucket del estado remoto y hace terraform init
cd infra
terraform plan
terraform apply
terraform output
```

## Pipeline CI/CD

| Etapa | Qué hace |
|---|---|
| CI · Lint, seguridad y pruebas | ruff, bandit, pytest unitarias, pytest integración con PostgreSQL real (service container) |
| CI · Validación Terraform | `fmt -check`, `validate`, escaneo de seguridad IaC con Trivy |
| CD · Terraform plan/apply | Credenciales desde GitHub Secrets, estado remoto en S3, `plan` → `apply` → `output` → smoke test |

Secrets requeridos (credenciales temporales de AWS Academy → *AWS Details*):
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`.
Variables opcionales: `AUTO_DEPLOY=true` (desplegar en cada push a main), `TF_OWNER`.

## Pruebas de desempeño y disponibilidad

```bash
URL=$(terraform -chdir=infra output -raw app_url)
k6 run -e BASE_URL=$URL load-tests/k6-load.js                    # perfil completo (≈8 min)
k6 run -e BASE_URL=$URL -e PROFILE=quick load-tests/k6-load.js   # perfil corto (≈2 min)
python3 scripts/lb_distribution.py $URL 300 20                   # reparto del ALB por instancia
bash scripts/chaos_test.sh $URL $(terraform -chdir=infra output -raw autoscaling_group_name)
```

Métricas en el dashboard `dgiti-prod-dashboard` de CloudWatch (creado por Terraform).

## Decisiones de diseño

- **Red en 3 capas y 2 AZ**: pública (ALB, NAT), privada de app (EC2), privada de BD aislada (sin ruta a Internet).
- **Security Groups encadenados**: Internet:80 → ALB → :8000 EC2 → :5432 RDS. Nada más está abierto.
- **Alta disponibilidad**: ASG mínimo 2 instancias en 2 AZ con health checks del ALB; si una falla se reemplaza sola.
- **Escalado**: target tracking por CPU promedio (50%), de 2 a 4 instancias.
- **BD**: PostgreSQL primaria + réplica de lectura en otra AZ; la app escribe en la primaria y lee de la réplica.
- **Secretos**: contraseña aleatoria en Secrets Manager, leída por la EC2 al arrancar con el `LabInstanceProfile`.
- **Despliegue sin caída**: el artefacto versionado (hash del código) va a S3; un cambio de versión dispara un *instance refresh* rolling.
- **Costo**: un solo NAT Gateway (en producción se usaría uno por AZ).

## Limpieza

```bash
cd infra && terraform destroy
```

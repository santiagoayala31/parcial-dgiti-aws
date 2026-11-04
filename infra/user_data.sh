#!/bin/bash
# user_data.sh - Arranque de cada EC2 del Auto Scaling Group (plantilla Terraform)
# 1) instala Python  2) descarga el artefacto desde S3  3) lee la contraseña de
# Secrets Manager  4) crea el servicio systemd de la API.
set -euxo pipefail
exec > >(tee -a /var/log/user-data.log) 2>&1

REGION="${aws_region}"
APP_DIR=/opt/dgiti-app

dnf install -y python3.11 python3.11-pip unzip

# --- Artefacto de la versión ${app_version} (bucket S3 privado, vía VPC endpoint)
mkdir -p "$APP_DIR"
aws s3 cp "s3://${artifact_bucket}/${artifact_key}" /tmp/app.zip --region "$REGION"
unzip -o /tmp/app.zip -d "$APP_DIR"

python3.11 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install --upgrade pip
"$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt"

# --- Credenciales: se leen en tiempo de arranque con el LabRole (nunca en el código)
DB_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id "${db_secret_arn}" --region "$REGION" \
  --query SecretString --output text \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])')

useradd --system --no-create-home --shell /sbin/nologin dgiti || true
chown -R dgiti:dgiti "$APP_DIR"

set +x # no imprimir la contraseña en el log
cat > /etc/dgiti-app.env <<EOF
APP_NAME=dgiti-api
APP_VERSION=${app_version}
ENVIRONMENT=${environment}
DB_HOST=${db_host}
DB_REPLICA_HOST=${db_replica_host}
DB_PORT=5432
DB_NAME=${db_name}
DB_USER=${db_username}
DB_PASSWORD=$DB_PASSWORD
EOF
set -x
chmod 600 /etc/dgiti-app.env

cat > /etc/systemd/system/dgiti-app.service <<EOF
[Unit]
Description=DGITI API (FastAPI)
After=network-online.target
Wants=network-online.target

[Service]
User=dgiti
WorkingDirectory=$APP_DIR
EnvironmentFile=/etc/dgiti-app.env
ExecStart=$APP_DIR/venv/bin/uvicorn main:app --host 0.0.0.0 --port ${app_port} --workers 2 --no-access-log
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now dgiti-app
echo "DGITI app ${app_version} desplegada"

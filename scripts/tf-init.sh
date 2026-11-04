#!/usr/bin/env bash
# Crea (si no existe) el bucket S3 del estado remoto de Terraform en la cuenta
# actual y ejecuta terraform init apuntando a él.
# Uso: ./scripts/tf-init.sh        (desde la raíz del repositorio)
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="dgiti-tfstate-${ACCOUNT_ID}"

if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "Bucket de estado existente: $BUCKET"
else
  echo "Creando bucket de estado: $BUCKET"
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
  aws s3api put-bucket-versioning --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption --bucket "$BUCKET" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
fi

terraform -chdir="$ROOT/infra" init -input=false -reconfigure \
  -backend-config="bucket=${BUCKET}" -backend-config="region=${REGION}"

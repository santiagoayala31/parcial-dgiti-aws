#!/usr/bin/env bash
# Crea (si no existen) los buckets S3 del estado remoto y de artefactos en la
# cuenta actual y ejecuta terraform init apuntando al estado.
# Uso: ./scripts/tf-init.sh        (desde la raíz del repositorio)
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="dgiti-tfstate-${ACCOUNT_ID}"

ARTIFACTS="dgiti-artifacts-${ACCOUNT_ID}"

# Crea un bucket privado, versionado y cifrado si no existe.
ensure_bucket() {
  local name="$1"
  if aws s3api head-bucket --bucket "$name" 2>/dev/null; then
    echo "Bucket existente: $name"
    return
  fi
  echo "Creando bucket: $name"
  aws s3api create-bucket --bucket "$name" --region "$REGION" >/dev/null
  aws s3api put-bucket-versioning --bucket "$name" \
    --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption --bucket "$name" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-public-access-block --bucket "$name" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
}

# AWS Academy niega s3:GetBucketObjectLockConfiguration, que el recurso
# aws_s3_bucket de Terraform necesita leer: los buckets se crean aquí con la CLI.
ensure_bucket "$BUCKET"     # estado remoto de Terraform
ensure_bucket "$ARTIFACTS"  # artefactos de la aplicación

terraform -chdir="$ROOT/infra" init -input=false -reconfigure \
  -backend-config="bucket=${BUCKET}" -backend-config="region=${REGION}"

# Libera un bloqueo huérfano (p. ej. de una ejecución cancelada) si se indica
if [ -n "${TF_LOCK_ID:-}" ]; then
  terraform -chdir="$ROOT/infra" force-unlock -force "$TF_LOCK_ID"
fi

# Migración: versiones anteriores administraban el bucket con aws_s3_bucket
STATE="$(terraform -chdir="$ROOT/infra" state list 2>/dev/null || true)"
for addr in aws_s3_bucket.artifacts random_id.suffix; do
  if grep -qx "$addr" <<<"$STATE"; then
    terraform -chdir="$ROOT/infra" state rm "$addr"
  fi
done

# Adopta recursos huérfanos de ejecuciones interrumpidas (idempotente)
bash "$ROOT/scripts/adopt-orphans.sh"

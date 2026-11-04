#!/usr/bin/env bash
# Adopta en el estado de Terraform recursos que una ejecución interrumpida
# (p. ej. un pipeline cancelado) alcanzó a crear sin registrarlos.
# Es idempotente: si no hay huérfanos no hace nada.
set -euo pipefail

INFRA="$(cd "$(dirname "$0")/../infra" && pwd)"
REGION="${AWS_REGION:-us-east-1}"
NAME="dgiti-prod"
tf() { terraform -chdir="$INFRA" "$@"; }

STATE="$(tf state list 2>/dev/null || true)"
has() { grep -qxF "$1" <<<"$STATE"; }

# Balanceador
if ! has "aws_lb.app"; then
  ARN="$(aws elbv2 describe-load-balancers --region "$REGION" --names "${NAME}-alb" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)"
  if [ -n "$ARN" ] && [ "$ARN" != "None" ]; then
    echo "Adoptando ALB huérfano: $ARN"
    tf import -input=false aws_lb.app "$ARN"
  fi
fi

# Bases de datos
for r in primary replica; do
  if ! has "aws_db_instance.$r" && aws rds describe-db-instances --region "$REGION" \
      --db-instance-identifier "${NAME}-db-$r" >/dev/null 2>&1; then
    echo "Adoptando RDS huérfana: ${NAME}-db-$r"
    tf import -input=false "aws_db_instance.$r" "${NAME}-db-$r"
  fi
done

# Asociaciones de las subredes de la app con una tabla de rutas huérfana:
# se importan tal como están y el siguiente apply las mueve a la tabla correcta.
for i in 0 1; do
  addr="aws_route_table_association.app[$i]"
  has "$addr" && continue
  SUBNET="$(tf state show -no-color "aws_subnet.app[$i]" 2>/dev/null | awk -F'"' '/^ *id *=/{print $2; exit}')"
  [ -z "$SUBNET" ] && continue
  RTB="$(aws ec2 describe-route-tables --region "$REGION" \
    --filters "Name=association.subnet-id,Values=$SUBNET" \
    --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || true)"
  if [ -n "$RTB" ] && [ "$RTB" != "None" ]; then
    echo "Adoptando asociación huérfana: $SUBNET -> $RTB"
    tf import -input=false "$addr" "$SUBNET/$RTB"
  fi
done

#!/usr/bin/env bash
# Prueba de alta disponibilidad ("chaos test"):
# termina una instancia del Auto Scaling Group mientras se envían solicitudes
# continuas al ALB y reporta la disponibilidad observada.
#
# Uso: ./scripts/chaos_test.sh http://<alb-dns> <nombre-asg> [segundos]
set -euo pipefail

URL="${1:?Falta la URL del ALB}"
ASG="${2:?Falta el nombre del ASG}"
DURATION="${3:-90}"
REGION="${AWS_REGION:-us-east-1}"

VICTIM=$(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
  --auto-scaling-group-names "$ASG" \
  --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId | [0]' \
  --output text)

echo "Instancia a terminar: $VICTIM"
echo "Enviando solicitudes a $URL/health durante ${DURATION}s..."

(
  sleep 5
  aws autoscaling terminate-instance-in-auto-scaling-group --region "$REGION" \
    --instance-id "$VICTIM" --no-should-decrement-desired-capacity >/dev/null
  echo ">>> $(date +%T) Instancia $VICTIM terminada; el ASG lanzará un reemplazo"
) &

OK=0; FAIL=0; END=$((SECONDS + DURATION))
while [ $SECONDS -lt $END ]; do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$URL/health" || echo 000)
  INST=$(curl -s --max-time 3 "$URL/api/info" | python3 -c 'import json,sys; print(json.load(sys.stdin)["instance_id"])' 2>/dev/null || echo "-")
  if [ "$CODE" = "200" ]; then OK=$((OK + 1)); else FAIL=$((FAIL + 1)); fi
  printf "%s  HTTP %s  atendido por %s\n" "$(date +%T)" "$CODE" "$INST"
  sleep 1
done
wait

TOTAL=$((OK + FAIL))
echo
echo "Resultado: $OK/$TOTAL solicitudes exitosas ($(python3 -c "print(round(100*$OK/$TOTAL,2))")% de disponibilidad)"
aws autoscaling describe-auto-scaling-groups --region "$REGION" --auto-scaling-group-names "$ASG" \
  --query 'AutoScalingGroups[0].Instances[].[InstanceId,AvailabilityZone,LifecycleState,HealthStatus]' \
  --output table

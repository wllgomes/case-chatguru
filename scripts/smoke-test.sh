#!/usr/bin/env bash
set -euo pipefail

# Uso: ./scripts/smoke-test.sh <dev|prod>
#
# Valida a aplicação já implantada de duas formas complementares:
#   1. Direto no Service (via port-forward)  -> prova que o Pod serve tráfego.
#   2. Através do Ingress (Host header)      -> prova que o roteamento funciona.
#
# Variável opcional:
#   INGRESS_URL - base do ingress (default: http://localhost).

ENVIRONMENT="${1:-}"
INGRESS_URL="${INGRESS_URL:-http://localhost}"

if [[ "$ENVIRONMENT" != "dev" && "$ENVIRONMENT" != "prod" ]]; then
  echo "Uso: $0 <dev|prod>" >&2
  exit 1
fi

NAMESPACE="case-chatguru-$ENVIRONMENT"
SERVICE_NAME="${ENVIRONMENT}-case-chatguru"
INGRESS_HOST="${ENVIRONMENT}.case-chatguru.local"
LOCAL_PORT="${LOCAL_PORT:-18080}"

FAILURES=0

check() {
  local description="$1" expected="$2" actual="$3"
  if [[ "$actual" == *"$expected"* ]]; then
    echo "  [OK]   $description"
  else
    echo "  [FAIL] $description"
    echo "         esperado conter: $expected"
    echo "         recebido:        $actual"
    FAILURES=$((FAILURES + 1))
  fi
}

echo "==> Smoke test via port-forward do Service '$SERVICE_NAME'"
kubectl -n "$NAMESPACE" port-forward "service/$SERVICE_NAME" "$LOCAL_PORT:80" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 20); do
  curl -sf "http://localhost:$LOCAL_PORT/health" >/dev/null 2>&1 && break
  sleep 1
done

check "GET /health responde status ok" \
  '"status":"ok"' \
  "$(curl -sS --max-time 5 --retry 3 --retry-delay 1 --retry-connrefused \
     "http://localhost:$LOCAL_PORT/health" || echo '<sem resposta>')"

check "GET /info reporta environment=$ENVIRONMENT" \
  "\"environment\":\"$ENVIRONMENT\"" \
  "$(curl -sS --max-time 5 --retry 3 --retry-delay 1 --retry-connrefused \
     "http://localhost:$LOCAL_PORT/info" || echo '<sem resposta>')"

kill "$PF_PID" 2>/dev/null || true
trap - EXIT

echo "==> Smoke test via Ingress ($INGRESS_HOST -> $INGRESS_URL)"
for _ in $(seq 1 20); do
  curl -sf -H "Host: $INGRESS_HOST" "$INGRESS_URL/health" >/dev/null 2>&1 && break
  sleep 2
done

check "GET /health através do Ingress" \
  '"status":"ok"' \
  "$(curl -sS --max-time 5 --retry 3 --retry-delay 1 --retry-connrefused \
     -H "Host: $INGRESS_HOST" "$INGRESS_URL/health" || echo '<sem resposta>')"

check "GET /info através do Ingress preserva o path" \
  "\"environment\":\"$ENVIRONMENT\"" \
  "$(curl -sS --max-time 5 --retry 3 --retry-delay 1 --retry-connrefused \
     -H "Host: $INGRESS_HOST" "$INGRESS_URL/info" || echo '<sem resposta>')"

echo ""
if (( FAILURES > 0 )); then
  echo "Smoke test do ambiente '$ENVIRONMENT' FALHOU ($FAILURES verificação(ões))." >&2
  exit 1
fi
echo "Smoke test do ambiente '$ENVIRONMENT' passou."

#!/usr/bin/env bash
set -euo pipefail

# Uso: ./scripts/deploy.sh <stg|prod>
#
# Variáveis opcionais:
#   IMAGE       - sobrescreve a imagem do container (ex.: ghcr.io/org/app:abc1234).
#                 Usado pela pipeline para fixar o deploy num SHA específico, em
#                 vez de confiar em tags móveis como 'latest'.
#   OVERLAY_DIR - caminho do overlay a aplicar (default: k8s/overlays/<ambiente>).
#                 Usado para apontar para um overlay derivado (ex.: stg-aws, que
#                 herda de stg/ mas troca host/TLS) sem mudar o namespace real,
#                 que continua vindo do nome do ambiente.
#   TIMEOUT     - timeout do rollout (default: 120s).

ENVIRONMENT="${1:-}"
TIMEOUT="${TIMEOUT:-120s}"

if [[ "$ENVIRONMENT" != "stg" && "$ENVIRONMENT" != "prod" ]]; then
  echo "Uso: $0 <stg|prod>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
OVERLAY_DIR="${OVERLAY_DIR:-$REPO_ROOT/k8s/overlays/$ENVIRONMENT}"
NAMESPACE="case-chatguru-$ENVIRONMENT"
DEPLOYMENT_NAME="${ENVIRONMENT}-case-chatguru"

echo "==> Garantindo namespace '$NAMESPACE'"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "==> Aplicando overlay '$ENVIRONMENT'"
kubectl apply -k "$OVERLAY_DIR"

if [[ -n "${IMAGE:-}" ]]; then
  echo "==> Fixando imagem em '$IMAGE'"
  kubectl -n "$NAMESPACE" set image "deployment/$DEPLOYMENT_NAME" \
    "case-chatguru=$IMAGE"
fi

echo "==> Aguardando rollout de '$DEPLOYMENT_NAME' (timeout $TIMEOUT)"
if ! kubectl -n "$NAMESPACE" rollout status "deployment/$DEPLOYMENT_NAME" --timeout="$TIMEOUT"; then
  echo "!! Rollout falhou. Estado atual do namespace:" >&2
  kubectl -n "$NAMESPACE" get pods -o wide >&2
  kubectl -n "$NAMESPACE" describe deployment "$DEPLOYMENT_NAME" >&2
  exit 1
fi

echo ""
kubectl -n "$NAMESPACE" get deploy,pods,svc,ingress

#!/usr/bin/env bash
set -euo pipefail

# Cria o cluster kind (se ainda não existir) usando o config com
# mapeamento de portas 80/443, necessário pro ingress-nginx funcionar.
# Depois instala e aguarda o ingress-nginx ficar pronto.

CLUSTER_NAME="case-chatguru"
KIND_VERSION="${KIND_VERSION:-v0.24.0}"
# Versão fixada do ingress-nginx: apontar para 'main' deixa o setup
# (e a pipeline) sujeito a quebrar sozinho quando o upstream mudar.
INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-controller-v1.13.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

install_kind() {
  local os arch kind_url

  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *)
      echo "Arquitetura não suportada para instalação automática do kind: $(uname -m)" >&2
      echo "Instale manualmente: https://kind.sigs.k8s.io/docs/user/quick-start/#installation" >&2
      exit 1
      ;;
  esac

  kind_url="https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${os}-${arch}"
  echo "kind não encontrado. Instalando ${KIND_VERSION} para ${os}/${arch}..."

  curl -Lo /tmp/kind "$kind_url"
  chmod +x /tmp/kind
  sudo mv /tmp/kind /usr/local/bin/kind

  echo "kind instalado: $(kind version)"
}

command -v kind >/dev/null 2>&1 || install_kind
command -v kubectl >/dev/null 2>&1 || { echo "kubectl não encontrado. Instale antes de continuar: https://kubernetes.io/docs/tasks/tools/#kubectl" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "docker não encontrado. Instale/inicie o Docker antes de continuar." >&2; exit 1; }

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "Cluster '$CLUSTER_NAME' já existe, pulando criação."
else
  echo "Criando cluster kind '$CLUSTER_NAME'..."
  kind create cluster --config "$REPO_ROOT/kind/kind-config.yaml"
fi

echo "Instalando ingress-nginx (${INGRESS_NGINX_VERSION})..."
kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/kind/deploy.yaml"

echo "Aguardando o ingress-nginx controller ficar pronto..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

echo "Cluster pronto. Contexto atual: $(kubectl config current-context)"
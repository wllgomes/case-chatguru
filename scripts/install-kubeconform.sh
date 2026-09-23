#!/usr/bin/env bash
set -euo pipefail

# Instala o kubeconform em ./.bin/kubeconform (local ao projeto, sem sudo),
# caso ainda não exista. Usado pelo `make validate` para que o comando
# funcione de imediato, do mesmo jeito que setup-kind.sh já faz para o kind.

KUBECONFORM_VERSION="${KUBECONFORM_VERSION:-0.6.7}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BIN_DIR="$REPO_ROOT/.bin"
BIN_PATH="$BIN_DIR/kubeconform"

if [[ -x "$BIN_PATH" ]]; then
  exit 0
fi

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$(uname -m)" in
  x86_64|amd64) arch="amd64" ;;
  aarch64|arm64) arch="arm64" ;;
  *)
    echo "Arquitetura não suportada para instalação automática do kubeconform: $(uname -m)" >&2
    echo "Instale manualmente: https://github.com/yannh/kubeconform#installation" >&2
    exit 1
    ;;
esac

url="https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/kubeconform-${os}-${arch}.tar.gz"
echo "kubeconform não encontrado. Instalando v${KUBECONFORM_VERSION} para ${os}/${arch} em ${BIN_DIR}..."

mkdir -p "$BIN_DIR"
curl -sSL "$url" | tar -xz -C "$BIN_DIR" kubeconform
chmod +x "$BIN_PATH"

echo "kubeconform instalado em $BIN_PATH"

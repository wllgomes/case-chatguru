IMAGE ?= ghcr.io/wllgomes/case-chatguru
TAG   ?= dev-latest
CLUSTER ?= case-chatguru

.PHONY: help test validate build kind-up kind-down load \
        deploy-dev deploy-prod smoke-dev smoke-prod ci logs-dev logs-prod

help:
	@grep -E '^[a-z-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

test: ## Roda os testes unitários
	pytest -v

validate: ## Renderiza os overlays e valida contra o schema da API
	@for target in k8s/base k8s/overlays/dev k8s/overlays/prod; do \
		echo "--> $$target"; \
		kubectl kustomize $$target | kubeconform -strict -summary - || exit 1; \
	done

build: ## Constrói a imagem da aplicação
	docker build -t $(IMAGE):$(TAG) .

kind-up: ## Cria o cluster kind e instala o ingress-nginx
	./scripts/setup-kind.sh

kind-down: ## Destrói o cluster kind
	./scripts/destroy-kind.sh

load: build ## Carrega a imagem construída dentro do cluster kind
	kind load docker-image $(IMAGE):$(TAG) --name $(CLUSTER)

deploy-dev: ## Aplica o overlay dev
	IMAGE=$(IMAGE):$(TAG) ./scripts/deploy.sh dev

deploy-prod: ## Aplica o overlay prod
	IMAGE=$(IMAGE):$(TAG) ./scripts/deploy.sh prod

smoke-dev: ## Smoke test do ambiente dev
	./scripts/smoke-test.sh dev

smoke-prod: ## Smoke test do ambiente prod
	./scripts/smoke-test.sh prod

# Reproduz localmente exatamente a sequência que a pipeline executa.
ci: test validate kind-up load deploy-dev smoke-dev deploy-prod smoke-prod ## Pipeline completa local
	@echo ""
	@echo "Pipeline local concluída com sucesso."

logs-dev: ## Segue os logs do ambiente dev
	kubectl -n case-chatguru-dev logs -l app=case-chatguru -f

logs-prod: ## Segue os logs do ambiente prod
	kubectl -n case-chatguru-prod logs -l app=case-chatguru -f

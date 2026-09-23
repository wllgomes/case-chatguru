# case-chatguru

Case técnico: API Flask simples, containerizada e implantada em Kubernetes
(cluster local via [kind](https://kind.sigs.k8s.io/)), com dois ambientes
(`dev` e `prod`) gerenciados via [Kustomize](https://kustomize.io/) e uma
pipeline de CI/CD no GitHub Actions que testa, valida, builda e faz o deploy
end-to-end de forma automatizada antes de publicar a imagem.

## Sumário

- [Arquitetura](#arquitetura)
- [Estrutura do projeto](#estrutura-do-projeto)
- [Endpoints da API](#endpoints-da-api)
- [Executando a aplicação](#executando-a-aplicação)
- [Pré-requisitos (Kubernetes / kind)](#pré-requisitos-kubernetes--kind)
- [Quickstart (Kubernetes local via kind)](#quickstart-kubernetes-local-via-kind)
- [Scripts disponíveis](#scripts-disponíveis)
- [Ambientes: dev vs prod](#ambientes-dev-vs-prod)
- [Pipeline de CI/CD](#pipeline-de-cicd)
- [Decisões de projeto](#decisões-de-projeto)
- [Troubleshooting](#troubleshooting)

## Arquitetura

```
Dev machine / GitHub Actions runner
        │
        │ docker build
        v
  ghcr.io/wllgomes/case-chatguru (imagem)
        │
        │ kind load docker-image
        v
┌─────────────────────────── cluster kind ───────────────────────────┐
│                                                                    │
│  ingress-nginx (controller)                                        │
│       │                                                            │
│       ├── Host: dev.case-chatguru.local  --> ns case-chatguru-dev  │
│       │                                       Deployment (1 pod)   │
│       │                                       Service ClusterIP    │
│       │                                                            │
│       └── Host: prod.case-chatguru.local --> ns case-chatguru-prod │
│                                               Deployment (2 pods)  │
│                                               Service ClusterIP    │
└────────────────────────────────────────────────────────────────────┘
```

A aplicação é a mesma imagem em qualquer ambiente — o que muda entre `dev` e
`prod` é só configuração (via Kustomize overlays): número de réplicas,
requests/limits de CPU/memória, `APP_ENV` e o host do Ingress.

## Estrutura do projeto

```
app/                        Código da aplicação (Flask)
  main.py                     Rotas: /, /health, /healthz, /info
  requirements.txt            Dependências de runtime
  requirements-dev.txt        Dependências de teste
  tests/test_main.py          Testes unitários (pytest)

k8s/
  base/                      Manifests base (recurso "canônico")
    deployment.yaml            Deployment com probes, resources, envFrom
    service.yaml                Service ClusterIP
    configmap.yaml               APP_ENV / APP_VERSION
    ingress.yaml                  Ingress (nginx)
    kustomization.yaml
  overlays/
    dev/                       Patches: 1 réplica, resources menores,
                                host dev.case-chatguru.local
    prod/                      Patches: 2 réplicas, resources maiores,
                                host prod.case-chatguru.local

kind/kind-config.yaml       Cluster kind com portas 80/443 mapeadas
                             (necessário para o ingress-nginx)

scripts/
  setup-kind.sh              Cria o cluster kind + instala ingress-nginx
  deploy.sh                  Aplica um overlay e aguarda o rollout
  smoke-test.sh               Valida a aplicação já implantada (Service + Ingress)
  install-kubeconform.sh       Instala o kubeconform em .bin/ (usado na validação)
  destroy-kind.sh             Destrói o cluster

.github/workflows/ci-cd.yaml  Pipeline: testes → validação de manifests →
                               deploy real no kind → smoke test → publish

Dockerfile                  Imagem final: python:3.12-slim + gunicorn,
                             non-root, com HEALTHCHECK
```

## Endpoints da API

| Rota        | Descrição                                              |
|-------------|---------------------------------------------------------|
| `GET /`     | Mensagem de boas-vindas                                 |
| `GET /health` / `/healthz` | Health check usado pelos probes do Kubernetes |
| `GET /info` | Versão da aplicação, ambiente (`APP_ENV`) e hostname do pod |

## Executando a aplicação

Duas formas simples de rodar só a API, sem precisar de Kubernetes.

### Localmente (Python)

```bash
python3 -m venv app/.venv
source app/.venv/bin/activate
pip install -r app/requirements.txt -r app/requirements-dev.txt

APP_VERSION=1.0.0 APP_ENV=local python app/main.py
```

A API sobe em `http://localhost:8080` (servidor de desenvolvimento do Flask).

```bash
curl http://localhost:8080/health
curl http://localhost:8080/info
```

### Via Docker

```bash
docker build -t case-chatguru:local .

docker run --rm -p 8080:8080 \
  -e APP_VERSION=1.0.0 \
  -e APP_ENV=docker-local \
  case-chatguru:local
```

```bash
curl http://localhost:8080/health
curl http://localhost:8080/info
```

`APP_VERSION` e `APP_ENV` são lidas de variáveis de ambiente (em Kubernetes,
vêm do `ConfigMap` — ver [`k8s/base/configmap.yaml`](k8s/base/configmap.yaml))
e retornadas pelo endpoint `/info`, junto com o hostname do processo/pod.

### Rodando os testes

```bash
pip install -r app/requirements.txt -r app/requirements-dev.txt
pytest -v
```

## Pré-requisitos (Kubernetes / kind)

Para o restante deste README — subir a aplicação em um cluster Kubernetes
local via kind — você vai precisar de:

- [Docker](https://docs.docker.com/get-docker/)
- [kind](https://kind.sigs.k8s.io/) `v0.24.0` (o script instala automaticamente se não encontrar)
- [kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl)

Nenhuma outra ferramenta precisa ser instalada manualmente: `kind` (via
`scripts/setup-kind.sh`) e `kubeconform` (via `scripts/install-kubeconform.sh`,
usado na validação dos manifests) se auto-instalam na primeira execução,
sem precisar de `sudo` nem de um gerenciador de pacotes.

Instruções detalhadas de deploy passo a passo (inclusive para um cluster
Kubernetes real, fora do kind) estão em [`DEPLOY.md`](DEPLOY.md).

## Quickstart (Kubernetes local via kind)

Os dois overlays já apontam para tags publicadas e públicas no GHCR (`dev`
usa `latest`, `prod` fixa uma tag por SHA — ver [Ambientes](#ambientes-dev-vs-prod)),
então o cluster consegue puxar a imagem direto da internet. **Não é
necessário buildar nada localmente** para reproduzir o deploy:

```bash
# 1. Testes
pip install -r app/requirements.txt -r app/requirements-dev.txt
pytest -v

# 2. Validar os manifests (kubeconform se auto-instala em .bin/ na primeira vez)
./scripts/install-kubeconform.sh
for t in k8s/base k8s/overlays/dev k8s/overlays/prod; do
  kubectl kustomize "$t" | ./.bin/kubeconform -strict -summary -
done

# 3. Subir o cluster kind + ingress-nginx
./scripts/setup-kind.sh

# 4. Deploy nos dois ambientes (a imagem é puxada do GHCR)
./scripts/deploy.sh dev
./scripts/deploy.sh prod

# 5. Conferir que está tudo no ar
./scripts/smoke-test.sh dev
./scripts/smoke-test.sh prod
```

Para acessar via Ingress com o host correto, use o header `Host` (não é
necessário editar `/etc/hosts`):

```bash
curl -H "Host: dev.case-chatguru.local"  http://localhost/info
curl -H "Host: prod.case-chatguru.local" http://localhost/info
```

Ao terminar:

```bash
./scripts/destroy-kind.sh
```

### Testando uma alteração local antes de publicar

Se você mudou o código e quer testar antes de dar `push`, construa a
imagem e carregue-a manualmente no kind (ver o aviso sobre isolamento do
kind em [`DEPLOY.md`](DEPLOY.md#3-construindo-e-disponibilizando-a-imagem-para-o-cluster)),
sobrescrevendo a tag do overlay via `IMAGE=`:

```bash
docker build -t ghcr.io/wllgomes/case-chatguru:local .
kind load docker-image ghcr.io/wllgomes/case-chatguru:local --name case-chatguru
IMAGE=ghcr.io/wllgomes/case-chatguru:local ./scripts/deploy.sh dev
```

Passo a passo detalhado (inclusive fora do kind) em [`DEPLOY.md`](DEPLOY.md).

## Scripts disponíveis

Sem Makefile de propósito — cada script é independente, chamável direto, e
é exatamente o que a pipeline de CI roda (nenhuma lógica de orquestração
duplicada em outro lugar):

| Script | O que faz |
|---|---|
| `scripts/setup-kind.sh` | Cria o cluster kind (`kind/kind-config.yaml`) e instala o ingress-nginx |
| `scripts/install-kubeconform.sh` | Instala o `kubeconform` em `.bin/` (usado na validação dos manifests) |
| `scripts/deploy.sh <dev\|prod>` | Cria o namespace, aplica o overlay e aguarda o rollout |
| `scripts/smoke-test.sh <dev\|prod>` | Valida a aplicação já implantada (via Service e via Ingress) |
| `scripts/destroy-kind.sh` | Destrói o cluster kind |

Logs de um ambiente já implantado:

```bash
kubectl -n case-chatguru-dev  logs -l app=case-chatguru -f
kubectl -n case-chatguru-prod logs -l app=case-chatguru -f
```

## Ambientes: dev vs prod

Ambos nascem do mesmo `k8s/base`, via Kustomize `namePrefix` + `namespace`
+ `patches`. Nenhum manifest é duplicado — as diferenças ficam só nos
patches de cada overlay.

| | dev | prod |
|---|---|---|
| Namespace | `case-chatguru-dev` | `case-chatguru-prod` |
| Réplicas | 1 | 2 |
| CPU request/limit | 25m / 100m | 100m / 500m |
| Memória request/limit | 32Mi / 64Mi | 128Mi / 256Mi |
| Host do Ingress | `dev.case-chatguru.local` | `prod.case-chatguru.local` |
| Tag de imagem | `latest` (acompanha `main`) | `sha-2953c21` (fixada) |

`dev` sempre aponta para a última imagem publicada em `main` (`latest`).
`prod` fixa uma tag imutável por SHA do commit — deliberadamente **não**
acompanha `main` sozinho. Promover uma nova versão para prod é uma ação
explícita: escolher a tag `sha-<commit>` já publicada pela pipeline (ver
[Pipeline de CI/CD](#pipeline-de-cicd)), atualizar `newTag` em
[`k8s/overlays/prod/kustomization.yaml`](k8s/overlays/prod/kustomization.yaml)
e comitar — o histórico do git vira o histórico de releases de prod.

## Pipeline de CI/CD

`.github/workflows/ci-cd.yaml` roda em todo push/PR para `main` (e sob
demanda via `workflow_dispatch`), com 4 jobs encadeados:

1. **`test`** — instala dependências e roda `pytest`.
2. **`validate-manifests`** — renderiza os três alvos (`base`, `overlays/dev`,
   `overlays/prod`) com `kustomize build` e valida o YAML resultante contra
   o schema oficial da API do Kubernetes com
   [kubeconform](https://github.com/yannh/kubeconform). Isso pega erros que
   `kustomize build` sozinho deixa passar (um campo com o nome errado num
   patch, por exemplo, renderiza sem erro e só quebraria no `kubectl apply`).
3. **`deploy-kind`** — builda a imagem, sobe um cluster kind efêmero com o
   mesmo `scripts/setup-kind.sh` executado localmente, carrega a
   imagem via `kind load docker-image` (sem depender de registry — funciona
   igual em PR de fork), faz o deploy real em `dev` e `prod`, roda o smoke
   test em cada um, e por fim **destrói o cluster** (`if: always()`, mesmo
   se algo falhar). Se qualquer etapa falhar, um passo de diagnóstico coleta
   pods, eventos e logs do cluster antes de encerrar.
4. **`publish`** — só roda em push para `main` e só depois do `deploy-kind`
   ter passado. Builda e publica a imagem no GHCR com tags por SHA e
   `latest`. Ou seja: **nada é publicado sem antes provar que sobe de
   verdade em um cluster Kubernetes.**

## Decisões de projeto

- **Kustomize em vez de Helm**: o projeto tem só dois ambientes com
  diferenças pequenas (réplicas, resources, host, tag de imagem) — overlays
  com patches são suficientes e mais diretos de ler do que um chart com
  `values.yaml`.
- **`kind load docker-image` em vez de registry na pipeline de deploy**: o
  job de deploy-kind não depende de credenciais nem de rede externa para
  colocar a imagem no cluster, então roda igual em PRs de forks. A imagem só
  vai para o GHCR depois de passar no deploy real.
- **Imagem fixada por SHA do commit no deploy da CI** (`IMAGE=` em
  `scripts/deploy.sh`), em vez de depender da tag `latest` do overlay:
  garante que o smoke test valida exatamente o artefato que acabou de ser
  construído — e não uma versão diferente que porventura já esteja
  publicada com essa tag.
- **`prod` pina uma tag por SHA em vez de `latest`**: evita que o
  ambiente de produção mude sozinho a cada novo `push` em `main` sem uma
  decisão explícita de promoção (só `dev` acompanha `main` automaticamente).
- **`kubeconform` além de `kustomize build`**: overlays com Kustomize
  aceitam silenciosamente campos com nome errado dentro de um patch — o
  `kubectl kustomize` renderiza normalmente, e o erro só aparece no
  `kubectl apply` contra o cluster real. Validar o YAML final contra o
  schema da API pega esse tipo de problema antes do deploy.
- **Smoke test em duas camadas** (`scripts/smoke-test.sh`): via
  `port-forward` direto no Service (prova que o Pod está de fato servindo
  tráfego) e via Ingress com header `Host` (prova que o roteamento externo
  funciona) — as duas coisas podem falhar independentemente.
- **Versão do ingress-nginx fixada** (`controller-v1.13.0`) em vez de
  apontar para `main` do repositório: evita que o setup do cluster quebre
  sozinho quando o upstream mudar.

## Troubleshooting

**Pods não sobem / `ImagePullBackOff`**
Duas causas prováveis:

1. Você apontou `IMAGE=` para uma tag que só existe localmente (ex.: uma
   imagem que você acabou de buildar) sem carregá-la no cluster antes — o
   kind roda isolado do Docker do host, então `docker build` sozinho não
   basta (detalhes em
   [`DEPLOY.md`](DEPLOY.md#3-construindo-e-disponibilizando-a-imagem-para-o-cluster)):

   ```bash
   docker build -t ghcr.io/wllgomes/case-chatguru:local .
   kind load docker-image ghcr.io/wllgomes/case-chatguru:local --name case-chatguru
   ```

2. O nó do kind não tem acesso à internet para puxar a tag publicada
   (`latest`/`sha-*`) do GHCR — confira com
   `kubectl describe pod -n <namespace> <pod>` a mensagem exata do evento
   `Failed`.

**Ingress retorna 404**
Confira se está enviando o header `Host` correto (`dev.case-chatguru.local`
ou `prod.case-chatguru.local`) — sem ele o nginx não sabe para qual serviço
rotear.

**Rollout trava em `scripts/deploy.sh dev`/`prod`**
Investigue o estado dos pods diretamente:

```bash
kubectl -n case-chatguru-dev get pods
kubectl -n case-chatguru-dev describe deployment dev-case-chatguru
kubectl -n case-chatguru-dev logs -l app=case-chatguru
```

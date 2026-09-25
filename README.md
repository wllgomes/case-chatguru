# case-chatguru

Case técnico: API Flask simples, containerizada e implantada em Kubernetes
(cluster local via [kind](https://kind.sigs.k8s.io/)), com dois ambientes
(`stg` e `prod`) gerenciados via [Kustomize](https://kustomize.io/) e uma
pipeline de CI/CD no GitHub Actions que testa, valida os manifests,
publica a imagem no GHCR e realiza deploy automatizado em staging, com
promoção controlada para produção.

## Sumário

- [Arquitetura](#arquitetura)
- [Estrutura do projeto](#estrutura-do-projeto)
- [Endpoints da API](#endpoints-da-api)
- [Executando a aplicação](#executando-a-aplicação)
- [Pré-requisitos (Kubernetes / kind)](#pré-requisitos-kubernetes--kind)
- [Quickstart (Kubernetes local via kind)](#quickstart-kubernetes-local-via-kind)
- [Scripts disponíveis](#scripts-disponíveis)
- [Ambientes: stg vs prod](#ambientes-stg-vs-prod)
- [Ambiente de demonstração pública](#ambiente-de-demonstração-pública)
- [Pipeline de CI/CD](#pipeline-de-cicd)
- [Decisões de projeto](#decisões-de-projeto)
- [Evolução futura: promoção por branch](#evolução-futura-promoção-por-branch)
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
│       ├── Host: stg.case-chatguru.local  --> ns case-chatguru-stg  │
│       │                                       Deployment (1 pod)   │
│       │                                       Service ClusterIP    │
│       │                                                            │
│       └── Host: prod.case-chatguru.local --> ns case-chatguru-prod │
│                                               Deployment (2 pods)  │
│                                               Service ClusterIP    │
└────────────────────────────────────────────────────────────────────┘
```

A aplicação é a mesma imagem em qualquer ambiente — o que muda entre `stg` e
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
    stg/                       Patches: 1 réplica, resources menores,
                                host stg.case-chatguru.local
    prod/                      Patches: 2 réplicas, resources maiores,
                                host prod.case-chatguru.local
    stg-aws/                   Herda de stg/, troca host/TLS para o
                                servidor de demonstração pública
    prod-aws/                  Herda de prod/, troca host/TLS para o
                                servidor de demonstração pública

kind/kind-config.yaml       Cluster kind com portas 80/443 mapeadas
                             (necessário para o ingress-nginx)

scripts/
  setup-kind.sh              Cria o cluster kind + instala ingress-nginx
  deploy.sh                  Aplica um overlay e aguarda o rollout
  smoke-test.sh               Valida a aplicação já implantada (Service + Ingress)
  install-kubeconform.sh       Instala o kubeconform em .bin/ (usado na validação)
  destroy-kind.sh             Destrói o cluster

.github/workflows/ci-cd.yaml  Pipeline: testes → validação de manifests →
                               publish (GHCR) → deploy no servidor AWS

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

Os dois overlays já apontam para tags publicadas e públicas no GHCR (`stg`
usa `latest`, `prod` fixa uma tag por SHA — ver [Ambientes](#ambientes-stg-vs-prod)),
então o cluster consegue puxar a imagem direto da internet. **Não é
necessário buildar nada localmente** para reproduzir o deploy:

```bash
# 1. Testes
pip install -r app/requirements.txt -r app/requirements-dev.txt
pytest -v

# 2. Validar os manifests (kubeconform se auto-instala em .bin/ na primeira vez)
./scripts/install-kubeconform.sh
for t in k8s/base k8s/overlays/stg k8s/overlays/prod; do
  kubectl kustomize "$t" | ./.bin/kubeconform -strict -summary -
done

# 3. Subir o cluster kind + ingress-nginx
./scripts/setup-kind.sh

# 4. Deploy nos dois ambientes (a imagem é puxada do GHCR)
./scripts/deploy.sh stg
./scripts/deploy.sh prod

# 5. Conferir que está tudo no ar
./scripts/smoke-test.sh stg
./scripts/smoke-test.sh prod
```

Para acessar via Ingress com o host correto, use o header `Host` (não é
necessário editar `/etc/hosts`):

```bash
curl -H "Host: stg.case-chatguru.local"  http://localhost/info
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
IMAGE=ghcr.io/wllgomes/case-chatguru:local ./scripts/deploy.sh stg
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
| `scripts/deploy.sh <stg\|prod>` | Cria o namespace, aplica o overlay e aguarda o rollout |
| `scripts/smoke-test.sh <stg\|prod>` | Valida a aplicação já implantada (via Service e via Ingress) |
| `scripts/destroy-kind.sh` | Destrói o cluster kind |

Logs de um ambiente já implantado:

```bash
kubectl -n case-chatguru-stg  logs -l app=case-chatguru -f
kubectl -n case-chatguru-prod logs -l app=case-chatguru -f
```

## Ambientes: stg vs prod

Ambos nascem do mesmo `k8s/base`, via Kustomize `namePrefix` + `namespace`
+ `patches`. Nenhum manifest é duplicado — as diferenças ficam só nos
patches de cada overlay.

| | stg | prod |
|---|---|---|
| Namespace | `case-chatguru-stg` | `case-chatguru-prod` |
| Réplicas | 1 | 2 |
| CPU request/limit | 25m / 100m | 100m / 500m |
| Memória request/limit | 32Mi / 64Mi | 128Mi / 256Mi |
| Host do Ingress | `stg.case-chatguru.local` | `prod.case-chatguru.local` |
| Tag de imagem | `latest` (acompanha `main`) | `sha-2953c21` (fixada) |

`stg` sempre aponta para a última imagem publicada em `main` (`latest`).
`prod` fixa uma tag imutável por SHA do commit — deliberadamente **não**
acompanha `main` sozinho. Promover uma nova versão para prod é uma ação
explícita: escolher a tag `sha-<commit>` já publicada pela pipeline (ver
[Pipeline de CI/CD](#pipeline-de-cicd)), atualizar `newTag` em
[`k8s/overlays/prod/kustomization.yaml`](k8s/overlays/prod/kustomization.yaml)
e comitar — o histórico do git vira o histórico de releases de prod.

## Ambiente de demonstração pública

Além dos overlays `stg`/`prod` (host fictício, pensados para reprodução
local via kind — ver [DEPLOY.md](DEPLOY.md)), existe um servidor real na
AWS servindo a aplicação publicamente, com TLS válido via Let's Encrypt:

| Ambiente | URL |
|---|---|
| stg | https://case-chatguru-stg.duckdns.org |
| prod | https://case-chatguru-prod.duckdns.org |

Esse servidor roda [k3s](https://k3s.io/) (Kubernetes real, não kind) numa
instância EC2, com `ingress-nginx` + `cert-manager` emitindo certificados
via `ClusterIssuer` do Let's Encrypt, e DNS apontando para o IP público
via [DuckDNS](https://www.duckdns.org/). **DuckDNS foi usado apenas para
fornecer DNS público estável no ambiente de demonstração** — não é uma
escolha de produção; em produção o normal seria um domínio próprio numa
zona DNS gerenciada (Route53, Cloudflare, etc.).

Os overlays [`k8s/overlays/stg-aws`](k8s/overlays/stg-aws) e
[`k8s/overlays/prod-aws`](k8s/overlays/prod-aws) existem só para esse
propósito: cada um herda o overlay correspondente (`../stg`, `../prod`)
via `resources:` e aplica um único patch trocando host/TLS/anotação do
`cert-manager` pelos domínios reais — sem duplicar Deployment, Service ou
ConfigMap, e sem alterar os overlays originais que o restante desta
documentação descreve. São esses overlays que os jobs `deploy-stg-aws` e
`deploy-prod-aws` da pipeline aplicam (ver [Pipeline de CI/CD](#pipeline-de-cicd)).

Esse servidor é temporário (mantido apenas para avaliação) e não faz
parte do escopo obrigatório do desafio — existe só para dar aos
avaliadores um link clicável, além do repositório.

## Pipeline de CI/CD

`.github/workflows/ci-cd.yaml` roda em todo push/PR para `main` (e sob
demanda via `workflow_dispatch`), com 5 jobs encadeados:

```
push main
  ├─ test ─────────────┐
  └─ validate-manifests ┤
                        v
                     publish (GHCR)
                        │
                        v
                  deploy-stg-aws
                        │
                        v
                 [aprovação manual]
                        │
                        v
                  deploy-prod-aws
```

1. **`test`** — instala dependências e roda `pytest`.
2. **`validate-manifests`** — renderiza os cinco alvos (`base`, `overlays/stg`,
   `overlays/prod`, `overlays/stg-aws`, `overlays/prod-aws`) com
   `kustomize build` e valida o YAML resultante contra o schema oficial da
   API do Kubernetes com [kubeconform](https://github.com/yannh/kubeconform).
   Isso pega erros que `kustomize build` sozinho deixa passar (um campo com
   o nome errado num patch, por exemplo, renderiza sem erro e só quebraria
   no `kubectl apply`).
3. **`publish`** — só roda em push para `main`, depois de `test` e
   `validate-manifests` passarem. Builda e publica a imagem no GHCR com
   tags por SHA (longa e curta) e `latest`.
4. **`deploy-stg-aws`** — só roda depois do `publish`. Via SSH (chave em
   `secrets.AWS_DEMO_SSH_KEY`, host em `vars.AWS_DEMO_HOST`), aplica
   `k8s/overlays/stg-aws` no servidor de demonstração pública (ver
   [Ambiente de demonstração pública](#ambiente-de-demonstração-pública)),
   fixando a imagem na tag `sha-<commit>` que acabou de ser publicada, e
   roda `scripts/smoke-test.sh` contra o host/TLS real. Uma falha aqui
   **derruba a pipeline inteira** (sem `continue-on-error`) — esse
   ambiente é parte da entrega, não um extra opcional.
5. **`deploy-prod-aws`** — só roda depois do `deploy-stg-aws`, e só depois
   de uma **aprovação manual**: o job usa o
   [Environment](https://docs.github.com/actions/deployment/targeting-different-environments/using-environments-for-deployment)
   `production`, configurado com *required reviewers*, então a execução
   fica pausada em "Review deployments" até alguém aprovar
   explicitamente. Só então aplica `k8s/overlays/prod-aws` e roda o smoke
   test contra o prod real. Isso espelha a mesma filosofia de "prod muda
   por decisão explícita" que já vale para a tag fixada no overlay
   `prod` (ver [Ambientes](#ambientes-stg-vs-prod)) — só que agora
   também no ambiente de demonstração pública, não só no overlay.

Diferente do modelo anterior (kind efêmero, destruído a cada run), o
servidor da AWS é **persistente** — os jobs nunca o destroem, só
atualizam os Deployments nele.

## Decisões de projeto

- **Kustomize em vez de Helm**: o projeto tem só dois ambientes com
  diferenças pequenas (réplicas, resources, host, tag de imagem) — overlays
  com patches são suficientes e mais diretos de ler do que um chart com
  `values.yaml`.
- **`publish` roda antes do deploy, não depois**: a versão anterior desta
  pipeline testava num cluster kind efêmero primeiro (usando
  `kind load docker-image`, sem precisar de registry) e só publicava no
  GHCR depois de provar que subia. Isso funcionava porque o kind é local
  ao runner. O servidor de demonstração é remoto e puxa a imagem pela
  rede — não existe "carregar localmente" num host que não é o runner —
  então a imagem precisa estar publicada **antes** do deploy poder
  acontecer. A validação de manifests (`kubeconform`) continua rodando
  antes de tudo, então um erro óbvio de manifest ainda barra a pipeline
  antes de publicar qualquer coisa.
- **Overlays `stg-aws`/`prod-aws` em vez de editar `stg`/`prod`
  diretamente**: eles herdam o overlay original via `resources:` e só
  sobrescrevem host/TLS/anotação do `cert-manager` num patch — uma
  aplicação imperativa (`kubectl patch` direto no cluster) foi descartada
  porque `kubectl apply` reverte esse tipo de patch na próxima execução da
  pipeline (o campo `host` está declarado no manifest original, então um
  novo `apply` o sobrescreve de volta). Com overlay dedicado, cada `apply`
  é idempotente e correto — sem depender de estado imperativo escondido.
- **Imagem fixada por SHA do commit no deploy** (`IMAGE=` em
  `scripts/deploy.sh`), em vez de depender só da tag `latest` do overlay:
  garante que cada deploy do `stg` puxe exatamente o artefato que acabou
  de ser construído (com `imagePullPolicy: IfNotPresent`, uma tag nova e
  única força um pull fresco sem depender do Kubernetes perceber que a
  tag "mudou de conteúdo" — o que ele nunca percebe sozinho).
- **`prod` pina uma tag por SHA em vez de `latest`**: evita que o
  ambiente de produção mude sozinho a cada novo `push` em `main` sem uma
  decisão explícita de promoção (só `stg` acompanha `main` automaticamente).
- **`imagePullPolicy: IfNotPresent` explícito no Deployment**: sem isso, o
  Kubernetes decide a política sozinho com base na tag ser ou não
  literalmente `latest` — e essa decisão fica **gravada no objeto desde a
  criação**, sobrevivendo até a um `kubectl set image` posterior que troque
  a tag por outra coisa. Foi exatamente o bug que pegamos aqui: o overlay
  `stg` cria o Deployment com a tag `latest` (política vira `Always` por
  default), e a CI depois troca a imagem via `kubectl set image` para uma
  tag que só existe localmente (carregada via `kind load docker-image`) —
  sem o `IfNotPresent` explícito, o kubelet insistia em puxar da rede uma
  tag que nunca foi publicada em lugar nenhum, e o pod ficava em
  `ImagePullBackOff`.
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

## Evolução futura: promoção por branch

O repositório roda num único branch (`main`), como o desafio pede
explicitamente ("disparado em push/PR para a branch principal", no
singular). A promoção controlada pra produção já existe hoje em duas
camadas: a tag de imagem fixada manualmente em
`k8s/overlays/prod/kustomization.yaml` (ver
[Ambientes](#ambientes-stg-vs-prod)), e o
[Environment](https://docs.github.com/actions/deployment/targeting-different-environments/using-environments-for-deployment)
`production` com *required reviewers* que pausa o `deploy-prod-aws` até
alguém aprovar manualmente (ver [Pipeline de CI/CD](#pipeline-de-cicd)).

O que ainda falta, e como eu estruturaria num ambiente real com múltiplos
desenvolvedores, é um modelo por branch: `stg` como branch de integração
(merge dispara deploy automático em staging) e `main` protegido, só
atualizado via PR de `stg` — a promoção vira um PR revisado, em vez de um
commit editando uma tag. Não implementei isso aqui porque o desafio pede
só um branch principal, e a aprovação manual via `Environment` já resolve
o problema de fundo (produção não muda sem decisão humana) sem o risco de
reestruturar branches a poucos dias da entrega.

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
Confira se está enviando o header `Host` correto (`stg.case-chatguru.local`
ou `prod.case-chatguru.local`) — sem ele o nginx não sabe para qual serviço
rotear.

**Rollout trava em `scripts/deploy.sh stg`/`prod`**
Investigue o estado dos pods diretamente:

```bash
kubectl -n case-chatguru-stg get pods
kubectl -n case-chatguru-stg describe deployment stg-case-chatguru
kubectl -n case-chatguru-stg logs -l app=case-chatguru
```

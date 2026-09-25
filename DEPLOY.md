# Deploy — passo a passo

Este documento descreve, do zero, como subir o `case-chatguru` em um cluster
Kubernetes: pré-requisitos, comandos de `kustomize build` / `kubectl apply`,
como acessar a aplicação depois de publicada e como trocar de overlay
(`stg` ↔ `prod`).

Os comandos abaixo funcionam contra **qualquer** cluster Kubernetes — o
guia usa [kind](https://kind.sigs.k8s.io/) como exemplo por ser o mais
simples de reproduzir localmente, mas os manifests não têm nenhuma
dependência de kind. A seção final trata das diferenças ao usar um cluster
gerenciado real (cloud).

## 1. Pré-requisitos

| Ferramenta | Uso | Instalação |
|---|---|---|
| `docker` | build da imagem e (no caso do kind) runtime do cluster | https://docs.docker.com/get-docker/ |
| `kubectl` (≥ 1.27, já traz `kustomize` embutido) | aplicar os manifests | https://kubernetes.io/docs/tasks/tools/#kubectl |
| `kind` (só se for usar um cluster local) | criar o cluster | https://kind.sigs.k8s.io/ |

Um cluster Kubernetes já acessível via `kubectl` (contexto atual configurado)
com um **Ingress controller nginx** instalado — os manifests deste repositório
usam `ingressClassName: nginx`.

Verifique o contexto atual antes de aplicar qualquer coisa:

```bash
kubectl config current-context
kubectl cluster-info
```

## 2. Subindo um cluster do zero (kind)

Se você ainda não tem um cluster, o script abaixo cria um cluster kind com
as portas 80/443 mapeadas para o host e instala o ingress-nginx:

```bash
./scripts/setup-kind.sh
```

Isso cria o cluster `case-chatguru` e aguarda o ingress-nginx controller
ficar pronto. Ao final, o contexto `kind-case-chatguru` já fica ativo.

## 3. Construindo e disponibilizando a imagem para o cluster

> **⚠️ Ponto importante sobre o kind:** um cluster kind roda totalmente
> isolado dentro de containers Docker (cada "nó" é, na prática, um
> container) — ele **não** compartilha o daemon Docker do host, nem o
> cache de imagens locais, nem tem acesso a registries privados por
> padrão. Ou seja: rodar `docker build` na sua máquina deixa a imagem
> disponível para o `docker run` do host, mas o **containerd de dentro do
> cluster kind não enxerga essa imagem**. Se você aplicar os manifests
> apontando para uma tag que só existe localmente, o Pod fica preso em
> `ImagePullBackOff` — o `kubectl describe pod` mostra algo como
> `Failed to pull image ... not found`.
>
> A saída é sempre uma destas duas:
> 1. `kind load docker-image <tag> --name case-chatguru` — injeta a
>    imagem já construída localmente direto no containerd dos nós do
>    cluster (é o que este projeto faz; ver o passo abaixo).
> 2. Dar `push` da imagem para um registry real (GHCR, Docker Hub, etc.)
>    e deixar o cluster puxá-la de lá — necessário em qualquer cluster que
>    **não** seja kind (cloud, minikube com driver diferente, etc.), já
>    que esses não têm o comando `kind load`.

Os dois overlays deste repositório já apontam para tags publicadas e
**públicas** no GHCR — `stg` usa `latest` (acompanha `main`), `prod` fixa
uma tag imutável por SHA do commit (ver a tabela em
[README](README.md#ambientes-stg-vs-prod)). Qualquer cluster com acesso à
internet consegue puxá-las diretamente, sem nenhum passo extra: **pule
para a seção 4** se for usar essas imagens (o caso comum).

Se preferir construir a imagem você mesmo (por exemplo, para testar uma
alteração local antes de publicar):

```bash
docker build -t ghcr.io/wllgomes/case-chatguru:local .
```

Em um cluster **kind**, carregue a imagem local nos nós (ver o ponto
importante acima):

```bash
kind load docker-image ghcr.io/wllgomes/case-chatguru:local --name case-chatguru
```

Em um cluster **real** (cloud), você precisa dar `push` da imagem para um
registry que o cluster consiga puxar (o próprio GHCR, por exemplo) e então
apontar para ela no passo 4.

## 4. Revisando os manifests antes de aplicar (`kustomize build`)

Cada overlay pode ser renderizado localmente para conferência antes de
aplicar no cluster — nenhum comando aqui altera o cluster:

```bash
# Base "crua", sem overlay (não é o que se aplica em uso real)
kubectl kustomize k8s/base

# Overlay de stg — o que de fato é aplicado no ambiente stg
kubectl kustomize k8s/overlays/stg

# Overlay de prod — o que de fato é aplicado no ambiente prod
kubectl kustomize k8s/overlays/prod
```

Vale conferir principalmente: `replicas`, `resources`, a tag de imagem
(`images:` no `kustomization.yaml` de cada overlay) e o `host` do `Ingress`.

Para validar o YAML renderizado contra o schema oficial da API do
Kubernetes (o mesmo passo que a pipeline de CI roda), use o
[kubeconform](https://github.com/yannh/kubeconform):

```bash
./scripts/install-kubeconform.sh   # instala em .bin/, sem precisar de sudo
kubectl kustomize k8s/overlays/stg | ./.bin/kubeconform -strict -summary -
```

## 5. Aplicando no cluster (`kubectl apply -k`)

O script `scripts/deploy.sh` encapsula os passos abaixo (cria o namespace,
aplica o overlay e aguarda o rollout) — é a forma recomendada:

```bash
./scripts/deploy.sh stg
./scripts/deploy.sh prod
```

Isso é equivalente, no fundo, a:

```bash
kubectl create namespace case-chatguru-stg --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -k k8s/overlays/stg
kubectl -n case-chatguru-stg rollout status deployment/stg-case-chatguru --timeout=120s
```

(troque `stg` por `prod` e `stg-case-chatguru` por `prod-case-chatguru` para
o outro ambiente).

Para fixar uma imagem específica (por exemplo, a que você acabou de
construir/carregar no passo 3), exporte `IMAGE` antes de rodar o script:

```bash
IMAGE=ghcr.io/wllgomes/case-chatguru:local ./scripts/deploy.sh stg
```

## 6. Conferindo que subiu

```bash
kubectl -n case-chatguru-stg get deploy,pods,svc,ingress
```

Saída esperada (resumida):

```
NAME                                READY   UP-TO-DATE   AVAILABLE
deployment.apps/stg-case-chatguru   1/1     1            1

NAME                                     READY   STATUS
pod/stg-case-chatguru-xxxxxxxxxx-xxxxx   1/1     Running

NAME                        TYPE        CLUSTER-IP
service/stg-case-chatguru   ClusterIP   10.x.x.x

NAME                                          CLASS   HOSTS
ingress.networking.k8s.io/stg-case-chatguru   nginx   stg.case-chatguru.local
```

## 7. Acessando a aplicação depois de publicada

O host configurado no Ingress é fictício (`stg.case-chatguru.local` /
`prod.case-chatguru.local`), então não existe DNS público apontando para
ele. Duas formas de acessar:

**Opção A — header `Host` direto no `curl`** (não precisa editar nada no
sistema; funciona em qualquer cluster onde você tenha o IP/host do Ingress):

```bash
# kind local: o ingress-nginx escuta em localhost:80/443
curl -H "Host: stg.case-chatguru.local"  http://localhost/health
curl -H "Host: stg.case-chatguru.local"  http://localhost/info

curl -H "Host: prod.case-chatguru.local" http://localhost/health
curl -H "Host: prod.case-chatguru.local" http://localhost/info
```

Em um cluster cloud, troque `http://localhost` pelo IP/hostname público do
Load Balancer do ingress controller:

```bash
INGRESS_IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -H "Host: stg.case-chatguru.local" "http://$INGRESS_IP/info"
```

**Opção B — editar `/etc/hosts`** (para navegar pelo browser):

```
127.0.0.1  stg.case-chatguru.local prod.case-chatguru.local
```

(aponte para o IP real do Ingress em vez de `127.0.0.1` caso não seja um
cluster local).

**Opção C — sem depender do Ingress**, direto no Service, útil para depurar:

```bash
kubectl -n case-chatguru-stg port-forward svc/stg-case-chatguru 8080:80
curl http://localhost:8080/info
```

O script `scripts/smoke-test.sh stg` (ou `prod`) automatiza as opções A e C
com verificações de conteúdo da resposta.

## 8. Trocando de overlay (stg ↔ prod)

Não existe um "trocar" no sentido de alternar estado — `stg` e `prod` são
namespaces e recursos **independentes**, nascidos do mesmo `k8s/base`. Os
dois podem coexistir no mesmo cluster ao mesmo tempo. Para atuar em um ou
outro, basta apontar o comando para o overlay correspondente:

```bash
kubectl apply -k k8s/overlays/stg    # cria/atualiza o ambiente stg
kubectl apply -k k8s/overlays/prod   # cria/atualiza o ambiente prod
```

As diferenças entre eles (réplicas, resources, host do Ingress, tag de
imagem) estão declaradas nos respectivos `k8s/overlays/<ambiente>/` — ver
a tabela comparativa no [README](README.md#ambientes-stg-vs-prod).

**Promovendo uma nova versão para prod**: como `prod` fixa uma tag
imutável por SHA (em vez de acompanhar `latest` automaticamente), subir
uma nova versão é uma edição deliberada de
[`k8s/overlays/prod/kustomization.yaml`](k8s/overlays/prod/kustomization.yaml)
— troque `images[].newTag` para a tag `sha-<commit>` que a pipeline já
publicou no GHCR, comite e aplique de novo:

```bash
kubectl apply -k k8s/overlays/prod
```

Para remover um ambiente por completo:

```bash
kubectl delete namespace case-chatguru-stg
# ou
kubectl delete namespace case-chatguru-prod
```

## 9. Encerrando o cluster (kind)

```bash
./scripts/destroy-kind.sh
```

## 10. Deploy em um cluster gerenciado (cloud) — feito de verdade

Os manifests deste repositório não têm nenhuma dependência de kind — os
mesmos comandos das seções 4–8 funcionam sem alteração em qualquer cluster
real, desde que ele tenha um Ingress controller nginx instalado. Isso não
é só teoria: existe um ambiente público rodando exatamente assim, num
servidor [k3s](https://k3s.io/) na AWS — ver a seção **"Ambiente de
demonstração pública"** no [README](README.md#ambiente-de-demonstração-pública)
para as URLs e os detalhes de implementação.

O que foi implementado nesse ambiente, com Ingress/DNS/TLS reais (não
fictícios):

- **Ingress controller**: o mesmo manifest estático usado pelo kind
  funciona igual em k3s — o `ServiceLB` embutido do k3s já expõe o
  Service `LoadBalancer` do ingress-nginx direto nas portas 80/443 do
  nó, sem precisar de um Load Balancer de cloud gerenciado à parte.
- **DNS**: o host do Ingress não é mais fictício — usa
  [DuckDNS](https://www.duckdns.org/) (`case-chatguru-stg.duckdns.org` /
  `-prod`), um serviço de DNS dinâmico gratuito, apontando para o IP
  público da instância. **DuckDNS foi usado apenas para fornecer DNS
  público estável no ambiente de demonstração** — não é uma escolha de
  produção; um ambiente real de produção usaria um domínio próprio
  registrado, numa zona DNS gerenciada (Route53, Cloudflare, etc.).
- **TLS**: `cert-manager` + `ClusterIssuer` do Let's Encrypt, emitindo
  certificados reais via desafio HTTP-01 — ver
  `k8s/overlays/stg-aws` e `k8s/overlays/prod-aws`, que existem
  especificamente para acrescentar host real + anotação do
  `cert-manager` por cima dos overlays `stg`/`prod` originais, sem
  alterá-los (os overlays "oficiais" deste desafio continuam com host
  fictício, por design — ver a introdução deste documento e a seção 8).
- **Registry**: a imagem já está pública no GHCR, então nenhum cluster
  precisa de credencial para puxá-la; um registry privado exigiria um
  `imagePullSecrets` no `Deployment`.

O que **não** foi implementado, por estar fora do escopo deste desafio:
`HorizontalPodAutoscaler`, `PodDisruptionBudget`, e integração com um
stack de observabilidade (Prometheus/Grafana ou equivalente da
plataforma).

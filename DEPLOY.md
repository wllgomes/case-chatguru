# Deploy — passo a passo

Este documento descreve, do zero, como subir o `case-chatguru` em um cluster
Kubernetes: pré-requisitos, comandos de `kustomize build` / `kubectl apply`,
como acessar a aplicação depois de publicada e como trocar de overlay
(`dev` ↔ `prod`).

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
**públicas** no GHCR — `dev` usa `latest` (acompanha `main`), `prod` fixa
uma tag imutável por SHA do commit (ver a tabela em
[README](README.md#ambientes-dev-vs-prod)). Qualquer cluster com acesso à
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

# Overlay de dev — o que de fato é aplicado no ambiente dev
kubectl kustomize k8s/overlays/dev

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
kubectl kustomize k8s/overlays/dev | ./.bin/kubeconform -strict -summary -
```

## 5. Aplicando no cluster (`kubectl apply -k`)

O script `scripts/deploy.sh` encapsula os passos abaixo (cria o namespace,
aplica o overlay e aguarda o rollout) — é a forma recomendada:

```bash
./scripts/deploy.sh dev
./scripts/deploy.sh prod
```

Isso é equivalente, no fundo, a:

```bash
kubectl create namespace case-chatguru-dev --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -k k8s/overlays/dev
kubectl -n case-chatguru-dev rollout status deployment/dev-case-chatguru --timeout=120s
```

(troque `dev` por `prod` e `dev-case-chatguru` por `prod-case-chatguru` para
o outro ambiente).

Para fixar uma imagem específica (por exemplo, a que você acabou de
construir/carregar no passo 3), exporte `IMAGE` antes de rodar o script:

```bash
IMAGE=ghcr.io/wllgomes/case-chatguru:local ./scripts/deploy.sh dev
```

## 6. Conferindo que subiu

```bash
kubectl -n case-chatguru-dev get deploy,pods,svc,ingress
```

Saída esperada (resumida):

```
NAME                                READY   UP-TO-DATE   AVAILABLE
deployment.apps/dev-case-chatguru   1/1     1            1

NAME                                     READY   STATUS
pod/dev-case-chatguru-xxxxxxxxxx-xxxxx   1/1     Running

NAME                        TYPE        CLUSTER-IP
service/dev-case-chatguru   ClusterIP   10.x.x.x

NAME                                          CLASS   HOSTS
ingress.networking.k8s.io/dev-case-chatguru   nginx   dev.case-chatguru.local
```

## 7. Acessando a aplicação depois de publicada

O host configurado no Ingress é fictício (`dev.case-chatguru.local` /
`prod.case-chatguru.local`), então não existe DNS público apontando para
ele. Duas formas de acessar:

**Opção A — header `Host` direto no `curl`** (não precisa editar nada no
sistema; funciona em qualquer cluster onde você tenha o IP/host do Ingress):

```bash
# kind local: o ingress-nginx escuta em localhost:80/443
curl -H "Host: dev.case-chatguru.local"  http://localhost/health
curl -H "Host: dev.case-chatguru.local"  http://localhost/info

curl -H "Host: prod.case-chatguru.local" http://localhost/health
curl -H "Host: prod.case-chatguru.local" http://localhost/info
```

Em um cluster cloud, troque `http://localhost` pelo IP/hostname público do
Load Balancer do ingress controller:

```bash
INGRESS_IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -H "Host: dev.case-chatguru.local" "http://$INGRESS_IP/info"
```

**Opção B — editar `/etc/hosts`** (para navegar pelo browser):

```
127.0.0.1  dev.case-chatguru.local prod.case-chatguru.local
```

(aponte para o IP real do Ingress em vez de `127.0.0.1` caso não seja um
cluster local).

**Opção C — sem depender do Ingress**, direto no Service, útil para depurar:

```bash
kubectl -n case-chatguru-dev port-forward svc/dev-case-chatguru 8080:80
curl http://localhost:8080/info
```

O script `scripts/smoke-test.sh dev` (ou `prod`) automatiza as opções A e C
com verificações de conteúdo da resposta.

## 8. Trocando de overlay (dev ↔ prod)

Não existe um "trocar" no sentido de alternar estado — `dev` e `prod` são
namespaces e recursos **independentes**, nascidos do mesmo `k8s/base`. Os
dois podem coexistir no mesmo cluster ao mesmo tempo. Para atuar em um ou
outro, basta apontar o comando para o overlay correspondente:

```bash
kubectl apply -k k8s/overlays/dev    # cria/atualiza o ambiente dev
kubectl apply -k k8s/overlays/prod   # cria/atualiza o ambiente prod
```

As diferenças entre eles (réplicas, resources, host do Ingress, tag de
imagem) estão declaradas nos respectivos `k8s/overlays/<ambiente>/` — ver
a tabela comparativa no [README](README.md#ambientes-dev-vs-prod).

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
kubectl delete namespace case-chatguru-dev
# ou
kubectl delete namespace case-chatguru-prod
```

## 9. Encerrando o cluster (kind)

```bash
./scripts/destroy-kind.sh
```

## 10. Observação: deploy em um cluster gerenciado (cloud)

Os manifests deste repositório não têm nenhuma dependência de kind — os
mesmos comandos das seções 4–8 funcionam sem alteração em qualquer cluster
gerenciado (EKS, GKE, AKS, OVHcloud Managed Kubernetes, etc.), desde que
ele tenha um Ingress controller nginx instalado. As diferenças práticas
seriam:

- **Ingress controller**: em vez do manifest estático usado pelo
  `setup-kind.sh` (pensado para kind), a forma recomendada em produção é
  instalar via Helm chart oficial do
  [ingress-nginx](https://kubernetes.github.io/ingress-nginx/), que
  provisiona automaticamente um Load Balancer da cloud (Service tipo
  `LoadBalancer`) com IP público.
- **DNS**: o host do Ingress deixaria de ser fictício — apontaria para um
  domínio real via registro `A`/`CNAME` para o IP do Load Balancer.
- **TLS**: adicionar `cert-manager` + `ClusterIssuer` (Let's Encrypt) e uma
  seção `tls:` no `Ingress` para HTTPS.
- **Registry**: a imagem já está pública no GHCR, então nenhum cluster
  precisa de credencial para puxá-la; um registry privado exigiria um
  `imagePullSecrets` no `Deployment`.
- **State/observabilidade**: um ambiente real se beneficiaria de
  `HorizontalPodAutoscaler`, `PodDisruptionBudget` e integração com o
  stack de monitoramento da plataforma (não incluídos aqui por estarem
  fora do escopo deste desafio).

Essa etapa não foi implementada neste repositório por não fazer parte do
escopo pedido — o objetivo aqui foi demonstrar a estrutura de manifests e
o pipeline de forma reproduzível por qualquer avaliador, sem depender de
uma conta de cloud específica.

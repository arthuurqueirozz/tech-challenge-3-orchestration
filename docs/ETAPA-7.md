# Etapa 7 — gateway Kong

Gate técnico concluído em 2026-09-14, horário de São Paulo: 71 verificações
passaram com 52 chamadas HTTP feitas exclusivamente pelo Kong.
[Evidências e limites do ensaio](EVIDENCIAS-ETAPA-7.md).

## Arquitetura e autenticação

Kong OSS 3.9.3 funciona em modo DB-less. O overlay `k8s/stage7` reaproveita
o cluster e o namespace `fcg-stage6`, adicionando `k8s/gateway` aos manifests
da etapa 6. UsersAPI e CatalogAPI continuam ClusterIP. O único acesso de
negócio criado pelo script é `http://127.0.0.1:18000`, encaminhado ao Kong.
Não há NodePort, LoadBalancer, hostPort ou hostNetwork. O acesso é local,
sem endpoint público AWS ou exposição à rede do computador.

`k8s/gateway/kong.template.json` versiona serviços, rotas, métodos e plugins.
Os caminhos regex usam o prefixo `~/` exigido pelo Kong e terminam em `/?$`;
`strip_path=false` preserva os caminhos esperados pelas APIs. Não há rota
genérica para `/api`, `/metrics`, `/health`, Swagger ou administração.

| Métodos e caminhos | Destino | Política |
|---|---|---|
| POST /api/auth/register e /api/auth/login | Users | Pública; validação do corpo na API |
| GET /api/me/profile | Users | JWT |
| GET /api/games e /api/games/{id} | Catalog | Pública |
| POST /api/games | Catalog | JWT no Kong; Admin na API |
| PUT e DELETE /api/games/{id} | Catalog | JWT no Kong; Admin na API |
| GET /api/me/library/games | Catalog | JWT |
| POST /api/me/library/games/{id} | Catalog | JWT |

O consumer `fcg-users-issuer` identifica o emissor FCG; não representa um papel
de negócio. A credencial usa HS256 e a mesma chave local das APIs. O plugin JWT
exige assinatura válida, emissor conhecido e claims `exp` e `nbf` presentes e
válidos. Aceita token somente no header Authorization, não em query ou cookie.
As APIs preservam validação de assinatura, issuer, audience, lifetime,
ClockSkew zero e o claim `role`. A policy Admin permanece na CatalogAPI.

O template contém somente um placeholder. O deploy lê `stage6-settings.local.json`
e gera `stage7-kong.local.json`, ignorado pelo Git, com o Secret Kubernetes
`kong-declarative`. A configuração completa fica montada somente para leitura
no pod. Atualizações exigem restart do Kong, já feito pelo script. Se trocar a
chave, sincronize também os Secrets das APIs pelo deploy da etapa 6 antes da 7.
Não imprima nem publique arquivos locais ou conteúdo dos Secrets. A API Admin
do Kong está desligada; o Service só expõe o proxy, e a porta status serve às
probes internas. Access log do proxy está desligado para não registrar queries.

## Executar e recuperar após reinício

Requer Docker Desktop com motor Linux ativo, kubectl no PATH e o ambiente da
[etapa 6](ETAPA-6.md) já implantado. Se for a primeira execução, siga primeiro
o deploy da etapa 6; ele cria imagens, banco, kubeconfig e Secrets locais.
Na pasta de orquestração, com PowerShell:

```powershell
./scripts/stop-stage7-access.ps1
./scripts/deploy-stage7.ps1
./scripts/start-stage7-access.ps1
./scripts/stage7-smoke.ps1
```

Depois de reiniciar o PC, inicie o Docker Desktop e aguarde o motor Linux.
O deploy inspeciona o nó existente, inicia-o se estiver parado e aguarda a API
Kubernetes e os rollouts. Reaplica manifests e Secret sem recriar o cluster/PVC.
Os arquivos `stage6-settings.local.json` e `stage6.kubeconfig.local.yaml` devem
estar preservados. Não é preciso renovar credenciais AWS para este ensaio.

O script de acesso encerra os port-forwards registrados da etapa 6 antes de
abrir somente o Kong. Se houver registro antigo de PIDs, o script de parada
remove registros de processos inexistentes e só encerra processos cuja identidade
kubectl/kubeconfig/port-forward confere. Se um PID foi reutilizado por outro
processo, ele recusa a parada: confira o processo antes de remover o registro
local obsoleto. Portas já ocupadas também causam falha explícita.

## Escopo do smoke

Admin e User fazem login real. O User é inserido temporariamente no banco
isolado com role User e hash do admin local, e removido em `finally`. Isso evita
gerar outbox SQS neste overlay sem credenciais AWS. Cadastro público é verificado
com corpo inválido e retorno 400 da UsersAPI. Compra autenticada de jogo
inexistente retorna 400 antes de publicar eventos. Cadastro bem-sucedido,
compra aprovada/rejeitada e notificações completas pertencem à etapa 8.

Tokens inválidos são assinados/adulterados somente em memória. O smoke verifica
status e presença de `X-Kong-Upstream-Latency` para distinguir rejeição no gateway
de resposta da API. CRUD usa jogo sintético, desativado ao terminar; o banco
preserva esse registro de exclusão lógica. Evidência local não contém tokens,
senhas ou hash da fixture. Acessos SQL/kubectl são preparo e inspeção interna;
todas as chamadas HTTP de negócio usam a porta 18000.

## Diagnóstico e encerramento

```powershell
kubectl --kubeconfig stage6.kubeconfig.local.yaml --context kind-fcg-fase3-stage6 -n fcg-stage6 get deployments
kubectl --kubeconfig stage6.kubeconfig.local.yaml --context kind-fcg-fase3-stage6 -n fcg-stage6 logs deployment/kong --tail=35
./scripts/stop-stage7-access.ps1
docker stop fcg-fase3-stage6-control-plane
```

O encerramento preserva dados e não altera AWS. Para visualizar Grafana sem
abrir APIs diretamente, use um port-forward administrativo separado; não use
`start-stage6-access.ps1` durante o smoke da etapa 7, que exige somente o Kong.
A reprodução integral do zero e a consolidação dos overlays são gate da etapa 8.

Referências oficiais: [modo DB-less](https://developer.konghq.com/gateway/db-less-mode/),
[plugin JWT](https://developer.konghq.com/plugins/jwt/),
[schema JWT 3.9.3](https://github.com/Kong/kong/blob/3.9.3/kong/plugins/jwt/schema.lua)
e [imagem oficial OSS](https://hub.docker.com/_/kong).

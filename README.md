# FIAP Cloud Games — Fase 3

Guia central da stack .NET 8: identidade, catálogo, compras e notificações
simuladas, com Kong, Redis, Prometheus/Grafana e AWS Lambda/SQS/DynamoDB.
A referência normativa é o PDF local `TC NETT - Fase 3.pdf`, páginas 3 a 7.
O PDF original não é publicado neste repositório.

## Arquitetura

```text
Cliente -> Kong -> UsersAPI -> SQL Server Users + outbox -> SQS UserCreated
                -> CatalogAPI -> SQL Server Catalog / Redis
                         | RabbitMQ OrderPlaced -> PaymentsAPI
                         | <- RabbitMQ PaymentProcessed <- |
                                                          +-> SQS PaymentProcessed
Ambas as filas SQS -> Lambda Notifications -> DynamoDB + CloudWatch Logs
Prometheus -> /metrics de UsersAPI/CatalogAPI -> Grafana
```

Kind executa nove componentes: Users, Catalog, Payments, SQL Server, RabbitMQ,
Redis, Kong, Prometheus e Grafana. Só Kong recebe chamadas externas de negócio.
As ferramentas de observabilidade têm acesso administrativo local separado.
NotificationsAPI antiga não integra a stack. DynamoDB armazena eventos flexíveis
e o efeito durável da simulação; não é enviado e-mail externo. SQL continua
fonte de verdade para identidade, jogos e biblioteca; Redis é descartável.

Opção A: Prometheus coleta UsersAPI/CatalogAPI, e Grafana mostra p95, totais,
contagem por status, requisições/s e taxas 4xx/5xx. Manifests, datasource e seis
painéis são provisionados pelo Git. CloudWatch centraliza os logs da Lambda.
Não se aplicam os agentes/traces exigidos apenas na Opção B.

## Repositórios e clones

Histórico e autoria da Fase 2 preservados; os três projetos evoluídos mantêm a
tag `fase-2-final` e usam a branch `fase-3`. Publicação autorizada pelo grupo.
Cinco projetos independentes devem ficar em pastas irmãs:

```powershell
git clone --branch fase-3 https://github.com/arthuurqueirozz/tech-challenge-2-users-api.git
git clone --branch fase-3 https://github.com/arthuurqueirozz/tech-challenge-2-catalog-api.git
git clone --branch fase-3 https://github.com/arthuurqueirozz/tech-challenge-2-payments-api.git
git clone https://github.com/arthuurqueirozz/tech-challenge-3-notifications-function.git
git clone https://github.com/arthuurqueirozz/tech-challenge-3-orchestration.git
cd tech-challenge-3-orchestration
```

Links: [Users](https://github.com/arthuurqueirozz/tech-challenge-2-users-api),
[Catalog](https://github.com/arthuurqueirozz/tech-challenge-2-catalog-api),
[Payments](https://github.com/arthuurqueirozz/tech-challenge-2-payments-api),
[Notifications Function](https://github.com/arthuurqueirozz/tech-challenge-3-notifications-function)
e [Orchestration](https://github.com/arthuurqueirozz/tech-challenge-3-orchestration).

## Pré-requisitos

- Windows/PowerShell, Git, .NET SDK 8, Docker Desktop com containers Linux,
  Kind, kubectl, AWS CLI v2 e AWS SAM CLI. Os scripts finais são PowerShell;
  Git Bash/curl/jq são necessários apenas para scripts históricos em Bash.
- Ferramentas no PATH; abra outro terminal após instalar. Os scripts reconhecem
  também instalações Windows por usuário de AWS CLI e Kind via WinGet.
- Docker Linux ativo, aproximadamente 16 GB de memória disponíveis ao motor,
  espaço para imagens .NET/SQL e PVCs locais SQL 2 GiB + RabbitMQ 1 GiB.
- Conta AWS própria ou autorizada em us-east-1 e perfil local `fiap-fase3`.
  Nesta implementação, as trusts dos produtores exigem o usuário IAM
  `fiap-fase3-cli`. A chave de deploy fica no host, nunca nos containers.
- IAM/SAM configurados conforme o
  [guia de permissões da função](https://github.com/arthuurqueirozz/tech-challenge-3-notifications-function/blob/main/iam/README.md).
  O responsável precisa anexar a política de deploy renderizada para sua conta.
  Não use o ID da conta de outra pessoa e não publique credenciais.

.NET 8 é a base preservada. Verifique
[suporte Lambda](https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html)
antes de um deploy futuro; não faça upgrade silencioso de framework.

## AWS: primeira instalação

Defina apenas dados não secretos; estes valores são usados nos comandos seguintes:

```powershell
$AccountId = 'SEU_ID_AWS_DE_12_DIGITOS'
$Profile = 'fiap-fase3'
aws configure set region us-east-1 --profile $Profile
aws sts get-caller-identity --profile $Profile
$Bucket = "fcg-fase3-artifacts-$AccountId-us-east-1"
```

Autentique o perfil local pelo mecanismo disponível na conta. Na conta deste
projeto, o responsável configurou uma chave IAM após falha de OAuth.
Não cole chaves em scripts, README ou chat. O STS deve retornar a conta esperada
e o usuário de deploy; ele sozinho não comprova todas as permissões.

O bucket privado é suporte aos artefatos SAM. Consulte primeiro sua existência;
em conta nova, crie apenas após confirmar ausência (404), nunca por erro 403:

```powershell
aws s3api head-bucket --bucket $Bucket --expected-bucket-owner $AccountId --profile $Profile --region us-east-1
# Apenas se confirmada ausência:
aws s3api create-bucket --bucket $Bucket --profile $Profile --region us-east-1
aws s3api put-public-access-block --bucket $Bucket --public-access-block-configuration 'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true' --profile $Profile --region us-east-1
aws s3api get-bucket-encryption --bucket $Bucket --profile $Profile --region us-east-1
```

Build e deploy, a partir da pasta de orquestração:

```powershell
Push-Location ../tech-challenge-3-notifications-function
sam validate --lint --template-file template.yaml --region us-east-1
sam build --template-file template.yaml
sam deploy --template-file .aws-sam/build/template.yaml --stack-name fcg-fase3-notifications --s3-bucket $Bucket --capabilities CAPABILITY_NAMED_IAM --region us-east-1 --profile $Profile --parameter-overrides NotificationsEnabled=false --confirm-changeset
Pop-Location
aws cloudformation describe-stacks --stack-name fcg-fase3-notifications --profile $Profile --region us-east-1 --query 'Stacks[0].{Status:StackStatus,Outputs:Outputs}'
```

Revise os recursos do changeset antes de executá-lo. A stack cria filas, função,
tabela, log group e roles restritas; não inclui EKS, VPC, NAT ou servidores AWS.
Se a stack já existe e está CREATE_COMPLETE/UPDATE_COMPLETE com o template
atual, reutilize-a. Não a apague para repetir os testes. Contratos, idempotência,
falhas parciais e remoção cloud estão no
[README da função](https://github.com/arthuurqueirozz/tech-challenge-3-notifications-function).

## Build e deploy completo no Kind

Com Docker Desktop Linux iniciado e a stack AWS pronta:

```powershell
./scripts/deploy.ps1 -AccountId $AccountId -Profile $Profile
./scripts/start-access.ps1
./scripts/run-smoke.ps1 -AccountId $AccountId -Profile $Profile
```

O deploy compila e carrega as três imagens, cria o cluster `fcg-fase3` se ausente,
usa kubeconfig isolado `fase3.kubeconfig.local.yaml`, namespace `fcg` e
`k8s/final`. Gera segredos locais uma única vez, consulta outputs SAM, assume
roles Users/Payments por uma hora e injeta Secrets. Banco/PVC e RabbitMQ/PVC
persistem entre paradas. SQL/Rabbit/Redis são aguardados antes de reiniciar APIs.
Schemas são criados/migrados pelas APIs; admin local `admin@fcg.local` é semeado.
Sua senha aleatória fica em `fase3-settings.local.json`.

O smoke reaproveita os cenários de JWT/papéis da etapa 7, habilita os dois
gatilhos por changeset, valida cadastro, login, compras aprovadas/rejeitadas,
biblioteca, notificações DynamoDB, cache e métricas, e pausa os gatilhos em
`finally`. Só aceita changesets com alteração de Enabled nos dois mappings,
sem troca de recursos. Logs CloudWatch são coletados após a pausa. Não feche
o terminal durante o teste; se ele for interrompido, execute o encerramento abaixo.

O ensaio usa dados sintéticos: jogos de preços 59,90 (aprovado) e 150,00
(rejeitado), limite de pagamento 100. Registros completos de integração são
preservados como evidência. A fixture User do smoke de autorização é removida.
Uma falha SQL controlada renomeia temporariamente Users/Games e restaura ambas
em finally para gerar 500 reais nas métricas; use apenas neste ambiente local.

## Acessar e demonstrar

| Uso | Endereço |
|---|---|
| Negócio, somente Kong | http://127.0.0.1:18000 |
| Grafana, Viewer local | http://127.0.0.1:13000/d/fcg-http |
| Prometheus, diagnóstico local | http://127.0.0.1:19090 |

Não abra port-forward para APIs. `start-access.ps1` encerra os acessos registrados
das etapas 6/7 e abre somente os três acima, todos em 127.0.0.1.
Kong DB-less usa rotas/métodos explícitos e JWT HS256 nas rotas protegidas;
as APIs mantêm audience/lifetime e a policy Admin. Rotas e detalhes em
[ETAPA-7.md](docs/ETAPA-7.md). `/metrics`, `/health`, Swagger e a administração
do Kong não são rotas públicas. Seu Admin API está desligado.

Grafana provisiona os painéis automaticamente; não exige importar JSON à mão.
Gere tráfego com o smoke e visualize a janela dos últimos 15 minutos. Taxas e p95
usam 2 minutos; totais reiniciam com os processos. Valores sem tráfego recente
podem estar vazios; 4xx do próprio Kong não chegam aos contadores das APIs.

## Renovar credenciais e recuperar após reinício

Antes de expirar a sessão STS (uma hora), ou após uma pausa longa:

```powershell
./scripts/prepare-secrets.ps1 -AccountId $AccountId -Profile $Profile -Apply
```

O comando obtém novas sessões, aplica os Secrets e reinicia Users/Payments.
O perfil do host precisa estar válido. Credenciais temporárias de laboratório,
se usadas no perfil, devem ser renovadas pelo responsável primeiro.
Mudar o arquivo local sem reiniciar os pods não atualiza as variáveis do processo.
Não altere senhas SQL/Rabbit manualmente com PVCs existentes; os dados persistidos
continuam associados às senhas originais. Segredos, kubeconfig, PIDs e evidências
brutas `*.local.*` são ignorados pelo Git.

Após reiniciar o PC: inicie Docker Desktop, execute `stop-access.ps1` para limpar
o registro antigo, depois `deploy.ps1`, `start-access.ps1` e o smoke. O deploy
reutiliza cluster e dados e renova STS. Se PID foi reutilizado por outro processo,
o script recusa encerrá-lo; confira sua identidade antes de remover apenas o
registro local obsoleto. Um deploy repetido faz rebuild/restart das APIs.

## Diagnóstico e encerramento

```powershell
kubectl --kubeconfig fase3.kubeconfig.local.yaml --context kind-fcg-fase3 -n fcg get deployments,pods,pvc
kubectl --kubeconfig fase3.kubeconfig.local.yaml --context kind-fcg-fase3 -n fcg logs deployment/payments-api --tail=30
aws logs tail /aws/lambda/fcg-fase3-notifications --since 10m --profile $Profile --region us-east-1
./scripts/stop.ps1 -AccountId $AccountId -Profile $Profile
```

O encerramento confirma mappings Disabled, fecha port-forwards e para apenas o
nó final, preservando dados. Após interrupção/reinício, confira a pausa AWS mesmo
que Docker já esteja parado. Mensagens SQS expiram em quatro dias; processe
pendências antes de pausas longas. Não apague cluster/PVC ou stack para encerrar.

Teto solicitado pelo responsável: USD 1/mês, sem créditos.
[Estimativa e limites de sessão](docs/CUSTOS.md): uso pequeno e gatilhos pausados
fora dos testes. Alertas não bloqueiam cobranças. Não deixe os gatilhos ligados
continuamente; parar Docker não pausa Lambda. Armazenamento cloud permanece.

## Validação e entrega

[Progresso](docs/PROGRESSO.md) e [matriz](docs/MATRIZ-REQUISITOS.md) distinguem
código, validação executada e entrega acadêmica. Evidências anteriores:
[cloud](docs/EVIDENCIAS-CLOUD.md), [produtores](docs/EVIDENCIAS-ETAPA-4.md),
[cache](docs/EVIDENCIAS-ETAPA-5.md), [métricas](docs/EVIDENCIAS-ETAPA-6.md) e
[gateway](docs/EVIDENCIAS-ETAPA-7.md). A instalação final passou em
[98 verificações](docs/EVIDENCIAS-ETAPA-8.md), incluindo os três eventos cloud.
[Revisão técnica](docs/REVISAO-TECNICA.md): 89 testes, builds, formatação e auditoria
NuGet concluídos. [Roteiro do vídeo](docs/ROTEIRO-VIDEO.md) e
[preparação da entrega](docs/ENTREGA.md).
Vídeo de até 20 minutos e relatório PDF/TXT com os dados do grupo continuam
obrigatórios; não são considerados entregues por haver código publicado.

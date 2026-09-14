# Etapa 4 - Produtores de notificações

Gate concluído em 2026-09-14: 40 testes locais nos produtores e 11 verificações
integradas, incluindo coleta dos cinco eventos no CloudWatch.
Resultados e identificadores em [EVIDENCIAS-ETAPA-4.md](EVIDENCIAS-ETAPA-4.md).

UsersAPI publica UserCreatedEvent em JSON direto no SQS pelo outbox transacional
existente. Mantém EventId, payload, backoff e marcação de conclusão após envio.
Não depende mais de RabbitMQ. Readiness verifica SQL Server: cadastro pode ser
persistido mesmo com SQS indisponível. Diagnosticar pendências pelo outbox e logs.

PaymentsAPI consome OrderPlacedEvent no RabbitMQ e publica o mesmo resultado em
RabbitMQ para CatalogAPI e SQS para a Lambda, nessa ordem. Uma falha propaga e
aciona retries MassTransit de 5, 15 e 30 segundos. Depois disso, a mensagem fica
em payments-order-placed_error para diagnóstico/reprocessamento. Não há novo
outbox nem transação entre destinos; OrderId estável permite tratar redelivery.

## Credenciais e infraestrutura

O SAM da função declara duas roles de publicação, cada uma com SendMessage na
própria fila. Trust explícita no usuário IAM fiap-fase3-cli da mesma conta permite
AssumeRole. A política FCGFase3Deploy recebeu os dois novos ARNs no escopo de
gerenciamento de roles; não houve concessão de acesso administrativo geral.

Na pasta de orquestração, com AWS CLI, Docker e perfil de deploy configurados:

```powershell
./scripts/prepare-stage4.ps1 -AccountId SEU_ACCOUNT_ID -Profile fiap-fase3
docker compose --env-file stage4.local.env -f compose.stage4.yaml config --quiet
docker compose --env-file stage4.local.env -f compose.stage4.yaml up -d --build
```

O primeiro comando preserva senhas locais preexistentes e renova as duas sessões
STS de uma hora. Gera stage4.local.env, users-runtime.local.env e
payments-runtime.local.env, todos ignorados pelo Git. Não imprimir docker compose
config sem --quiet ou ambientes de containers: essas saídas podem conter segredos.
Após renovar as sessões, recriar os produtores para carregar os novos valores:

```powershell
docker compose --env-file stage4.local.env -f compose.stage4.yaml up -d --no-deps --force-recreate users-api payments-api
```

## Ensaio isolado

compose.stage4.yaml deriva do Compose da Fase 2, com SQL Server, RabbitMQ e três
APIs. NotificationsAPI histórica não participa. Portas HTTP 18080/18081 e painel
RabbitMQ 15672 ficam vinculados a 127.0.0.1. SQL/AMQP não são publicados no host.
É um ambiente de desenvolvimento para o gate dos produtores. A stack final
Kind/Kong, seus manifests e a entrada única serão entregues nas etapas seguintes.

Ativar NotificationsEnabled=true pelo SAM conforme README da função, aguardar
stack/mappings prontos e executar:

```powershell
./scripts/stage4-smoke.ps1 -Profile fiap-fase3
```

O script usa dados sintéticos. Verifica cadastro com outbox, compra aprovada e
rejeitada, biblioteca e itens reais no DynamoDB. Para testar falhas, aponta cada
produtor temporariamente à fila do outro; suas roles não permitem esse envio.
Restaura os containers em finally. No pagamento, RabbitMQ já publicou o resultado
antes da falha SQS; recriar o consumer devolve a entrega pendente ao broker, que
faz redelivery. O teste exige mesmo OrderId, notificação recuperada e jogo único
na biblioteca. Isso também exercita a recuperação após reiniciar o processo.

Executar em sessão isolada. Se interrompido à força, recriar os produtores usando
somente compose.stage4.yaml para restaurar as configurações. Se os retries forem
esgotados antes da restauração, conferir payments-order-placed_error e reprocessar
apenas o pedido sintético identificado; o script não apaga nem esvazia filas.

Saída resumida em stage4-smoke.local.json, ignorada pelo Git; evidências públicas
devem conter somente os IDs e resultados sintéticos, sem JWTs ou credenciais.

## Encerramento

Após confirmar filas drenadas, pausar os mappings com NotificationsEnabled=false
pelo SAM. Parar o ensaio preservando os volumes SQL/RabbitMQ:

```powershell
docker compose --env-file stage4.local.env -f compose.stage4.yaml stop
./scripts/collect-stage4-logs.ps1 -Profile fiap-fase3
```

A coleta de logs é somente leitura e aguarda até dez minutos pela ingestão dos
cinco eventos correlacionados. Pode ser repetida com gatilhos pausados e containers
parados; acrescenta a décima primeira verificação ao arquivo local de evidências.

Não usar down --volumes antes de preservar evidências: remove os dados locais.
Credenciais STS expiram em uma hora; recursos AWS e armazenamento continuam
existindo após parar os containers. Ver CUSTOS.md para limites operacionais.

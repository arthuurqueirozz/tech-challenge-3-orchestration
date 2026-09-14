# Evidências da etapa 4 — produtores

Gate executado em 2026-09-14, após reconferir páginas 4–5 do PDF oficial.
Ambiente: três APIs em Docker Compose local, SQL Server, RabbitMQ e AWS real
em us-east-1 (SQS → Lambda → DynamoDB, com CloudWatch). A NotificationsAPI
histórica não participou. Kind/Kong e a stack final permanecem para as próximas etapas.

Commits da implementação: UsersAPI `ca66442`, PaymentsAPI `63ef444`, função/IAM
`4ed2cdc`. CatalogAPI permaneceu em `ecd30fd`, sem alterações nesta etapa.

## Resultado

- UsersAPI: 28 testes passaram (23 herdados + 5 novos). O teste com SQLite
  verifica outbox pendente, backoff, falha de envio, recuperação e EventId preservado.
- PaymentsAPI: 12 testes passaram (8 herdados + 4 novos). Cobrem contratos nos
  dois destinos, aprovação/rejeição, falha RabbitMQ e falha parcial SQS com retry.
- SAM: validate --lint e build passaram; imagens Docker das três APIs compiladas.
- Ensaio real: 10 verificações do smoke passaram, mais uma de correlação dos
  cinco eventos no CloudWatch: total 11, sem falhas no ensaio final.

Comandos dos testes, dentro de cada repositório:

```powershell
dotnet run --project tests/FCG.Users.Tests/FCG.Users.Tests.csproj --configuration Release
dotnet run --project tests/FCG.Payments.Tests/FCG.Payments.Tests.csproj --configuration Release
```

Comandos integrados, após preparar ambiente conforme [ETAPA-4.md](ETAPA-4.md):

```powershell
./scripts/stage4-smoke.ps1 -Profile fiap-fase3
# Pausar gatilhos e parar Compose conforme o guia; então coletar os logs:
./scripts/collect-stage4-logs.ps1 -Profile fiap-fase3
```

## Fluxos e correlação real

Todos os itens abaixo foram lidos com ConsistentRead no DynamoDB e
ProcessingStatus=Completed; os cinco logs CloudWatch têm result=SimulationRecorded.
Notificação significa simulação durável registrada, sem envio de e-mail externo.

| Caso | EventKey | Resultado observado | Horário do log AWS (UTC) |
|---|---|---|---|
| Cadastro HTTP | user-created:70b4a8f5-2bc3-4298-b21c-b65a1d3499a8 | Outbox SQL processado; Welcome | 21:12:34.133 |
| Compra aprovada, 59,90 | payment-processed:716f9203-257b-4617-a2ff-ab12ca7d9943 | Jogo na biblioteca; PurchaseConfirmation | 21:12:38.792 |
| Compra rejeitada, 150,00 | payment-processed:3d47c189-ec3b-4ee9-ba21-c8e1f4bd9414 | Sem jogo; NotificationState=Skipped, NotificationKind=None | 21:12:42.238 |
| Cadastro com falha SQS e recuperação | user-created:25850b30-31d1-4b85-9760-0297edbf712e | Cadastro preservado; mesmo EventId; Welcome após restauração | 21:12:55.793 |
| Publicação parcial do pagamento, 49,90 | payment-processed:c70f4efa-3661-4ddd-950e-3af619750090 | RabbitMQ atualizou biblioteca antes do SQS; redelivery recuperou confirmação, com um único jogo | 21:13:05.854 |

O relógio local estava cerca de 2m25s adiantado em relação à AWS. O arquivo de
evidências registra início local 21:14:56.473Z e fim 21:15:40.635Z. Correlação foi
feita pelas chaves únicas acima, com margem de dez minutos na consulta de logs.

## Falhas exercitadas

Cada produtor foi temporariamente apontado para a fila do outro, cujo envio sua
role não permite. Nenhuma política de negação temporária foi criada na AWS.
UsersAPI continuou aceitando cadastro: AttemptCount aumentou, ProcessedAtUtc
ficou nulo e não apareceu item de notificação antes de restaurar a fila correta.
O outbox foi então processado com o mesmo ID.

Em PaymentsAPI, a biblioteca recebeu o resultado RabbitMQ enquanto a notificação
SQS estava ausente. A restauração recriou o consumer, provocando redelivery da
entrega pendente. O mesmo OrderId foi recuperado, sem jogo duplicado. O teste
local complementar verifica propagação da exceção e nova publicação; o ensaio
real prova recuperação após reinício, não esgotamento de todos os retries.
Depois do ensaio, payments-order-placed_error estava vazia ou inexistente.

Não foi criado outbox novo em PaymentsAPI. O consumer tem retries em 5, 15 e 30
segundos; falhas persistentes terminam na fila de erro e exigem diagnóstico e
reprocessamento. Os contratos FCG.IntegrationEvents.V1 foram preservados.

## AWS e encerramento

- Política FCGFase3Deploy atualizada pelo responsável; SAM criou
  fcg-fase3-users-publisher-role e fcg-fase3-payments-publisher-role.
- Cada role concede somente sqs:SendMessage na própria fila. Sessões STS de
  uma hora foram usadas nos containers; a identidade de deploy não foi injetada.
- Deploy das roles e ativação dos gatilhos concluídos. Após o teste, changeset
  de encerramento alterou somente os dois mappings, sem substituição.
- Conferência final: stack UPDATE_COMPLETE, NotificationsEnabled=false,
  ambos os mappings Disabled; Lambda Active/Successful com a tabela original.
- Filas SQS drenadas; cinco containers parados, volumes SQL/RabbitMQ preservados.
- Artefatos S3 totalizaram 1.615.905 bytes; recursos e armazenamento permanecem.
  Custo real ainda não apurado. Aplicam-se os limites de [CUSTOS.md](CUSTOS.md).

Evidência bruta em stage4-smoke.local.json, ignorada pelo Git. Este resumo usa
somente resultados e identificadores sintéticos, sem senhas, JWTs ou credenciais.
O primeiro início do smoke parou por incompatibilidade de flags do sqlcmd;
o leitor foi corrigido e o ensaio completo subsequente passou.

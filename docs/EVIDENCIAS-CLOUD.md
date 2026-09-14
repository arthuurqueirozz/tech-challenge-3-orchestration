# Gate cloud - Etapas 2 e 3

Execução em 2026-09-14, região us-east-1. Referência: PDF oficial, páginas 4 a 6,
reconsultadas antes do deploy e da validação. Código da Lambda/template em
`tech-challenge-3-notifications-function`, base `e871215`; script reproduzível
`scripts/cloud-smoke.ps1`. Não houve participação do container NotificationsAPI.

## Infraestrutura aplicada

Stack `fcg-fase3-notifications`, criada por AWS SAM/CloudFormation. O changeset
inicial acrescentou somente oito recursos: função, dois mappings SQS, duas filas,
tabela DynamoDB, grupo de logs e execution role. Bucket de artefatos separado,
privado, com quatro bloqueios públicos ativos e criptografia AES256 verificada.
Política FCGFase3Deploy anexada pelo responsável; nenhum AdministratorAccess.

Lambda .NET 8, 256 MB, timeout 30 segundos; dois mappings com concorrência máxima
2 cada, lote 10 e ReportBatchItemFailures. SQS com visibility timeout 180 segundos
e retenção de quatro dias. DynamoDB on-demand. CloudWatch Logs retém sete dias.
Não foram criados VPC, NAT, EC2, EKS, RDS ou outros servidores gerenciados.

## Execução reproduzível

Ativar os mappings pelo SAM conforme o README da função e executar:

```powershell
./scripts/cloud-smoke.ps1 -AccountId SEU_ACCOUNT_ID -Profile fiap-fase3 -TestDependencyFailure
```

Ensaio final: 18 verificações passaram; início local 20:30:12 UTC, fim 20:34:42 UTC.
O relógio local estava aproximadamente dois minutos adiantado em relação à AWS.
Horários abaixo são do CloudWatch; a correlação usa IDs únicos de mensagens.
Saída bruta local: `cloud-smoke.local.json`, ignorada pelo Git. Os trechos abaixo
contêm somente eventos sintéticos, sem credenciais, nomes ou endereços de e-mail.

| Caso | Evidência real | Resultado |
|---|---|---|
| Cadastro via SQS | Mensagem `14a3ea39-324e-406c-9a65-bce675a3348d`, 20:27:53 UTC | Welcome / Simulated / Completed no DynamoDB; SimulationRecorded no CloudWatch |
| Pagamento aprovado via SQS | Mensagem `bf5c1cc5-d1a8-4e7b-a1f9-37b3dfa530e7`, 20:28:11 UTC | PurchaseConfirmation / Simulated / Completed |
| Pagamento rejeitado via SQS | Mensagem `74a04579-e01b-41bd-a272-74ca4e454f7c`, 20:28:29 UTC | None / Skipped / Completed, sem confirmação |
| Dados flexíveis | Mapas Data de cadastro e pagamento com campos distintos | Mesmo store NoSQL registra ambos os contratos usando AWSSDK.DynamoDBv2 |
| Cadastro duplicado | Mensagem `1f368f2d-c1fe-437d-9ff9-06c852da3634` | Duplicate; ProcessedAtUtc original preservado |
| Pagamento duplicado | Mensagem `c4749837-ca5b-4b2b-910b-5f6fbb57c188`, com timestamp de negócio alterado | Duplicate; ProcessedAtUtc original preservado |
| Lote parcial | Invocação direta da Lambda com um registro válido e JSON inválido | Apenas `268c188f-c18e-4ed4-8321-41c6f70286d3` retornou em batchItemFailures; registro válido persistido |
| Dependência sem acesso | Mensagem SQS `6229d2e2-71c8-4b40-8e98-a4eca89a2896`, 20:29:03 UTC | Retry / AmazonDynamoDBException; nenhum item marcado como completo |
| Recuperação automática | Mesma mensagem, 20:32:03 UTC, após restaurar EVENTS_TABLE | SimulationRecorded / Completed, sem reenviar a mensagem manualmente |
| Encerramento do ensaio | Ambiente da função restaurado; ambas as filas sem mensagens visíveis/em trânsito | Sem falha pendente; logs consultados não contêm nome/e-mail sintético |

Chaves principais persistidas:

- `user-created:c6b557f1-11ac-4894-b381-a92beebf0526`
- `payment-processed:0e76d3fe-690f-4cba-afe0-4e9cf0a62668`
- `payment-processed:9fce5873-8029-4cc4-a5be-6a11281ada35`
- Recuperação: `user-created:3aebb517-1c78-4bb6-9e30-f87ec9b75c40`

## Garantia demonstrada e limites

A simulação é o registro durável atômico no DynamoDB. Não é envio externo de e-mail
nem promessa de entrega exatamente uma vez. Repetição de evento completo não muda
a simulação; falha de acesso não cria marcador que impeça recuperação. Itens e
logs permanecem até retenção/limpeza; preservar esta evidência antes de excluir.

O teste de falha aponta temporariamente a função para um nome de tabela fora de
sua permissão e restaura as variáveis originais em finally. Nenhuma tabela extra
é criada. Isso demonstra recuperação de erro real de dependência após corrigir
configuração, não uma indisponibilidade regional. O teste de lote parcial é uma
invocação direta determinística; ambos os triggers foram testados por SQS real.

Tentativas anteriores corrigiram o harness: tolerância ao relógio local e uso dos
argumentos específicos de `aws lambda invoke`. Uma tentativa com negação IAM
temporária processou a mensagem antes de a alteração surtir efeito, portanto não
foi contada como prova de falha. A política temporária foi removida e o ensaio final
usa a configuração da tabela. Código de negócio da função não precisou de alteração.

As Etapas 2/3 atendem seus gates técnicos. A integração dos produtores, remoção do
container antigo da stack final, Redis, gateway, métricas, vídeo e relatório seguem
pendentes nas respectivas etapas. O custo modelado está em [CUSTOS.md](CUSTOS.md);
esta execução não comprova o valor final da fatura nem garante o teto mensal.

Estado final conferido pela AWS CLI: stack UPDATE_COMPLETE, parâmetro
NotificationsEnabled=false e ambos os mappings Disabled. Lambda Active/Successful
com a tabela original restaurada; role contém apenas fcg-fase3-notification-runtime.
Artefatos S3 totalizaram 807.034 bytes na conferência. Dados, logs, filas e função
foram preservados para a próxima etapa; pausa dos mappings não elimina custos
de armazenamento. O ensaio final deixou as duas filas drenadas.

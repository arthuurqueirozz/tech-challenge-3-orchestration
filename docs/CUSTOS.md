# Custo operacional - us-east-1

Planejamento em 2026-09-14. O responsável informou não haver créditos promocionais.
Teto solicitado: USD 1/mês para o projeto. A estimativa abaixo não subtrai nenhuma
franquia gratuita, não presume saldo de créditos e não inclui outros projetos da
conta. Tributos e conversão cambial dependem da fatura. Não é uma medição real.

## Sessões pequenas de demonstração

Hipóteses operacionais, que devem ser medidas e revistas no primeiro ensaio:

- Até 20 horas mensais com os dois mappings SQS/Lambda habilitados.
- Até 1.000 invocações Lambda no mês, incluindo retries e testes. Para estimar
  compute usa-se o timeout inteiro de 30 segundos a 256 MB, não uma latência ideal.
- Polling ocioso estimado em cinco leitores por fila, uma consulta longa a cada
  20 segundos: 2 x 5 x 20h x 3.600 / 20 = 36.000 solicitações. É um modelo de
  estimativa, não um limite garantido do serviço. Reservam-se mais 10.000 chamadas
  SQS para envio, confirmação, retries e diagnóstico; payloads menores que 64 KB.
- Até 2.000 WRUs e 2.000 RRUs DynamoDB; até 0,01 GB-mês de dados. O item atual
  é pequeno; unidades reais dependem de seu tamanho e de leituras condicionais.
- Até 0,1 GB de ingestão de logs e 0,1 GB-mês armazenado, sem Insights/Live Tail,
  métricas customizadas, alarmes pagos ou outros recursos de observabilidade cloud.
- Até 0,1 GB-mês de artefatos S3, 100 operações de escrita/listagem e 100 leituras.

| Componente | Conta sem descontos | Estimativa USD |
|---|---|---:|
| SQS Standard | 46.000 / 1.000.000 x 0,40 | 0,01840 |
| Lambda compute | 1.000 x 30 x 0,25 GB x 0,0000166667 | 0,12500 |
| Lambda requests | 1.000 / 1.000.000 x 0,20 | 0,00020 |
| DynamoDB writes/reads/storage | 2.000/1M x 0,625 + 2.000/1M x 0,125 + 0,01 x 0,25 | 0,00400 |
| CloudWatch Logs ingestão/armazenamento | 0,1 x 0,50 + 0,1 x 0,03 | 0,05300 |
| S3 armazenamento e operações | 0,1 x 0,023 + 100/1.000 x 0,005 + 100/1.000 x 0,0004 | 0,00284 |
| Subtotal estimado | Soma das linhas | 0,20344 |

Reservar operacionalmente USD 0,30 para essas sessões, incluindo margem para
transferências pequenas e chamadas auxiliares. Isso deixa margem em relação ao
teto de USD 1, mas não garante um limite rígido. Volume, polling, falhas repetidas,
armazenamento acumulado, tributos e serviços já existentes podem mudar a fatura.
Validar o uso real da primeira sessão e rever as hipóteses antes de ampliar testes.

## Como limitar o uso

O SAM usa `NotificationsEnabled=false` por padrão. Habilitar com
`--parameter-overrides NotificationsEnabled=true` durante os ensaios; ao concluir,
aplicar o mesmo template com `NotificationsEnabled=false`, usando o comando de
deploy do README da função e revisando o changeset. Confirmar ausência de fila
pendente antes de pausas longas: retenção SQS continua contando com triggers parados.

Não deixar os gatilhos ativos o mês inteiro. Com máxima concorrência configurada,
a otimização de polling de baixo tráfego descrita pela AWS não está disponível.
O cenário de 20h não representa um ambiente 24x7. A pausa preserva tabela, logs,
fila e código; armazenamento pode continuar gerando cobrança.

Se permitido pela conta, configurar AWS Budgets no console para USD 1/mês e
alertas antecipados. Alertas não bloqueiam gastos nem chegam necessariamente
imediatamente. Nenhum orçamento ou alerta foi criado por este agente.

O primeiro deploy permanece pendente de anexação da política IAM preparada.
Benefícios Free Tier são distintos de créditos promocionais: podem reduzir o
valor real, mas não foram usados neste cálculo nem verificados nesta conta.

## Fontes oficiais consultadas

- [SQS e franquia mensal](https://aws.amazon.com/sqs/pricing/)
- [Tarifa SQS em exemplo oficial vigente](https://docs.aws.amazon.com/solutions/latest/automated-security-response-on-aws/cost.html)
- [Polling e máxima concorrência](https://docs.aws.amazon.com/lambda/latest/dg/services-sqs-scaling.html)
- [Lambda](https://aws.amazon.com/lambda/pricing/)
- [DynamoDB on-demand](https://aws.amazon.com/dynamodb/pricing/)
- [CloudWatch Logs](https://aws.amazon.com/cloudwatch/pricing/)
- [S3](https://aws.amazon.com/s3/pricing/)
- [Tarifas S3 em artigo técnico AWS de setembro de 2026](https://aws.amazon.com/blogs/storage/run-spark-31-faster-and-optimize-compute-costs-with-amazon-s3-express-one-zone-on-amazon-emr/)

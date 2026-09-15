# Roteiro do vídeo — até 20 minutos

Planejamento de gravação, não comprovação de vídeo entregue. Reserve 18 minutos
e confira a duração final antes de publicar. Não mostre arquivos `*.local.*`,
JWTs completos, senhas, Secrets Kubernetes nem a configuração da AWS CLI.

## Antes de gravar

1. Siga o README central para deploy e `start-access.ps1`. Renove as sessões STS
   se faltarem menos de 15 minutos para expirar.
2. Execute `run-smoke.ps1` para validar tudo; ele pausa os gatilhos ao terminar.
   Deixe o Grafana na janela dos últimos 15 minutos e confirme os seis painéis.
3. Separe o README, os manifests, o console CloudWatch/DynamoDB e o terminal
   com as saídas resumidas do smoke. O console deve ser aberto pelo responsável.
4. Para mostrar novas invocações ao vivo, rode outro smoke durante a gravação,
   com o volume pequeno previsto em CUSTOS.md. Não deixe gatilhos ativos esperando.

## Sequência sugerida

| Tempo | Demonstração | Evidência que precisa aparecer |
|---|---|---|
| 0:00–2:00 | Arquitetura e escolhas | Kind com nove componentes; AWS Lambda, duas SQS, DynamoDB e CloudWatch; Opção A |
| 2:00–5:00 | Gateway e identidade | URL 127.0.0.1:18000; catálogo/login públicos, perfil protegido, token ausente 401, User 403, CRUD Admin |
| 5:00–8:30 | Cadastro e compras | Cadastro real, outbox enviado, aprovação abaixo de 100 e rejeição acima de 100; biblioteca só recebe aprovado |
| 8:30–11:00 | Serverless e logs | Triggers SQS reais; três eventKeys do ensaio e logs correlacionados no CloudWatch |
| 11:00–13:00 | NoSQL e idempotência | Registros DynamoDB de Welcome, PurchaseConfirmation e rejeição Skipped; explicar escrita condicional |
| 13:00–16:00 | Grafana | Totais, status, p95 e taxas; mostrar o dashboard visualmente reagindo ao tráfego e aos 500 controlados |
| 16:00–17:00 | Redis | Hit real, TTL absoluto, invalidação depois do PUT e recarga após expiração |
| 17:00–18:00 | Reprodutibilidade e fechamento | Cinco repositórios, README central, mappings Disabled e encerramento preservando dados |

## Explicações essenciais

- Users/Catalog continuam validando JWT e autorização; Kong não substitui as APIs.
- Payments continua RabbitMQ com Catalog e publica também no SQS. A função
  substitui o processo contínuo antigo de notificações.
- O simulador registra o efeito no DynamoDB; não envia e-mail externo. Duplicatas
  são tratadas por eventKey e escrita condicional, sem promessa de exatamente uma
  vez para efeitos externos. Rejeições são registradas sem confirmação de compra.
- Redis é cache do catálogo público, SQL é fonte de verdade. Evidência detalhada
  da etapa 5 mostra miss com um SELECT e hit com zero; o teste final confirma
  Redis, TTL/invalidação e o fluxo pelo Kong.
- Contadores das APIs excluem requisições rejeitadas no próprio gateway. Taxas
  usam janela de 2 minutos, e p95 é estimativa por histograma.

## Depois de gravar

Execute `stop.ps1`, confirme gatilhos Disabled, publique o vídeo em local
acessível ao avaliador e teste o link sem depender da sua sessão de login.
Confira duração de até 20 minutos e legibilidade das evidências.
Preencha os dados do grupo e inclua o link real no relatório PDF/TXT.
O arquivo de submissão será preenchido/publicado pelo responsável conforme o plano.

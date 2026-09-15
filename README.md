# FIAP Cloud Games - Orquestração Fase 3

Preparação em andamento. Este repositório ainda não permite subir a stack final.
O enunciado oficial é a referência local `TC NETT - Fase 3.pdf`, páginas 3 a 7.

## Arquitetura escolhida

Kind local executará UsersAPI, CatalogAPI, PaymentsAPI, SQL Server, RabbitMQ,
Kong, Redis, Prometheus e Grafana. Kong será a única entrada HTTP de negócio.
A AWS executará uma Lambda .NET 8, duas filas SQS, DynamoDB e CloudWatch Logs,
declarados no repositório independente da função por AWS SAM.

Opção A de observabilidade: Prometheus coleta UsersAPI/CatalogAPI e Grafana
exibe latência, total/contagem por status HTTP e taxa de erros. Essa opção
atende à página 4 do PDF com ferramentas locais e manifests versionados.
PaymentsAPI mantém a mensageria RabbitMQ com CatalogAPI e envia notificações ao
SQS. UsersAPI usa SQS pelo outbox existente. NotificationsAPI antiga é apenas referência.

## Repositórios

Cinco projetos ativos independentes, em pastas irmãs:
- `tech-challenge-2-users-api`
- `tech-challenge-2-catalog-api`
- `tech-challenge-2-payments-api`
- `tech-challenge-3-notifications-function`
- `tech-challenge-3-orchestration`

Destino autorizado: usuário GitHub `arthuurqueirozz`. Repositórios criados:

- [UsersAPI](https://github.com/arthuurqueirozz/tech-challenge-2-users-api)
- [CatalogAPI](https://github.com/arthuurqueirozz/tech-challenge-2-catalog-api)
- [PaymentsAPI](https://github.com/arthuurqueirozz/tech-challenge-2-payments-api)
- [Notifications Function](https://github.com/arthuurqueirozz/tech-challenge-3-notifications-function)
- [Orchestration](https://github.com/arthuurqueirozz/tech-challenge-3-orchestration)

As bases do grupo são de
`leo-bernar`; autorização para publicar versões modificadas confirmada.
Os três projetos evoluídos preservam histórico e tag `fase-2-final`.
A pasta contêiner não é um monorepositório.

## Preparação

Git, SDK .NET 8, Docker Desktop com containers Linux, Kind, kubectl,
AWS CLI, SAM CLI, Git Bash, curl e jq. No Windows, abra novo terminal após
instalar ferramentas. Os scripts Bash herdados serão executados pelo Git Bash.
Copie `.env.example` para `.env` e preencha apenas localmente.

Perfil AWS: `fiap-fase3`; região: `us-east-1`; teto solicitado: USD 1/mês.
Sem créditos promocionais. [Estimativa e limites de uso](docs/CUSTOS.md):
cerca de USD 0,20 para as sessões mensais descritas, sem descontos gratuitos.
O SAM mantém os gatilhos pausados por padrão; habilitar nos testes e pausar ao terminar.
O login IAM via chave foi configurado pelo responsável após falha de OAuth.
O perfil do host não é automaticamente disponibilizado aos containers:
a etapa integrada deve renderizar Secrets locais, ignorados pelo Git.
A Lambda utiliza sua execution role; Docker Linux já foi iniciado e verificado.

## Estado e próximos gates

Etapa 1: baselines da Fase 2 passaram em 53 testes; branches e tags preservadas.
Etapas 2 e 3: stack AWS criada; 18 testes locais, lint e build SAM passaram.
Smoke real passou em 18 verificações, incluindo os dois eventos por SQS,
duplicidade, lote parcial e recuperação automática após falha de dependência.
Resultados e limites em [EVIDENCIAS-CLOUD.md](docs/EVIDENCIAS-CLOUD.md).
Etapa 4 concluída: 28 testes UsersAPI, 12 PaymentsAPI e 11 verificações integradas
com AWS real, falhas parciais, recuperação e logs dos cinco eventos sintéticos.
[Executar o ensaio dos produtores](docs/ETAPA-4.md) e
[consultar evidências](docs/EVIDENCIAS-ETAPA-4.md).
As roles dos produtores permitem somente SendMessage na respectiva fila;
os containers recebem sessões STS temporárias. Ensaio encerrado com containers
parados e gatilhos Lambda desabilitados, preservando dados.
Etapa 5 concluída: Redis no catálogo público com TTL/invalidação e fallback SQL;
29 testes CatalogAPI e 21 verificações HTTP com Redis/SQL reais passaram.
Hits de lista/detalhe reduziram SELECTs de 1 para 0. Startup sem Redis e
reconexão também validados, sem mudanças AWS.
[Executar o ensaio de cache](docs/ETAPA-5.md) e
[consultar evidências](docs/EVIDENCIAS-ETAPA-5.md).
Etapa 6 concluída no gate técnico: métricas nas duas APIs, Prometheus/Grafana no
Kind, datasource e dashboard provisionados por Git. 59 testes locais e 33
verificações integradas passaram; 94 requisições conferidas por serviço/status,
incluindo oito erros 500 reais e recuperação. Consultas dos seis painéis
validadas via Grafana; inspeção visual no navegador ainda pendente.
[Executar e acessar o dashboard](docs/ETAPA-6.md) e
[consultar evidências](docs/EVIDENCIAS-ETAPA-6.md).
Etapa 7 concluída no gate técnico: Kong OSS 3.9.3 no Kind, configuração
declarativa e JWT com segredo local. 71 verificações passaram; 52 chamadas HTTP
somente pelo gateway, com validação de tokens e permissões Admin/User.
Recuperação do ambiente após reinício do computador também executada.
[Implantar, recuperar e acessar o Kong](docs/ETAPA-7.md) e
[consultar evidências](docs/EVIDENCIAS-ETAPA-7.md).
Etapa 8 ainda precisa consolidar todos os componentes e validar cadastro,
compra e notificações pelo gateway, com deploy completo do zero.
Vídeo e relatório permanecem pendentes.

O README central receberá os comandos validados de build/carga no Kind,
deploy integrado, inicialização, acesso via Kong, dashboard, diagnóstico e
limpeza conforme os respectivos gates forem executados.

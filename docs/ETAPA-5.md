# Etapa 5 — Redis no CatalogAPI

Gate concluído em 2026-09-14. Requisitos DATA-004/005/006/007, páginas 5–6 do
PDF oficial: Redis real nas consultas públicas, driver IDistributedCache,
redução comprovada de consultas SQL, TTL, invalidação e falha do cache.
Evidências em [EVIDENCIAS-ETAPA-5.md](EVIDENCIAS-ETAPA-5.md).

## Comportamento

Cache-aside somente em GET /api/games e GET /api/games/{id}. A lista atual
contém jogos ativos ordenados por título e não tem parâmetros de filtragem ou
paginação. Chaves: fcg:catalog:v1:games:active:title-asc e
fcg:catalog:v1:game:{GUID canônico}. Novos parâmetros que alterem a resposta
deverão entrar na chave. Não são armazenados 404, JWTs nem dados de biblioteca.

O decorador CachedGameCatalogService usa IDistributedCache/Redis; a implementação
SQL existente continua responsável pelos dados e pelas mutações. Compras e
biblioteca não passam pelo cache, preservando os preços e invariantes do SQL.
TTL absoluto de 60 segundos por padrão, contado antes do início da consulta;
hits não renovam sua duração. O ensaio usa cinco segundos para exercitar expiração.

Create/update/delete invalidam a lista e o detalhe após commit. Erros Redis não
desfazem SQL: leituras fazem fallback; mutações confirmadas continuam bem-sucedidas.
Ambas as remoções são tentadas. Não há transação distribuída: falha de invalidação
ou leitura concorrente pode servir dado antigo até expirar o TTL. Essa limitação
é explícita e coberta pelo teste de invalidação malsucedida. Redis é descartável.

Health: Redis indisponível produz Degraded com HTTP 200; SQL/RabbitMQ continuam
obrigatórios (Unhealthy/503). Liveness independe das dependências. Conexão Redis
usa AbortOnConnectFail=false, BacklogPolicy.FailFast e timeouts de 500 ms; a
avaliação desses timeouts depende do heartbeat do cliente. Startup e consultas
SQL funcionam sem Redis, com reconexão automática posteriormente.

## Executar o ensaio local

Pré-requisitos: Docker Desktop Linux, PowerShell e CatalogAPI em pasta irmã.
O ambiente é independente do ensaio da etapa 4 e não requer perfil AWS nem
credenciais de produtores. A porta 127.0.0.1:18081 deve estar livre: pare o ensaio
anterior se necessário. Execute na pasta de orquestração:

```powershell
./scripts/prepare-stage5.ps1
docker compose --env-file stage5.local.env -f compose.stage5.yaml config --quiet
docker compose --env-file stage5.local.env -f compose.stage5.yaml up -d --build
./scripts/stage5-smoke.ps1
```

prepare-stage5 gera senhas e chave JWT aleatórias em stage5.local.env, ignorado
pelo Git. Preserva valores existentes. Não imprimir Compose sem --quiet nem
ambientes de containers. O smoke assina em memória um JWT Admin sintético com
a chave exclusiva deste ensaio, sem persistir/exibir o token. Isso testa CRUD e
cache; login real foi validado na etapa 4 e será revalidado no fluxo final.

compose.stage5 deriva os serviços SQL/RabbitMQ/Catalog da etapa 4. Adiciona Redis
7.4-alpine, validado como 7.4.11, sem volume, sem snapshots/AOF, com 64 MB de
maxmemory e eviction allkeys-lru. Redis/SQL/RabbitMQ não têm portas no host.
Somente CatalogAPI usa porta loopback para o gate de desenvolvimento; a entrada
única via Kong/Kind continua pendente nas etapas próprias.

O smoke verifica os SELECTs emitidos pelo EF nos logs do container: primeiro
GET consulta SQL; repetição imediata não consulta. Logging Database.Command está
em Information apenas neste ensaio, sem habilitar sensitive data logging.
Depois prova TTL real no Redis, CRUD, falha, startup sem Redis e reconexão.
O teste para/restaura Redis e recria CatalogAPI. Executar sem tráfego paralelo.

Saída: stage5-smoke.local.json com resultados, contagens e IDs sintéticos; nunca
segredos. Dados sintéticos são desativados via API no finally. Se interrompido
à força, execute start redis, confira health e identifique os dados de teste.

## Encerrar

```powershell
docker compose --env-file stage5.local.env -f compose.stage5.yaml stop
docker compose --env-file stage5.local.env -f compose.stage5.yaml ps --status running
```

Volumes SQL/RabbitMQ são preservados; Redis perde seu cache ao reiniciar.
Nenhum recurso AWS foi criado, ativado ou alterado nesta etapa.
Manifests Redis no Kind e ensaio via Kong serão consolidados na etapa integrada.

## Referências técnicas consultadas

- [Cache distribuído no ASP.NET Core](https://learn.microsoft.com/en-us/aspnet/core/performance/caching/distributed?view=aspnetcore-8.0).
- [Configuração StackExchange.Redis](https://seredis.dev/Configuration.html).
- [Pacote Microsoft 8.0.28](https://www.nuget.org/packages/Microsoft.Extensions.Caching.StackExchangeRedis/8.0.28).
- [Imagem oficial Redis](https://hub.docker.com/_/redis).

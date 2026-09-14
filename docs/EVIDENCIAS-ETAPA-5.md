# Evidências da etapa 5 — cache Redis

Ensaio concluído em 2026-09-14, início local 21:31:30.382Z e fim 21:31:42.845Z.
PDF páginas 5–6 reconferido antes da implementação e na conclusão do gate.
CatalogAPI .NET 8, SQL Server 2022, RabbitMQ e Redis 7.4.11 em Docker local.
Não houve chamadas nem mudanças AWS nesta etapa.

Implementação CatalogAPI: commit `c21a55e`, branch `fase-3`, preservando a tag
`fase-2-final`. Os demais microsserviços e a função não foram alterados nesta etapa.

## Testes e builds

- 29 testes CatalogAPI passaram: 19 herdados e 10 novos de cache, sem falhas
  ou pulados. Comando: dotnet run --project tests/FCG.Catalog.Tests/FCG.Catalog.Tests.csproj --configuration Release.
- Testes novos usam SQLite/EF real, contador de SELECTs e cache com relógio
  controlado: hit/miss de lista/detalhe, expiração absoluta sem renovação por hit,
  CRUD, mutação inválida, falhas de leitura/escrita/invalidação, JSON inválido,
  cancelamento e health degradado. A indisponibilidade de invalidação pode deixar
  entrada antiga até TTL; teste verifica o dado confirmado após expiração.
- Docker build de CatalogAPI e compose config --quiet passaram.
- Smoke HTTP com Redis e SQL Server reais: 21 verificações passaram.
  Roteiro em [ETAPA-5.md](ETAPA-5.md), script scripts/stage5-smoke.ps1.

## Prova de redução de consultas

Contagens obtidas dos SELECTs nos logs EF, em sessão sem tráfego paralelo.
As consultas de cache miss leram um jogo sintético do SQL real; as repetições
usaram o Redis e preservaram os dados da resposta HTTP.

| Caso | Contador antes → depois | SELECTs da leitura |
|---|---|---|
| Lista: miss | 6 → 7 | 1 |
| Lista: hit | 7 → 7 | 0 |
| Detalhe: miss | 7 → 8 | 1 |
| Detalhe: hit | 8 → 8 | 0 |
| Detalhe após TTL | 8 → 9 | 1 |
| Redis desligado: detalhe | 15 → 16 | 1 |
| Hit após reconexão | 10 → 10 | 0 |

O contador da última linha pertence ao container recriado durante o teste.
Redução demonstrada nos hits: 1 para 0 SELECTs. Não foi realizado benchmark de
latência/carga; a evidência comprova redução de round-trips nas consultas testadas.

## Outros resultados reais

- PING Redis retornou PONG; lista e detalhe foram encontrados nas chaves v1.
- PTTL do detalhe foi positivo e até 5.000 ms; após expiração, SQL foi consultado.
- Create removeu lista previamente preenchida; jogo apareceu na consulta seguinte.
- Update removeu lista/detalhe; preço passou de 59,90 para 79,90 nas respostas.
- Com Redis desligado, health retornou Degraded/200. GET leu SQL e POST confirmou
  um novo jogo, visível na lista durante a indisponibilidade.
- CatalogAPI foi recriada com Redis desligado, iniciou e respondeu pelo SQL.
- Redis restaurado: health voltou a Healthy e hits voltaram a evitar SELECTs.
- Delete removeu as duas entradas; detalhe retornou 404 e lista não trouxe o jogo.

ID sintético principal: 9e175f48-1282-4c57-9146-f482f7f7870c. O smoke desativou
seus jogos de teste pela API. Evidência bruta em stage5-smoke.local.json,
ignorada pelo Git. Tokens e senhas não foram persistidos nas evidências.

## Escopo e limites

Cache apenas nas consultas públicas; compra e biblioteca permanecem no SQL.
TTL padrão da aplicação é 60 s; cinco segundos são configuração do ensaio.
Invalidação é após commit e best effort: falha ou concorrência pode deixar uma
entrada antiga até o TTL. Não é fonte de verdade nem coordenação distribuída.
Health degrada para manter disponibilidade das consultas; dados SQL continuam
obrigatórios. Cache vazio após restart é comportamento esperado.

Ensaio encerrado com quatro containers parados e volumes SQL/RabbitMQ preservados.
Sem criação de recursos ou ativação de gatilhos AWS. Kind, Kong, métricas e
entregáveis finais ainda não são validados por este ensaio.

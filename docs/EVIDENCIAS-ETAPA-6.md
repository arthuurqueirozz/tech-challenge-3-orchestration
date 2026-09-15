# Evidências da etapa 6

PDF páginas 4–5 reconferido: Opção A, métricas UsersAPI/CatalogAPI, dashboard e
implantação Prometheus/Grafana por manifests Kubernetes. Gate executado em
2026-09-14 às 22:27 BRT (2026-09-15 01:27:17–01:27:40 UTC).

Implementação: UsersAPI `8aa318d`, CatalogAPI `7b35ee3`, ambas na branch fase-3.
PaymentsAPI e a função não sofreram alterações nesta etapa.

## Resultado

- UsersAPI: 29 testes passaram. CatalogAPI: 30. Total 59, sem falhas ou pulados.
  Novos testes verificam cardinalidade por template, normalização de método,
  status 401/404/500, histograma e exclusão de IDs e métricas administrativas.
- Imagens Docker compiladas/carregadas no Kind, Kubernetes v1.37.0.
- Sete deployments prontos: SQL Server, RabbitMQ, Redis, Users, Catalog,
  Prometheus 3.14.0, Grafana OSS 13.2.1. Services ClusterIP.
- Grafana inicialmente sofreu eviction por volume limitado a 256 MiB. Após
  ajuste para 2 GiB, novo pod ficou Ready, sem reinícios na conferência final.
- Promtool aprovou a configuração efetivamente montada no Prometheus.
- Smoke final passou em 33 verificações, com tráfego HTTP e dependências reais.

## Contagem exata do ensaio final

| Serviço | 200 | 400 | 401 | 404 | 500 | Total |
|---|---:|---:|---:|---:|---:|---:|
| UsersAPI | 13 | 12 | 12 | 12 | 4 | 53 |
| CatalogAPI | 12 | 0 | 12 | 13 | 4 | 41 |
| Total | 25 | 12 | 24 | 25 | 8 | 94 |

Todos os deltas foram conferidos contra os contadores coletados pelo Prometheus.
Havia tráfego de uma tentativa anterior; os totais acumulados no último snapshot
eram 106 em Users e 82 em Catalog. O script usa deltas para não confundir sessões.
GUIDs distintos apareceram no HTTP, mas não nos labels: detalhe do catálogo usa
/api/games/{id:guid}; rotas inexistentes usam unmatched. Health e /metrics não
entraram nas métricas de negócio.

## Grafana e histogramas

API confirmou dashboard fcg-http como provisioned=true, seis painéis, datasource
fcg-prometheus com URL http://prometheus:9090. As seis expressões dos painéis
foram executadas pelo proxy do próprio Grafana para Prometheus, retornando dados
finitos; painéis 4xx e 5xx reagiram nos dois serviços.

Valores do snapshot final (janela móvel de 2 min, inclui tráfego anterior):

| Medida | UsersAPI | CatalogAPI |
|---|---:|---:|
| Requisições/s | 0,8182 | 0,4875 |
| Erros 5xx (%) | 7,5674 | 12,2951 |
| Erros 4xx (%) | 67,7122 | 59,6393 |
| p95 rota demonstrada | login: 0,07873 s | detalhe: 0,00817 s |

P95 é estimativa do histograma. Percentuais de rate usam a janela de 2 min,
portanto não são iguais à divisão dos deltas de uma única rodada curta.
O teste comprova dados e consultas do dashboard. Inspeção visual/screenshot
não foi realizada: a ferramenta de navegador respondeu que não havia navegador
disponível nesta sessão. A demonstração visual no vídeo permanece pendente.

## Falha e recuperação

Users e Games foram renomeadas temporariamente apenas nos bancos deste cluster,
sem apagar linhas. Quatro requisições em cada API geraram erro SQL real e HTTP
500. Os nomes originais foram restaurados em finally; login voltou a 200 e
detalhe inexistente voltou a 404. Métricas mantiveram as rotas originais e
registraram os oito erros. Nenhum endpoint artificial de falha foi adicionado.

A primeira tentativa passou nas contagens, mas uma asserção de p95 falhou por
tratar resultado único como array no PowerShell 5. A consulta Prometheus já
retornava p95 positivo; a leitura foi corrigida e o ensaio completo passou.
Também foi ajustada a leitura UTF-8 dos títulos Grafana no script de diagnóstico.

## Reproduzir e limites

Comandos em [ETAPA-6.md](ETAPA-6.md). Arquivos de métricas e manifests versionados;
configuração e segredos locais ignorados pelo Git. Evidência bruta em
stage6-smoke.local.json. Não houve criação/ativação/alteração AWS.
Ensaio de observabilidade no Kind; não substitui o gate futuro do Kong e a
integração com Payments/SQS, nem o vídeo e relatório finais.

Encerramento: quatro port-forwards interrompidos, nó Kind parado, cluster e
volume SQL preservados. A leitura da lista de processos no PowerShell 5 foi
corrigida e o encerramento dos acessos foi executado com sucesso.

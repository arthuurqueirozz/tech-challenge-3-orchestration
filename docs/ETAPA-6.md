# Etapa 6 — métricas e dashboard

Gate técnico concluído em 2026-09-14 (horário de São Paulo): UsersAPI/CatalogAPI
instrumentadas, Prometheus e Grafana implantados no Kind por manifests, datasource
e dashboard provisionados por arquivos versionados. 59 testes locais e 33
verificações integradas passaram. [Evidências](EVIDENCIAS-ETAPA-6.md).

## Métricas e painéis

As APIs expõem /metrics. Counter fcg_http_requests_total e histograma
fcg_http_request_duration_seconds medem somente tráfego de negócio /api.
Labels: route (template parametrizado ou unmatched), method (GET, POST, PUT,
DELETE, PATCH, HEAD, OPTIONS ou OTHER), status_code. Job é acrescentado pelo
scraper. Health/scraping, IDs individuais, tokens e query strings não entram
nas séries de negócio. O middleware envolve o handler de exceções e captura
o template antes que o tratamento de erro remova o endpoint.

Prometheus coleta a cada 5 s. O dashboard fcg-http tem filtro por serviço,
atualização a cada 5 s e seis painéis: total desde início do processo, total por
status HTTP, p95 por rota, requisições/s, erros de servidor 5xx (%) e erros de
cliente 4xx (%). Taxas e p95 usam janela móvel de 2 minutos. P95 é estimado a
partir dos buckets, não uma amostra exata. Requisições sem tráfego recente podem
não ter p95; taxas de erro sem tráfego ficam em zero.

Contadores brutos reiniciam com o processo; não são totais permanentes. As
consultas rate tratam resets. Erros 4xx e 5xx têm painéis separados para não
confundir rejeição do cliente com falha do servidor. Cada taxa usa todas as
requisições de negócio do respectivo serviço como denominador.

## Deploy a partir dos arquivos

Pré-requisitos: Docker Desktop Linux, Kind, kubectl, PowerShell, três repositórios
irmãos (UsersAPI, CatalogAPI e Orchestration). Pelo menos a capacidade local já
validada: Docker com 16 GB disponíveis. Executar na pasta de orquestração:

```powershell
./scripts/deploy-stage6.ps1
./scripts/start-stage6-access.ps1
./scripts/stage6-smoke.ps1
```

O deploy cria cluster fcg-fase3-stage6 (kindest/node:v1.37.0), kubeconfig isolado,
imagens locais, namespace fcg-stage6 e Secrets gerados localmente. No Windows,
o script também localiza Kind instalado pelo WinGet se ainda não estiver no PATH.
Para rebuild em cluster existente, recria os pods das APIs com as imagens recém
carregadas. Pare os port-forwards antes de executar novamente o deploy.

Manifests: k8s/monitoring contém Prometheus 3.14.0, Grafana OSS 13.2.1,
datasource, provider e JSON do dashboard. k8s/stage6 acrescenta dependências e
APIs para este gate. Kustomize gera ConfigMaps com hash do conteúdo, referências
de volume e namespace. Não há Helm nem operador. Os manifests são JSON válido
dentro de arquivos YAML, formato aceito pelo Kubernetes/Kustomize.

Todos os Services são ClusterIP. Acesso administrativo somente por port-forward
em 127.0.0.1. Prometheus usa 24 h de retenção e limite TSDB de 256 MB; volume
temporário de 512 MiB. Grafana tem volume temporário de 2 GiB (o limite inicial
256 MiB causava eviction e foi corrigido). SQL tem PVC de 2 GiB. Não apague o
cluster/PVC se quiser preservar os dados locais; dashboard e datasource nascem
novamente dos arquivos mesmo após perder o armazenamento do Grafana.

Este ensaio não tem PaymentsAPI nem publica eventos SQS. Users usa valores
explicitamente fictícios no SDK para inicializar seu cliente, sem credenciais
AWS reais; o teste usa login de admin sem cadastrar usuários e gerar outbox.
Não use este overlay para provar notificações. A stack completa com roles reais,
Payments e Kong será consolidada nas etapas seguintes.

## Acessos

| Uso | URL local |
|---|---|
| Dashboard | http://127.0.0.1:13000/d/fcg-http |
| Prometheus | http://127.0.0.1:19090 |
| UsersAPI, apenas ensaio | http://127.0.0.1:18080 |
| CatalogAPI, apenas ensaio | http://127.0.0.1:18081 |

Grafana permite visualização anônima com papel Viewer dentro deste ambiente
local; configuração administrativa usa senha aleatória no Secret. Não exige
criação manual de datasource ou dashboard. Credenciais/settings, kubeconfig,
PIDs e evidências brutas ficam em arquivos *.local.*, ignorados pelo Git. Não
publique seus conteúdos. /metrics e ferramentas administrativas não devem ser
expostos pelas rotas de negócio do Kong.

## Teste e diagnóstico

O smoke mede deltas por serviço/status e exige a contagem exata de 94 requisições.
Exercita respostas 200/400/401/404 e oito falhas 500 reais. Para essas falhas,
renomeia temporariamente Users/Games nos bancos isolados FcgUsersDb/FcgCatalogDb,
produz erros SQL de objeto ausente e restaura os nomes em finally. Não remove
linhas. Usa GUIDs distintos para verificar que não geram séries distintas.
Valida histogramas, queries dos seis painéis através do proxy do datasource
Grafana→Prometheus e recuperação das APIs. Execute sem tráfego concorrente.

Se houver interrupção forçada durante a falha, confira e restaure os nomes
Users_stage6_fault → Users e Games_stage6_fault → Games, nos respectivos bancos,
antes de retomar. Não altere bancos de outros ambientes. O helper SQL do script
usa a senha apenas dentro do container, sem exibi-la.

```powershell
kubectl --kubeconfig stage6.kubeconfig.local.yaml -n fcg-stage6 get pods
kubectl --kubeconfig stage6.kubeconfig.local.yaml -n fcg-stage6 logs deployment/prometheus --tail=30
kubectl --kubeconfig stage6.kubeconfig.local.yaml -n fcg-stage6 logs deployment/grafana --tail=30
kubectl --kubeconfig stage6.kubeconfig.local.yaml -n fcg-stage6 exec deployment/prometheus -- promtool check config /etc/prometheus/prometheus.yml
```

## Encerrar e retomar

```powershell
./scripts/stop-stage6-access.ps1
docker stop fcg-fase3-stage6-control-plane
# Para retomar sem apagar os dados:
docker start fcg-fase3-stage6-control-plane
kubectl --kubeconfig stage6.kubeconfig.local.yaml -n fcg-stage6 get pods
./scripts/start-stage6-access.ps1
```

Aguarde os sete serviços ficarem prontos antes do novo smoke. Os scripts de
acesso controlam somente os processos kubectl criados por eles. AWS permaneceu
sem alterações nesta etapa. Gateway, ensaio completo, vídeo e relatório pendentes.

Referências: [prometheus-net](https://github.com/prometheus-net/prometheus-net),
[provisionamento Grafana](https://grafana.com/docs/grafana/latest/administration/provisioning/),
[Prometheus](https://prometheus.io/download/),
[Kind](https://kind.sigs.k8s.io/docs/user/quick-start/).

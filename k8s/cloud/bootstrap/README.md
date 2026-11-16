# Bootstrap Kubernetes da Fase 4

Esta árvore prepara a configuração cloud sem aplicar o conjunto legado do Kind.
Users/Catalog e seus Jobs de migration continuam em `../users` e `../catalog`,
com deploy individual pelo script central. Os manifests não contêm Secrets.

| Arquivo | Recursos e responsabilidade |
|---|---|
| `namespaces.yaml` | `fcg-users`/`fcg-catalog` com Pod Security restricted v1.35; `fcg-platform` baseline |
| `serviceaccounts.yaml` | Contas de cada componente, migradores sem IAM e `catalog-search-bootstrap` |
| `storage.yaml` | EBS CSI gp3 criptografado, `WaitForFirstConsumer`, retenção; SQL20Gi/Rabbit5Gi |
| `platform.yaml` | SQL, Rabbit, Redis, Payments e Kong; somente Kong possui NodePort30080 |
| `monitoring.yaml` | Prometheus/Grafana privados, dashboard existente e métricas das duas réplicas por DNS |

Antes de aplicar, o renderer central substitui `__AVAILABILITY_ZONE_A__` pelo
output real `AvailabilityZoneA` de network-compute e `__PAYMENTS_IMAGE__` por
uma imagem ECR `repo@sha256:...` publicada e verificada. Não inferir AZ pelo nome
da região. O node group, os dois PVCs e seus consumidores SQL/Rabbit usam a AZ A.
Falhas de capacidade nessa AZ não têm failover automático nesta configuração.

`kubectl kustomize k8s/cloud/bootstrap` renderiza o conjunto fonte para revisão.
O procedimento operacional aplica os recursos na ordem de dependências, após
resolver os tokens; a renderização sozinha não valida criação EBS, identidades,
DNS, Secrets ou funcionamento dos pods na AWS.

Preparação e ordem:

1. Criar os namespaces e ServiceAccounts. RBAC de deploy por API pertence à
   configuração central, sem acesso ao namespace de infraestrutura.
2. Instalar a stack runtime-identity após os outputs SAM. Aguardar Pod Identity
   Agent e EBS CSI saudáveis; a associação do EBS é administrada pelo addon,
   sem criar outra associação para `kube-system/ebs-csi-controller-sa`.
3. Aplicar StorageClass/PVCs com AZ real e preparar os Secrets/ConfigMaps abaixo.
4. Subir SQL/Rabbit/Redis; aguardar SQL e criar logins distintos por banco antes
   de executar Jobs. `sa` fica somente em `fcg-platform`; runtime usa
   datareader/datawriter e migration usa db_owner somente no próprio banco.
5. Executar migrations Users/Catalog e o bootstrap da busca com a mesma imagem
   das respectivas APIs. O Job de busca usa `catalog-search-bootstrap`, associado
   ao papel Catalog; migradores SQL não recebem papel AWS.
6. Implantar APIs, Payments e Kong com imagens/configuração verificadas. Aplicar
   monitoramento e conferir targets/health e os fluxos pelo endereço externo.

| Namespace | Configuração externa exigida | Contrato |
|---|---|---|
| `fcg-platform` | Secret `sql-bootstrap-secrets` | Chave `MSSQL_SA_PASSWORD`, disponível apenas a SQL/bootstrap administrativo |
| `fcg-platform` | Secret `rabbit-secrets` | Chave `RABBITMQ_DEFAULT_PASS` |
| `fcg-platform` | ConfigMap `payments-api-config` e Secret `payments-api-secrets` | Opções Rabbit/SQS dos binders existentes; segredo inclui `RabbitMq__Password` |
| `fcg-platform` | Secret `fcg-kong-config` | Chave `kong.json`, upstreams `users-api.fcg-users.svc.cluster.local:8080` e `catalog-api.fcg-catalog.svc.cluster.local:8080` |
| `fcg-platform` | Secret `grafana-secrets` | Chave `GF_SECURITY_ADMIN_PASSWORD`; usuário admin padrão da imagem |
| `fcg-users` | ConfigMap `users-api-config`, Secrets `users-api-secrets`/`users-migration-secrets` | Nomes exigidos pelos manifests do ciclo3b; conexões com logins distintos |
| `fcg-catalog` | ConfigMap `catalog-api-config`, Secrets `catalog-api-secrets`/`catalog-migration-secrets` | Runtime Rabbit/JWT/SQL e configuração Search; migration recebe somente SQL/seed pertinente |

Rabbit e Redis são resolvidos por
`rabbitmq.fcg-platform.svc.cluster.local:5672` e
`redis.fcg-platform.svc.cluster.local:6379`. SQL usa
`sqlserver.fcg-platform.svc.cluster.local:1433`. Valores finais são gerados fora
do Git; não transportar `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` ou
`AWS_SESSION_TOKEN` do legado para pods. Users/Payments/Catalog usam Pod Identity.

O NLB central encaminha para NodePort30080 e seu healthcheck TCP. O security group
do nó deve aceitar essa porta apenas do security group do NLB; o manifesto de
Service sozinho não cria essa restrição. O status Kong8100 e seu admin permanecem
privados; o listener de administração está desativado. O solver HTTP-01 de TLS é
um recurso operacional separado da configuração de negócio.

Prometheus usa Services headless `users-api-metrics` e `catalog-api-metrics`,
descobrindo cada pod sem token Kubernetes ou permissão de listar Secrets. Mantém
os nomes de jobs e o dashboard da Fase3. Grafana exige login, com acesso privado.
Os dados de Prometheus/Grafana e o cache Redis são efêmeros; exportar as provas
antes de recriar os pods. Os PVCs SQL/Rabbit usam `Retain`: excluir PVC/namespace
não encerra a cobrança dos volumes. A remoção final segue o inventário e a
preservação autorizados do runbook central.

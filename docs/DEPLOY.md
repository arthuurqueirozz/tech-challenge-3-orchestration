# Entrega automatizada de Users e Catalog — Fase 4

O fluxo é: PR executa restore/build/testes sem credenciais de deploy; push na `main` faz CI, constrói imagem versionada, publica no ECR, resolve o digest, executa a migration em Job e somente após sucesso aplica o Deployment e verifica rollout/status pelo Kong. Users e Catalog usam workflows próprios e alteram somente os recursos da API correspondente.

O código deste ciclo prepara esse fluxo e seu ensaio local. ECR/EKS, IAM/RBAC, conectividade do runner, HTTPS e execução real dos workflows precisam ser configurados e validados antes de declarar a entrega cloud concluída. Não há provisionamento AWS por este script.

## Pré-requisitos e configuração externa

Antes de invocar o deploy, devem existir o namespace, SQL e demais dependências, ConfigMaps, Secrets e service accounts. Bootstrap, armazenamento e identidades são responsabilidades da infraestrutura; a pipeline da aplicação não cria IAM, rede, banco, namespace, Secret ou service account. O kubeconfig deve apontar explicitamente para o contexto autorizado. Nunca execute os scripts históricos da Fase 3 como substituto deste fluxo.

| Serviço | Deployment/Service/SA web | ConfigMap web | Secret web | SA migration | Secret migration |
|---|---|---|---|---|---|
| Users | `users-api` | `users-api-config` | `users-api-secrets` | `users-migration` | `users-migration-secrets` |
| Catalog | `catalog-api` | `catalog-api-config` | `catalog-api-secrets` | `catalog-migration` | `catalog-migration-secrets` |

Os arquivos `k8s/cloud/<serviço>/bootstrap-serviceaccounts.json` definem as SAs sem permissões Kubernetes e com montagem automática de token desativada. Devem ser aplicados uma vez pelo bootstrap da infraestrutura, no namespace correto; o deploy da aplicação não os aplica. As associações EKS Pod Identity e as permissões de SQL/AWS são configuração externa. Não fornecer chaves AWS fixas aos pods, que devem usar a cadeia padrão do SDK.

| Objeto | Conteúdo, sem valores no Git |
|---|---|
| Users ConfigMap | `Jwt__Issuer`, `Jwt__Audience`, `Sqs__Region`, `Sqs__QueueUrl` e demais opções não sensíveis necessárias |
| Users Secret web | `ConnectionStrings__UsersDatabase`, `Jwt__Key` |
| Users Secret migration | `ConnectionStrings__UsersDatabase`; opcionalmente `AdminSeed__Enabled`, `AdminSeed__Name`, `AdminSeed__Email`, `AdminSeed__Password` para o primeiro administrador |
| Catalog ConfigMap | `Jwt__Issuer`, `Jwt__Audience`, `RabbitMq__Host`, `RabbitMq__Port`, `RabbitMq__VirtualHost`, `CatalogCache__Configuration` quando não contiver senha, e opções `Search__*` conforme README Catalog |
| Catalog Secret web | `ConnectionStrings__CatalogDatabase`, `Jwt__Key`, `RabbitMq__Username`, `RabbitMq__Password`; `CatalogCache__Configuration` se contiver credencial |
| Catalog Secret migration | Somente `ConnectionStrings__CatalogDatabase` |

Os pods usam `ASPNETCORE_ENVIRONMENT=Production`. Na AWS, Search exige HTTPS, autenticação AWS e região; a flexibilização Development do QA não é configuração de produção. Não duplique a mesma chave entre ConfigMap/Secret. O Job não recebe o ConfigMap ou o Secret web, somente o Secret de migration. Não copie a senha de seed para o Secret web; o startup normal não executa seed. Consulte [MIGRATIONS.md](MIGRATIONS.md) sobre validação, repetição e bootstrap do índice.

## Workflows e sessões temporárias

As APIs contêm `.github/workflows/ci-cd.yml`. Configure estas Repository Variables em cada repositório autorizado antes de ativar o deploy:

| Variable | Contrato |
|---|---|
| `AWS_ACCOUNT_ID` | ID de 12 dígitos da conta destinada à demonstração |
| `AWS_REGION` | Região dos recursos efetivamente provisionados |
| `AWS_SESSION_EXPIRES_AT` | Data ISO-8601 com timezone da expiração real da sessão restrita; a pipeline exige de 20 a 65 minutos restantes antes de alterar o ambiente |
| `ECR_REPOSITORY` | Nome do repositório ECR da própria API |
| `EKS_CLUSTER_NAME` | Cluster autorizado e acessível pelo runner |
| `SSM_NODE_INSTANCE_ID` | InstanceId real do único node gerenciado, redescoberto após substituição |
| `SSM_TUNNEL_DOCUMENT_NAME` | Documento fixo `fcg-fase4-eks-tunnel`, sem destino ou porta remotos configuráveis |
| `K8S_NAMESPACE` | Namespace previamente preparado |
| `ORCHESTRATION_REPOSITORY` | `owner/repository` deste repositório, com acesso concedido ao workflow |
| `ORCHESTRATION_REF` | SHA completo de 40 caracteres de uma versão revisada/publicada da orquestração; não usar branch flutuante nem inventar SHA enquanto a mudança só existir localmente |
| `SMOKE_URL` | HTTPS real para `/status/users` ou `/status/catalog` no gateway |

Na cloud, o workflow chama `deploy-cloud-api.ps1`, que abre o túnel Session Manager, mantém CA e tls-server-name do EKS e executa o script de migration/rollout abaixo dentro da mesma sessão; fecha somente o próprio túnel ao final. `scripts/renew-cloud-deploy-session.ps1` instala sessões temporárias nos dois repositórios via GitHub CLI, sem valores sensíveis em argumentos. A região e os namespaces permitidos são Ohio (`us-east-2`) e `fcg-users`/`fcg-catalog`; uma política de admissão impede Services externos nesses namespaces. A janela 13–18/11/2026 e a expiração STS são verificadas antes de publicação/deploy. Consulte [CLOUD-OPERACAO.md](CLOUD-OPERACAO.md) para a sequência completa e o estado real.

Secrets do deploy: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` e `AWS_SESSION_TOKEN` da sessão STS limitada do papel específico da API. O workflow confere conta e o papel `fiap-f4-users-deploy` ou `fiap-f4-catalog-deploy`; esses papéis ainda precisam ser criados com IAM/RBAC mínimo. Não usar `AccountFullAccessRole`. PR não recebe esses Secrets. Sessões precisam ser renovadas antes de cada janela, diretamente nos Secrets, sem copiar valores para chat, Git ou logs; o fluxo não oferece credenciais permanentes.

Se a orquestração for privada, fornecer `ORCHESTRATION_READ_TOKEN` com leitura somente desse repositório. O token padrão do workflow de uma API não concede automaticamente acesso a outro repositório privado. Se a orquestração for pública, a leitura pode usar o token padrão. Manter `ORCHESTRATION_REF` fixo em ambos os casos.

A `main` candidata é conferida antes da publicação e novamente antes de alterar o cluster. A imagem recebe tag com SHA completo e execução/tentativa; o digest resolvido do ECR é passado ao script. O workflow registra build/ref/imagem e serializa deploys de cada API sem cancelar migration/rollout em andamento. A sessão ainda deve ser válida para todos os timeouts. Expiração ou falta de acesso deve falhar claramente, sem abrir a administração do cluster como atalho.

## Script compartilhado e manifests

`scripts/deploy-api.ps1` é compatível com PowerShell 5/7 e exige `kubectl` no PATH. Todo comando fornece kubeconfig, contexto e namespace explícitos. Os JSONs em `k8s/cloud/users` e `k8s/cloud/catalog` são templates: o script substitui a imagem sentinela por `repo@sha256:<64hex>`, anota as versões e gera arquivos temporários. Não aplique diretamente `deployment.json` ou `migration-job.json`, nem use tag ou `latest` como imagem de deploy.

O exemplo abaixo pressupõe variáveis de ambiente não sensíveis preenchidas com os valores reais do ambiente já preparado. A sessão/autorização do kubeconfig é externa ao script; não coloque senhas nesses argumentos.

```powershell
.\scripts\deploy-api.ps1 -Service users `
  -Kubeconfig $env:FCG_KUBECONFIG -Context $env:FCG_KUBE_CONTEXT `
  -Namespace $env:FCG_NAMESPACE -Image $env:FCG_USERS_IMAGE_DIGEST `
  -BuildSha $env:FCG_USERS_BUILD_SHA -OrchestrationRef $env:FCG_ORCHESTRATION_REF `
  -DeploymentId $env:FCG_DEPLOYMENT_ID -SmokeUrl $env:FCG_USERS_SMOKE_URL `
  -OutputPath $env:FCG_DEPLOY_RESULT_PATH
```

Para Catalog, trocar `-Service` e as variáveis específicas da imagem/build/URL. `BuildSha` e `OrchestrationRef` exigem 40 caracteres hexadecimais; `DeploymentId` é um DNS label de até 31 caracteres, por exemplo o identificador de execução/tentativa da pipeline. Timeouts padrão: migration 300 segundos e rollout 300 segundos, ajustáveis entre 30 e 600 pelos parâmetros correspondentes. O diretório do arquivo de resultado precisa existir. O JSON de resultado contém somente versões, recurso, etapas e horários, sem kubeconfig, tokens ou configuração de aplicação.

1. O script recusa outro Job de migration ativo da mesma API. Essa checagem não é um lock atômico: a pipeline serializa as execuções e operadores manuais devem fazer o mesmo.
2. Cria Job `<serviço>-migrate-<SHA12>-<DeploymentId>`, com `--migrate`, mesma imagem por digest da futura API, `backoffLimit=0` e deadline. Se já existir, confere identidade, imagem, argumentos, referências de configuração e estado antes de reutilizá-lo; nunca apaga um Job ativo.
3. Aguarda `Complete`; `Failed`, timeout ou configuração divergente encerram o processo antes de alterar o Deployment. O Job concluído é mantido como evidência e permite repetição idempotente da mesma execução. Para tentar novamente um Job falho após corrigir a causa, usar um novo `DeploymentId` após inspeção.
4. Aplica somente Service e Deployment da API escolhida. Usa duas réplicas, `maxUnavailable=0`, `maxSurge=1`, cinco segundos de prontidão mínima e probes HTTP. Startup/liveness consultam `/health/live`; readiness consulta `/health`. OpenSearch permanece fora da readiness geral do Catalog.
5. O encerramento espera cinco segundos antes de enviar o sinal ao processo e permite 45 segundos ao pod, cobrindo o timeout padrão de 30 segundos do host. O cluster precisa de capacidade para o pod adicional e dependências saudáveis. Essa configuração sozinha não comprova ausência de interrupção.
6. Aguarda rollout e, quando `SmokeUrl` é fornecida, exige 200, corpo `service` da API esperada/`status=running` e cabeçalho `X-Build-Sha` igual ao candidato. Kong expõe somente as rotas exatas GET `/status/users` e `/status/catalog`, encaminhando à raiz das APIs; não expõe administração ou `/metrics` por essas rotas.

O smoke exige HTTPS com validação normal do certificado; HTTP só é aceito em loopback para QA isolado. Quando omitido, o resultado registra `Smoke=skipped`, que não constitui aceite completo do deploy. O workflow exige a URL. Em falhas, o diagnóstico automático limita-se a nomes/fases dos pods; não despeja logs, Secrets ou ambiente dos containers.

## Falhas, recuperação e limites

Se a migration falhar ou expirar, o Deployment anterior permanece. Investigue o Job e o banco com acesso autorizado, corrija a causa e reexecute serialmente; não apague Job ativo ou reverta schema automaticamente. Uma migration já concluída pode ter persistido mesmo se uma etapa posterior falhar.

Se rollout ou smoke falharem, a nova versão pode ter sido parcialmente aplicada. O script retorna falha e não faz rollback automático. Recupere uma imagem anterior conhecida e compatível usando o mesmo processo de migration/rollout, mantendo schema aditivo; em seguida reconcilie a `main` por correção/revert e pipeline. Não execute `Down`, drop, recriação de índice ou alteração destrutiva dos dados como recuperação.

Os manifests deste ciclo abrangem somente Users/Catalog e SAs de bootstrap. Não provisionam dependências, registry, Load Balancer, TLS ou permissões cloud. O primeiro bootstrap de busca deve ocorrer separadamente, com escritores/workers controlados; o deploy rotineiro executa somente `--migrate`. A evidência local de renderização e rollout não substitui o deploy real por push na AWS, a medição contínua de requisições e a validação de NoSQL/cache.

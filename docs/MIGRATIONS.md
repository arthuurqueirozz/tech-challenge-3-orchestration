# Migrations administrativas — Fase 4

Users e Catalog usam a própria imagem da API com o argumento `--migrate` para preparar o banco. O comando aplica as migrations pendentes e termina; não inicia HTTP, consumidores, publicação de eventos ou indexação. Execute-o antes de iniciar a aplicação ou liberar uma nova versão. O startup web não aplica migrations nem cria o administrador.

## Configuração e execução

Use a imagem construída a partir da mesma versão que será iniciada como API. Entregue a configuração por arquivo de ambiente local ignorado pelo Git ou pelo mecanismo de secrets do ambiente; não passe senhas em argumentos nem publique arquivos renderizados.

| Comando | Configuração necessária |
|---|---|
| Users `--migrate` | `ConnectionStrings__UsersDatabase` |
| Users com administrador inicial | Conexão e `AdminSeed__Enabled=true`, `AdminSeed__Name`, `AdminSeed__Email`, `AdminSeed__Password` |
| Catalog `--migrate` | `ConnectionStrings__CatalogDatabase` |

JWT, RabbitMQ, Redis, AWS e OpenSearch não são necessários para esses comandos. O SQL Server precisa estar acessível e a identidade SQL precisa poder aplicar o schema. Sem seed habilitado, Users apenas prepara o banco. Com seed habilitado, nome, email e senha forte são validados antes de alterar o schema; forneça esses valores externamente. Uma conta existente com o mesmo email normalizado é preservada, incluindo senha e papel. Não use o seed para promover usuários ou trocar senhas.

Na stack local de busca, depois de preparar os arquivos conforme [SEARCH-LOCAL.md](SEARCH-LOCAL.md), para aplicar somente o schema do Catalog:

```powershell
$composeArgs = @('--env-file', 'search.local.env', '-f', 'compose.search.local.yaml')
docker compose @composeArgs up -d --wait --wait-timeout 240 sqlserver
docker compose @composeArgs run --rm --no-deps --build catalog-api --migrate
if ($LASTEXITCODE -ne 0) { throw 'Migration falhou; não iniciar a nova API.' }
```

O exemplo prepara apenas SQL. Para habilitar a busca pela primeira vez, siga a sequência completa de `SEARCH-LOCAL.md`: `--search-bootstrap` já aplica migrations antes de criar/conferir o mapping e enfileirar os jogos. Não é necessário executar os dois comandos nessa sequência. `--migrate` e `--search-bootstrap` são modos distintos e não podem ser combinados.

Users não faz parte dessa stack focada. Ao executar sua imagem, acrescente `--migrate` ao comando do container e forneça somente a conexão e, quando necessário, os campos do seed acima. Depois do sucesso, inicie a API com sua configuração web completa.

## Falhas e readiness

Sucesso retorna código zero; configuração inválida, conexão indisponível ou falha de migration retornam código diferente de zero. Confira o código do processo, não apenas a presença de um log. Corrija a causa e reexecute de forma serializada por serviço. As migrations aplicadas ficam registradas no histórico EF; repetição bem-sucedida não reaplica o schema nem duplica o administrador. Uma falha após uma migration já concluída pode deixar etapas anteriores aplicadas: inspecione o histórico antes de qualquer intervenção manual.

Na execução web, `/health/live` verifica se o processo responde. A readiness SQL exige conexão e nenhuma migration conhecida pela versão em execução pendente. Um banco vazio pode estar acessível e ainda assim manter a API fora de serviço (`503` na readiness). Essa verificação consulta o estado sem criar schema ou executar seed. Não compara o banco com migrations futuras desconhecidas por um pod antigo; alterações aditivas são necessárias para coexistência durante Rolling Update. O OpenSearch continua fora da readiness geral do Catalog.

## Contrato para o deploy

Os Jobs Kubernetes em `k8s/cloud` usam a mesma imagem por digest da API correspondente e executam `--migrate` antes do rollout, com uma execução por serviço e espera explícita pelo sucesso no script `scripts/deploy-api.ps1`. Uma falha bloqueia a atualização. Consulte [DEPLOY.md](DEPLOY.md) para os nomes de Secrets, SAs, parâmetros e comportamento em repetição/falha. O bootstrap de busca permanece uma operação administrativa separada, com escritores/workers controlados conforme seu guia. Não execute `Down`, drop de banco ou recriação de índice como recuperação automática.

Este guia documenta os comandos e o fluxo local. Permissões, configuração e execução cloud dos Jobs/pipelines continuam pendentes de validação. Os scripts históricos da Fase 3 abaixo do README principal pressupõem o comportamento antigo de inicialização e não são o caminho de deploy da Fase 4.

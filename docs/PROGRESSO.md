# Progresso - FIAP Fase 3

Atualizado em 2026-09-14.

## Etapa atual

Etapas 0 a 4 concluídas em seus gates técnicos. Produtores adaptados e ensaio integrado com AWS real aprovado: cadastro, compra aprovada/rejeitada, falhas parciais e recuperação, com logs correlacionados. Evidências em `tech-challenge-3-orchestration/docs/EVIDENCIAS-ETAPA-4.md`; gates anteriores em `docs/EVIDENCIAS-CLOUD.md`. Próxima etapa: 5, Redis no CatalogAPI. Kind/Kong, métricas, integração final, vídeo e relatório ainda pendentes.

## Etapa 4 — estado atual

- UsersAPI envia UserCreatedEvent em JSON direto ao SQS pelo outbox existente, mantendo EventId, backoff e conclusão somente após envio. RabbitMQ removido porque não restou outro uso. Testes: 28 passaram (23 herdados + 5 novos).
- PaymentsAPI mantém RabbitMQ para CatalogAPI e acrescenta SQS para notificações. Exceções propagam ao consumer; retries em 5/15/30 segundos, depois fila de erro. Sem novo outbox. Testes: 12 passaram (8 herdados + 4 novos).
- Compose de desenvolvimento derivado da Fase 2 com SQL Server, RabbitMQ e três APIs, sem NotificationsAPI histórica. CatalogAPI não sofreu alterações de código; integração final em Kind será feita posteriormente.
- Gate real: 10 verificações do smoke + correlação dos cinco eventos no CloudWatch passaram. SQL outbox, biblioteca, DynamoDB e logs conferidos. Falha Users preservou cadastro/EventId; falha parcial Payments recuperou notificação com mesmo OrderId após redelivery, sem duplicar jogo.
- SAM lint/build e builds Docker passaram. Política FCGFase3Deploy ampliada somente no escopo das duas roles nomeadas de produtores, após atualização pelo responsável. SAM criou ambas; cada runtime recebe somente SendMessage na própria fila, via credenciais STS de uma hora, em arquivos locais ignorados pelo Git.
- Encerramento conferido: stack UPDATE_COMPLETE, NotificationsEnabled=false, dois mappings Disabled, Lambda Active/Successful, filas drenadas e cinco containers parados. Volumes e recursos preservados; S3 totalizou 1.615.905 bytes. Fatura real ainda não apurada.
- Roteiro reproduzível em `tech-challenge-3-orchestration/docs/ETAPA-4.md`. Segredos e JWTs não entram nas evidências publicadas.
- Commits da etapa: UsersAPI `ca66442`, PaymentsAPI `63ef444`, função/IAM `4ed2cdc`; CatalogAPI permanece `ecd30fd`. Orquestração registra roteiro, scripts e evidências no commit desta atualização documental.

## Histórico das etapas 0 a 3

- Publicação confirmada em 2026-09-14: três forks em `arthuurqueirozz` com branch `fase-3` e tag `fase-2-final` publicadas; função `f1f9c32` e orquestração inicial `594d905` em main. `gh repo view` confirmou os cinco URLs e Git local confirmou acompanhamento dos respectivos remotos sem alterações pendentes. Links no README de orquestração. A NotificationsAPI histórica não foi publicada novamente nem alterada.
- Nova função: `tech-challenge-3-notifications-function`, commit `f1f9c32`. Contratos preservados; handlers para os dois eventos, falhas parciais de lote, escrita condicional DynamoDB, logs estruturados sem nome/e-mail e template SAM.
- Testes da função: 18 passaram via `dotnet run --project tests/FCG.Notifications.Function.Tests/FCG.Notifications.Function.Tests.csproj --configuration Release`. Testes em memória não substituem integração real.
- `sam validate --lint --template-file template.yaml --region us-east-1`: template válido.
- `sam build --template-file template.yaml`: sucesso; pacote .NET 8/linux-x64 preparado em `.aws-sam/build/NotificationsFunction` e template em `.aws-sam/build/template.yaml`. SAM instalou Amazon.Lambda.Tools 7.0.0. Execução fora do sandbox necessária para seus metadados locais.
- SQS: duas filas, visibility 180s, retenção 4 dias, resposta parcial, concorrência 2 por trigger. Lambda 256 MB/30s; DynamoDB on-demand; logs 7 dias.
- Controle de custo: parâmetro SAM `NotificationsEnabled=false` por padrão; habilitar explicitamente nos testes cloud e desabilitar ao encerrar. Lint e build SAM passaram novamente após a alteração. Gatilhos pausados não interrompem retenção de mensagens nem cobrança de armazenamento.
- Sem créditos promocionais, conforme informado pelo responsável em 2026-09-14. Estimativa sem benefícios gratuitos: USD 0,20344 para até 20 horas mensais de gatilhos ativos e 1.000 invocações, sob as demais hipóteses de `tech-challenge-3-orchestration/docs/CUSTOS.md`. Reserva operacional de USD 0,30; não representa garantia de teto. Validar uso real na primeira sessão.
- Garantia do simulador: o efeito é o registro durável atômico no DynamoDB, não e-mail externo. Logs são projeção de diagnóstico. Retry de resposta perdida não duplica o registro; itens incompletos/conflitantes não são reconhecidos. Limitações descritas no README.
- Política de deploy em `tech-challenge-3-notifications-function/iam/deploy-policy.template.json`; versão preenchida em `iam/deploy-policy.local.json`, ignorada pelo Git. Anexação confirmada em 2026-09-14 e criação da stack validada sem ampliar a política. Quota Lambda da conta: 10 execuções simultâneas.
- Bucket de artefatos privado, com os quatro bloqueios de acesso público ativos e criptografia AES256. Stack com oito recursos previstos, sem rede/servidores gerenciados adicionais. Criação e atualização dos mappings via changesets revisados; somente os dois mappings mudaram ao ativar os testes.
- Docker Desktop iniciado; motor Linux 29.6.1 funcionando, 20 CPUs e aproximadamente 16 GB disponíveis, sem containers em execução na conferência.
- Encerramento cloud: stack UPDATE_COMPLETE, NotificationsEnabled=false, ambos os mappings Disabled; Lambda Active/Successful com tabela original. Role contém somente a política de runtime, sem política temporária. Filas drenadas no smoke; 807.034 bytes de artefatos S3. Recursos e dados preservados; fatura real ainda não apurada.
- Orquestração: README inicial com arquitetura/Opção A, links de destino, pré-requisitos e placeholders em `.env.example`. Manifests finais ainda não implementados.
- Varredura inicial dos novos fontes não encontrou padrões de access keys ou chaves privadas. `git diff --cached --check` aplicado antes dos commits.

## Referência e escopo

- Plano lido integralmente: `fiap-fase-3-implementation-plan.md`.
- PDF original preservado: `TC NETT - Fase 3.pdf`, nesta pasta de trabalho.
- SHA256: `081F70B8508E7E0E6B73C0402825D500ECD4903DFCA66995083544E6FC1D8F32`.
- Texto das oito páginas lido com `pdftotext -layout -enc UTF-8`. Nenhuma divergência textual encontrada em relação à matriz do plano. Inspeção visual não realizada; `pdftoppm` e `pdfinfo` não encontrados no PATH.
- Mantidas as escolhas: .NET 8, Kind + AWS, Kong, Prometheus/Grafana (Opção A), Redis, Lambda/SQS/DynamoDB/CloudWatch e SAM.
- Interpretações preservadas: JWT nas rotas protegidas; métricas em UsersAPI/CatalogAPI; CloudWatch para logs da função; Kubernetes local. A redação geral dos entregáveis na página 6 é lida em conjunto com a Opção A explícita na página 4.

## Ambiente identificado

Pasta: `C:\Users\Arthur\Desktop\fiap\TechChallenge3`. Windows build 26200, x64, PowerShell.

| Ferramenta | Evidência / situação |
|---|---|
| Git | 2.47.1.windows.2 |
| .NET SDK | 8.0.425 disponível; também instalados 7.0.410 e 9.0.305 |
| Docker | Motor Linux 29.6.1 validado após iniciar Docker Desktop; 20 CPUs e aproximadamente 16 GB disponíveis |
| kubectl | v1.36.1 |
| Kind | v0.33.0 instalado pelo WinGet, hash verificado pelo instalador |
| AWS CLI | v2.36.44 instalado por MSI oficial com assinatura válida, por usuário |
| AWS SAM CLI | v1.166.2 instalado por MSI oficial com assinatura válida; exigiu elevação UAC após erro Windows 1925 |
| GitHub CLI | Consulta autenticada `gh api user --jq .login` confirmou `arthuurqueirozz` fora do bloqueio de rede do sandbox |
| Bash / curl.exe | Disponíveis na instalação do Git; scripts devem usar Git Bash |
| jq | v1.8.2 instalado pelo WinGet, hash verificado pelo instalador; usado pelos smoke tests herdados |

## Bases locais

READMEs dos quatro projetos lidos; soluções e projetos identificados. `git ls-remote` confirmou os mesmos commits main nas origens e ausência de `fase-2-final`. Users/Catalog/Payments receberam a tag local `fase-2-final` nos commits abaixo e branch `fase-3`; o clone Notifications permaneceu intacto em main. Nos três evoluídos, a origem foi renomeada para `upstream` (leo-bernar) e `origin` aponta para arthuurqueirozz. O usuário confirmou que são projetos de seu grupo e que tem autorização para publicar versões modificadas. Cinco repositórios de destino existem; publicação e verificação dos refs registradas abaixo quando concluídas.

| Projeto | Commit local |
|---|---|
| UsersAPI | `d1de660fccdd265fdc60e29011a337bb6efe7075` |
| CatalogAPI | `ecd30fd46a685fc3b02d9bf72310cf286b30b640` |
| PaymentsAPI | `cd1ca5f8410b55aedca554346e4c1acfa25d3012` |
| NotificationsAPI histórica | `f97a5dd16b706bfcab95328fec2185fab5c83ca2` |

Baseline compilada e testes executados em Release com `dotnet run --project tests/FCG.<Projeto>.Tests/FCG.<Projeto>.Tests.csproj --configuration Release`, usando o runner nativo xUnit v3. Users: 23, Catalog: 19, Payments: 8, Notifications: 3; total 53 testes, todos passaram, sem falhas ou pulados. A restauração dentro do sandbox falhou sem diagnóstico de compilação; a execução autorizada fora dele concluiu os quatro projetos. Estes são os resultados da baseline preservada nas tags; alterações e testes da etapa 4 estão registrados acima.

## Pendências

Autenticação e permissões de deploy resolvidas: STS confirmou `fiap-fase3-cli`; ListAttachedUserPolicies confirmou FCGFase3Deploy e ListUserPolicies retornou lista vazia. GetFreeTierUsage funcionou, inicialmente com registros de uso Glue/KMS; não permite concluir gratuidade de todos os serviços do projeto. Ausência de créditos confirmada; a estimativa não depende de benefícios gratuitos. Histórico da falha OAuth mantido abaixo apenas para explicar a adaptação.

Usuário confirmou autenticação no navegador como root. A documentação atual permite root no `aws login` sem política adicional `SignInLocalDevelopmentAccess`; portanto, não atribuir `TOKEN_EXPIRED` à ausência dessa política ou ao tipo de usuário. Tentativa `--remote` também falhou com `TOKEN_EXPIRED`, conforme saída enviada pelo usuário. Nenhum código de autorização foi reutilizado ou registrado neste arquivo.

Diagnóstico de autenticação (2026-09-13): tentativas normal e `--remote` do usuário com `aws login --profile fiap-fase3` falharam em `CreateOAuth2Token`, código `TOKEN_EXPIRED`. AWS CLI local v2.36.44; na última inspeção o perfil ainda não tinha sido persistido nos arquivos padrão. Foram conferidos apenas nomes de campos, sem exibir tokens ou credenciais. Existe relato do mesmo erro no repositório oficial AWS CLI (#10330), aberto e classificado como bug de API do serviço; isso não comprova a causa desta conta. Não repetir o mesmo login sem nova evidência. Alternativa orientada: usuário IAM dedicado `fiap-fase3-cli`, sem console e inicialmente sem políticas, com chave de acesso configurada pelo próprio usuário somente no perfil local `fiap-fase3`. Justificativa: evitar o fluxo OAuth que falhou nas duas modalidades, sem mudar arquitetura/provedor. Preferência geral continua sendo credenciais temporárias; chave permanente é alternativa para desbloquear este ambiente e deve ser removida quando não for mais necessária. STS GetCallerIdentity não exige política de permissão e permite validar essa configuração antes de preparar permissões de deploy restritas ao projeto. Nenhuma identidade IAM ou chave foi criada por este agente; nenhum cache ou perfil existente foi apagado.

Conta confirmada pelo usuário: conta própria, sob sua responsabilidade. Qualquer região permitida; adotada `us-east-1`, sugestão do plano e não exigência do PDF. Preferência de custo: mínimo possível, visando permanecer nos benefícios do Free Tier. Teto mensal confirmado: USD 1 para o projeto. Alertas não bloqueiam automaticamente cobranças. Uso de Learner Lab não se aplica.

1. Aplicar os limites de sessões e volume de `docs/CUSTOS.md` da orquestração; conferir uso real após o primeiro ensaio frente ao teto de USD 1/mês. Não presumir gratuidade; ausência de créditos já confirmada.
2. Perfil `fiap-fase3` validado com STS; produtores já usam roles restritas com SendMessage. Renovar sessões temporárias pelo script prepare-stage4 antes dos ensaios e recriar containers para carregar os valores.
3. Política de deploy validada na criação real; remover recursos e outros caminhos ainda exigem validação quando executados.
4. Adaptar o preparo das credenciais temporárias para Secrets locais do Kind na etapa integrada; manter arquivos fora do Git.
5. Destino GitHub autorizado: usuário pessoal `arthuurqueirozz`, confirmado pela API autenticada; autorização do grupo para republicação confirmada pelo usuário. Não foi inventada licença para código do grupo.
6. Docker Linux iniciado e recursos conferidos; verificar portas ao preparar a stack integrada. Kind/jq já instalados.
7. Gates cloud das Etapas 2/3 e produtores da Etapa 4 concluídos; avançar para Redis (Etapa 5). Manter integração final, vídeo/relatório e demais entregáveis pendentes.

Os pré-requisitos não exigem criar manualmente filas, tabela ou função: esses recursos serão declarados no SAM na etapa prevista. S3 é suporte ao upload dos artefatos de deploy, não um novo componente de negócio.

## Documentação oficial consultada

- https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/prerequisites.html
- https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html
- https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
- https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html
- https://aws.amazon.com/free/free-tier-faqs/
- https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/tracking-free-tier-usage.html
- https://kind.sigs.k8s.io/docs/user/quick-start/
- https://jqlang.org/download/

Matriz: `MATRIZ-REQUISITOS.md`. Somente linhas com evidência correspondente são marcadas como validadas.

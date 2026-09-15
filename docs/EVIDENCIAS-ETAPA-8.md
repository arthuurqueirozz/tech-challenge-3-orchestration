# Evidências da etapa 8 — integração final

Gate técnico executado em 2026-09-15. PDF original páginas 3–7 reconferido;
SHA256 preservado: `081F70B8508E7E0E6B73C0402825D500ECD4903DFCA66995083544E6FC1D8F32`.
O README central contém os comandos usados para preparar e executar a stack.

## Instalação e recuperação

Cluster novo `fcg-fase3`, kubeconfig isolado `fase3.kubeconfig.local.yaml` e
namespace novo `fcg`. O cluster anterior `fcg-fase3-stage6` foi preservado.
As três imagens foram compiladas e carregadas no Kind; Kubernetes v1.37.0.
Manifests finais derivados dos ensaios e da Fase 2, com Kong/monitoramento
reaproveitados. Nove deployments READY 1/1: Users, Catalog, Payments, SQL Server,
RabbitMQ, Redis, Kong, Prometheus e Grafana. NotificationsAPI antiga ausente.

SQL tem PVC 2 GiB e RabbitMQ PVC 1 GiB, ambos Bound. A implantação usou banco e
namespace vazios, com migrações/semente pelas APIs. A stack AWS já validada nas
etapas anteriores foi reutilizada, sem apagar dados ou repetir sua criação.
O primeiro preparo foi corrigido porque Get-Command confundia a função auxiliar
Aws com o executável aws; o resolvedor agora exige CommandType Application.

Depois de um reinício real do computador, os nove deployments e ambos os PVCs
continuaram disponíveis. Sessões STS expiradas foram renovadas com
`prepare-secrets.ps1 -Apply`; Users/Payments reiniciaram e ficaram disponíveis.
Novas expirações observadas: 2026-09-15 18:35:17/18:35:18 UTC da AWS.
Nenhuma senha persistente foi trocada e nenhum volume foi recriado.

## Testes do ambiente final

**98 verificações passaram:** 71 de gateway, 26 do fluxo integrado e uma de
correlação CloudWatch para os três eventos. Arquivos brutos locais ignorados:
`gateway-evidence.local.json` e `integrated-smoke.local.json`.

- Gateway: 52 chamadas HTTP pelas rotas Kong, JWT válido/ausente/expirado/
  adulterado, nbf/exp ausentes, nbf futuro, issuer inválido, audience inválida ou
  ausente, Admin/User e CRUD. APIs continuam ClusterIP; nenhum acesso direto,
  hostPort/hostNetwork/externalIP. Apenas Kong e monitoramento têm port-forwards.
- Cadastro, login e perfil reais pelo Kong, User correto e outbox marcado enviado.
- Compra de 59,90 aprovada; resultado RabbitMQ adicionou um jogo à biblioteca;
  SQS acionou Lambda e persistiu confirmação no DynamoDB.
- Compra de 150,00 rejeitada; DynamoDB registrou Skipped, sem adicionar jogo à
  biblioteca nem gerar confirmação. Limite do simulador: 100,00.
- Redis: criação de chave em leitura pública, aumento real de keyspace_hits na
  leitura repetida, TTL absoluto até 60 s, invalidação por PUT, leitura do novo
  título, expiração real e recarga. DELETE removeu jogo da listagem pública.
- Prometheus coletou as duas APIs. Falha SQL controlada produziu um 500 em cada
  API via Kong; tabelas foram restauradas e ambas se recuperaram. Contadores 500
  foram coletados. Dashboard Grafana provisionado com seis painéis; as seis
  consultas foram executadas pelo próprio datasource com resultados finitos.
- As duas filas SQS ficaram sem mensagens visíveis/em voo; nenhuma mensagem
  permaneceu em fila de erro RabbitMQ. Gatilhos pausados ao terminar.

O smoke integrado registrou 04:52:22–04:53:38 UTC no relógio do host. O relógio
local estava cerca de 2 min 30 s adiantado em relação à AWS; correlação usa as
chaves de eventos, não igualdade entre timestamps. O coletor recua dez minutos
na janela de logs. Não foram alteradas configurações de relógio do computador.

| Evento | EventKey | Resultado DynamoDB e CloudWatch |
|---|---|---|
| Cadastro | user-created:013638a3-6ce6-4e87-8380-d95b0f0e0450 | Welcome, Simulated, Completed; SimulationRecorded |
| Compra aprovada | payment-processed:8a35799d-33bf-420c-8e70-3736f6b741cd | PurchaseConfirmation, Simulated, Completed; SimulationRecorded |
| Compra rejeitada | payment-processed:99e49ee8-6cbd-4a6c-9f18-aae2e249bcfc | None, Skipped, Completed; SimulationRecorded |

Três logs correlacionados recuperados de `/aws/lambda/fcg-fase3-notifications`.
Os IDs são de dados sintéticos do ensaio, sem tokens ou credenciais.

## Correções e limites

O transporte stdin do terminal acrescentava BOM ao SQL, mesmo após configurar
OutputEncoding. Os dois smokes agora codificam o SQL sintético e o decodificam
dentro do container; a senha continua lida somente do ambiente do SQL.
Uma variável de perfil HTTP colidia com o parâmetro Profile da AWS; foi renomeada.
A pausa em finally funcionou na falha e no sucesso. Os testes finais acima
passaram após essas correções; não foram necessárias mudanças de negócio.

A inspeção visual do Firefox foi bloqueada pela ferramenta de Computer Use
porque sua política de URLs ainda não é suportada nesse navegador. Não houve
screenshot ou confirmação visual automática. Dados, queries e provisionamento
foram validados; a conferência visual e a demonstração no vídeo continuam pendentes.

## Estado de encerramento

Após o reinício, nova consulta confirmou stack UPDATE_COMPLETE,
NotificationsEnabled=false e dois mappings Disabled. O script de encerramento
foi executado; clusters `fcg-fase3` e `fcg-fase3-stage6` em estado exited,
port-forwards encerrados, SQL/Rabbit/PVCs e dados AWS preservados.
Somente sessões STS e o Enabled dos mappings foram alterados na AWS nesta etapa;
não foram criados novos recursos cloud. Armazenamento existente permanece.

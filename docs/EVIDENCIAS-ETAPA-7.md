# Evidências da etapa 7

Gate executado em 2026-09-14 às 23:29 BRT
(2026-09-15 02:29:44–02:29:46 UTC). Páginas 3 e 5 do PDF original reconferidas:
gateway como entrada, JWT, roteamento Users/Catalog e configuração versionada.

## Resultado observado

- `deploy-stage7.ps1` reaplicou o ambiente após reinício real do computador.
  Docker Desktop foi iniciado; cluster, SQL/PVC e arquivos locais preservados.
- Oito deployments com READY 1/1 e AVAILABLE 1: SQL, RabbitMQ, Redis,
  Users, Catalog, Prometheus, Grafana e Kong. Todos os Services ClusterIP;
  nenhum deployment com hostNetwork/hostPort, nenhum Service com externalIPs.
- Kong OSS 3.9.3, imagem efetiva
  `docker.io/library/kong@sha256:ca71c5591eabaf18de96d26b7eed5e2fdb590dac141e467a779c38017e5bdf81`.
- Smoke final encerrou com código zero: 71 verificações e 52 chamadas HTTP,
  todas em `http://127.0.0.1:18000`. Só havia port-forward para o Kong;
  portas diretas 18080/18081 fechadas. Administração/status não expostos pelo Service.
- Login real dos dois papéis, perfil com identidade preservada, biblioteca,
  rotas públicas e CRUD administrativo exercitados. User recebeu 403 para
  POST/PUT/DELETE do catálogo. Admin criou, atualizou e desativou jogo; leituras
  públicas refletiram a atualização e a remoção da lista após invalidação Redis.

## Respostas do smoke final

| Origem da resposta | 200 | 201 | 204 | 400 | 401 | 403 | 404 | Total |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| APIs, via Kong | 10 | 1 | 1 | 4 | 5 | 3 | 1 | 25 |
| Kong, sem encaminhar | 0 | 0 | 0 | 0 | 19 | 0 | 8 | 27 |
| Total | 10 | 1 | 1 | 4 | 24 | 3 | 9 | 52 |

Status e presença/ausência de `X-Kong-Upstream-Latency` conferidos juntos.
JWT ausente bloqueado nas seis combinações protegidas de método/caminho.
Nos endpoints de perfil e biblioteca, ambos passaram pelos oito casos:
expirado, nbf futuro, exp ausente, nbf ausente, issuer desconhecido, audience
incorreta, audience ausente e assinatura adulterada. Expiração, nbf futuro,
exp/nbf ausentes, issuer desconhecido e adulteração retornaram 401 no Kong,
sem upstream; os dois casos de audience retornaram 401 das APIs.
Login com senha incorreta também retornou 401 da UsersAPI.

Configuração existente das duas APIs revisada: ValidateIssuer, ValidateAudience,
ValidateLifetime e ValidateIssuerSigningKey ativos, ClockSkew zero e role claim
preservado. A verificação temporal HTTP ocorreu no gateway; os testes de audience
e papel demonstram autorização/validação adicionais nas APIs. Não houve alteração
de fonte das APIs nem novos builds/testes unitários nesta etapa.

## Correções durante a validação

O Kong recusou inicialmente o prefixo regex `~^/`; ajustado para `~/`, mantendo
a terminação de caminho. A inicialização real validou a configuração renderizada.
O primeiro smoke passou pelos cenários, mas falhou ao serializar a lista de
evidências no Windows PowerShell; substituído `@($checks)` por `ToArray()`.
A execução final acima concluiu também a gravação de evidências.

## Limites e próximos passos

Cadastro foi testado com corpo inválido, sem gerar outbox. O User temporário
foi criado por SQL para emitir JWT real no login e removido no finally.
Compra de jogo inexistente validou a rota protegida sem publicar RabbitMQ.
Jogos de teste foram desativados por DELETE lógico. Tokens/segredos não foram
gravados na evidência nem incluídos no Git; Secrets renderizados são locais.
Nenhuma operação AWS foi executada nesta etapa. Após as verificações, o
port-forward foi encerrado e o nó Kind parou com estado `exited`, preservando
cluster, banco/PVC e configurações locais.

Estes resultados validam o gate da etapa 7. GW-001/GW-002 ainda exigem reconferência
na stack final e no smoke completo da etapa 8. Também continuam pendentes:
Payments/SQS integrados ao Kind, deploy completo do zero pelo README,
inspeção visual do dashboard, revisão final, vídeo e relatório acadêmico.

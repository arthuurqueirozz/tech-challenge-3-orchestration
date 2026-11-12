# Busca da Fase 4 — ambiente local

Esta stack é focada no Catalog e na busca. SQL Server, RabbitMQ, Redis e OpenSearch ficam em uma rede interna; somente o Kong recebe conexões do host, em `127.0.0.1:18084`. Nenhuma conta ou credencial AWS é usada. O OpenSearch local não substitui o serviço gerenciado exigido na entrega cloud.

Pré-requisitos: Docker Desktop com containers Linux, memória disponível para SQL/OpenSearch e os cinco repositórios como pastas irmãs. O Compose compila o Catalog .NET 10; acesso à internet é necessário para baixar imagens e pacotes durante a preparação. A stack não inicia Users/Payments nem o Kind antigo.

## Preparar e iniciar

Na raiz deste repositório:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\prepare-search.ps1
$composeArgs = @('--env-file', 'search.local.env', '-f', 'compose.search.local.yaml')
docker compose @composeArgs up -d --wait --wait-timeout 240 sqlserver rabbitmq redis opensearch
docker compose @composeArgs run --rm --no-deps --build catalog-api --search-bootstrap
docker compose @composeArgs up -d --no-deps catalog-api kong
curl.exe 'http://127.0.0.1:18084/search?q=space'
```

O bootstrap aplica migrations, cria ou confere o mapping e enfileira os jogos existentes, incluindo inativos. Ele termina sem iniciar servidor HTTP, consumidores ou indexador. Depois que a API sobe, o worker processa as pendências; pode haver um pequeno intervalo até a busca refletir cada atualização. Um banco vazio retorna `[]`.

O startup normal da API exige o banco previamente preparado; não aplica migrations. Para preparar somente o schema SQL, sem iniciar dependências da busca, consulte [MIGRATIONS.md](MIGRATIONS.md). A sequência acima já prepara o schema pelo bootstrap e não requer uma chamada adicional a `--migrate`.

O script gera `search.local.env`, `search.catalog.local.env` e `search.kong.local.json`, ignorados pelo Git. Valores existentes são preservados; um conjunto incompleto exige inspeção antes de regenerar. O arquivo de ambiente do Catalog contém a conexão SQL e credenciais locais; o YAML contém referências, sem valores secretos. Não imprima esses arquivos, não versione o JSON renderizado e não use os valores gerados fora desse ambiente local.

Para outro ambiente isolado, use `-Name search-qa -Port 18085`, o arquivo `search-qa.local.env` e `-p fiap-f4-search-qa` em todos os comandos Compose. Cada projeto recebe suas próprias redes e volumes; não reaproveite volumes da Fase 2/Kind.

## Contrato e configuração

- `GET /search?q=termo`: anônimo, até 20 jogos ativos, fuzzy search e ordenação por relevância com desempate estável.
- Termo ausente/vazio/branco: `400`; nenhuma correspondência: `200 []`; motor/índice indisponível ou timeout: `503`.
- O gateway preserva JWT nas escritas do catálogo e não expõe administração ou `/metrics`. A autenticação de usuários da stack completa continua no guia da Fase 3; esta stack focada não inicia esses serviços.
- O worker usa revisões externas no OpenSearch. Repetição/atraso não substitui uma revisão mais nova nem reativa jogo inativo; falhas deixam a pendência disponível para nova tentativa.

| Chave | Configuração local |
|---|---|
| `Search__Endpoint` | `http://opensearch:9200`, somente rede interna |
| `Search__IndexName` | `fcg-games-local` |
| `Search__UseAwsAuth` | `false`, somente `Development` |
| `Search__Region` | `us-east-2`; autenticação AWS desativada localmente |
| `Search__RequestTimeoutSeconds` | 3 |
| `Search__BatchSize` | 20 |
| `Search__PollIntervalSeconds` | 1 |
| `Search__MaxRetryDelaySeconds` | 15 |

As opções completas estão no README do Catalog. OpenSearch não integra a readiness geral da API: sua falha afeta a busca e o processamento de pendências, enquanto operações independentes mantêm seus critérios próprios de saúde. O Compose espera o motor apenas para ordenar o primeiro bootstrap local.

O Kong local limita seu cache DNS a um segundo e não usa registros expirados. Isso permite reencontrar o Catalog caso o Docker atribua outro IP após reinício, sem esperar o TTL longo do DNS da rede. Essa configuração local não altera o cache de consultas do Catalog.

## Bootstrap, reconstrução e encerramento

Antes do primeiro bootstrap e de uma reconstrução, pare todas as instâncias escritoras/workers do Catalog. Não mantenha aplicações antigas, que desconhecem revisão/outbox, gravando no banco. O bootstrap pode ser repetido e produz o mesmo snapshot canônico para a mesma revisão; não apaga índice ou dados automaticamente. Mapping incompatível deve gerar erro, exigindo decisão explícita do operador.

Se um índice for perdido, com escritores/workers controlados, reexecute o bootstrap para criar o mapping e enfileirar o estado SQL atual; então retome a API. Não destrua um índice em uso para resolver configuração.

O motor local usa `action.auto_create_index=false`. Assim, uma escrita após perda de índice falha e conserva a pendência, em vez de recriar um índice com mapping inferido incorreto. Antes de implantar no domínio gerenciado dedicado, aplicar e conferir a mesma configuração do motor; não presumir que ela é padrão da AWS. A criação explícita pelo bootstrap continua permitida. Essa configuração cloud ainda não foi aplicada neste ciclo local.

```powershell
# Encerrar esta stack, preservando seus dados locais:
docker compose @composeArgs down
```

SQL, Rabbit e OpenSearch usam volumes próprios do projeto Compose. Não use limpeza global de volumes. O runner QA pode remover exclusivamente seu projeto descartável e seus dados sintéticos após registrar as evidências. Na AWS, exigir HTTPS/IAM e secrets de runtime; nunca transportar a opção local de desativar o plugin de segurança.

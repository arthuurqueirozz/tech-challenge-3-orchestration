# Revisão técnica — etapa 9

Executada em 2026-09-15, sem declarar concluída a entrega acadêmica.
Referência: páginas 3–7 do PDF original; matriz atualizada por evidência real.

## Verificações

| Projeto | Testes Release | Build | Formatação | Auditoria NuGet |
|---|---:|---|---|---|
| UsersAPI | 29 passaram | Docker/.NET 8 passou | Conforme | Nenhuma vulnerabilidade conhecida retornada |
| CatalogAPI | 30 passaram | Docker/.NET 8 passou | Conforme | Nenhuma vulnerabilidade conhecida retornada |
| PaymentsAPI | 12 passaram | Docker/.NET 8 passou | Conforme | Nenhuma vulnerabilidade conhecida retornada |
| Notifications Function | 18 passaram | SAM build passou | Oito ajustes de espaços/quebras aplicados; verificação passou | Nenhuma vulnerabilidade conhecida retornada |

Total: 89 testes, sem falhas ou pulados. Comando por projeto:
`dotnet run --project tests/<Projeto>.Tests/<Projeto>.Tests.csproj --configuration Release`.
`dotnet format --verify-no-changes --no-restore --verbosity quiet` conferiu as
quatro soluções. Somente espaços/quebras foram alterados em quatro arquivos da
função; contratos, dependências e comportamento não mudaram. O runtime cloud
mantém a versão funcional previamente implantada; não houve redeploy por formatação.

`dotnet list package --vulnerable --include-transitive` consultou NuGet em todas
as soluções. O resultado depende do catálogo vigente e não é garantia universal
de ausência de vulnerabilidades. Não houve atualização de versões de pacotes.
SAM validate --lint e SAM build passaram. PowerShell foi analisado pelo parser;
Kustomize renderizou o overlay final e os manifests foram aplicados no Kind.

No ambiente real: 71 verificações de gateway + 26 integradas + correlação dos
três logs CloudWatch = 98 verificações. Ver [evidências da etapa 8](EVIDENCIAS-ETAPA-8.md).
Os smokes anteriores preservam as provas mais detalhadas de retry/idempotência,
falhas parciais, cache com contagem SQL e métricas com deltas exatos.

Antes da publicação: diff check e varredura de arquivos versionados para valores
dos segredos locais, access keys AWS, chaves privadas e JWTs literais. Arquivos
de configuração sensível, kubeconfig e evidências brutas permanecem ignorados.

## Conferência do enunciado

- Página 3: Kong, JWT e roteamento Users/Catalog demonstrados na stack final.
- Página 4: SQS aciona Lambda real; opção A com Users/Catalog instrumentadas e
  dashboard provisionado. Exigências exclusivas da opção B não se aplicam.
- Página 5: DynamoDB com driver oficial e Redis via IDistributedCache;
  gateway, função e monitoramento versionados nos repositórios responsáveis.
- Página 6: cinco repositórios públicos conferidos, README central com deploy,
  teste e encerramento. Vídeo demonstrativo permanece pendente.
- Páginas 6–7: relatório com grupo, participantes/Discord e links é obrigatório.
  Dados do grupo e URL real do vídeo ainda não foram fornecidos. Preparação em
  [ENTREGA.md](ENTREGA.md), sem gerar automaticamente o PDF/TXT de submissão.

O [roteiro](ROTEIRO-VIDEO.md) prevê 18 minutos. Inspeção visual do Grafana,
gravação/publicação, duração/acesso do vídeo e publicação do relatório ainda
dependem de conclusão e conferência. A etapa 9 não tem seu gate final concluído.

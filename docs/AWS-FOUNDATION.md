# Fundação AWS — Fase 4

A sequência completa atual, incluindo SAM, Pod Identity, bootstrap, SSM, NLB/HTTPS e Actions, está em [CLOUD-OPERACAO.md](CLOUD-OPERACAO.md). Esta fundação é parte dela. Janela autorizada: 13/11/2026 20h até 18/11/2026 20h BRT; nenhum recurso deve ser criado antes. Templates preparados não equivalem a validação cloud concluída.

Esta etapa prepara dois templates, sem implantar aplicações ou ativar pipelines:

| Template | Conteúdo |
|---|---|
| `infra/aws/templates/network-compute.json` | VPC Ohio, duas subnets públicas/AZs distintas, IGW, EKS1.35 com acesso privado e público restrito a um IPv4 /32, administrador IAM explícito, um nó AL2023 m6a.xlarge, raiz40GiB gp3 criptografada/IMDSv2 e três ECRs privados |
| `infra/aws/templates/search.json` | OpenSearch2.19 VPC, uma AZ, t3.small.search, 10GiB gp3, HTTPS/criptografia e porta443 acessível apenas pelo SG do cluster |

Não há NAT, Spot, Auto Mode, SSH ou criação de provedor OIDC. A identidade administrativa é um ARN IAM existente, nunca o ARN STS de uma sessão. O nó recebe as permissões CNI necessárias ao bootstrap; separar as identidades dos componentes é parte da etapa seguinte.

## Conferência somente leitura

Crie uma pasta local de resultados fora do Git. Forneça o ID esperado da conta e o caminho da AWS CLI oficial já instalada:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-aws-foundation.ps1 `
  -ExpectedAccountId $env:FCG_AWS_ACCOUNT_ID -Profile fiap-fase4 `
  -AwsExecutable $env:FCG_AWS_CLI -OutputPath $env:FCG_PREFLIGHT_PATH
```

O script consulta identidade, plano/crédito, role IAM, zonas, tipo/oferta do nó, quota, versão EKS e limites OpenSearch. Uma conta incorreta ou sessão expirada interrompe as verificações. Não faz login, criação, atualização, change set ou exclusão. Os erros são classificados sem registrar a resposta bruta de autenticação.

`GateStatus=read-only-verified` comprova apenas as consultas. **`ReadyToProvision` e `CreationPermissionsVerified` permanecem false.** Ainda é necessário verificar uso da quota, capacidade real, permissões de criação/SCP, janela/cobertura financeira, revisão dos arquivos e a operação concreta a executar.

O serviço vinculado `AWSServiceRoleForAmazonOpenSearchService` deve existir ou poder ser criado automaticamente pelo provisionamento autorizado. Sua ausência é registrada; o template não tenta criar uma role global incondicionalmente. Uma consulta bem-sucedida não comprova `iam:CreateServiceLinkedRole`.

## Parâmetros locais e sequência

O gerador não consulta AWS. Para rede/compute, forneça valores reais previamente verificados:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\new-aws-foundation-parameters.ps1 `
  -Stage network-compute -ExpectedAccountId $env:FCG_AWS_ACCOUNT_ID `
  -AdminRoleArn $env:FCG_ADMIN_ROLE_ARN -AdminCidrIPv4 $env:FCG_OPERATOR_CIDR `
  -AvailabilityZoneA $env:FCG_AZ_A -AvailabilityZoneB $env:FCG_AZ_B `
  -OutputPath $env:FCG_NETWORK_PARAMETERS_PATH
```

O IPv4 /32 precisa ser o endereço público de saída atual do operador, não um IP privado, de documentação ou de outro serviço. O gerador rejeita formatos não canônicos, conta divergente, ARN STS e AZs inválidas/iguais. Ele não comprova propriedade do IP, existência de uma role arbitrária ou permissões dessa role; use a role verificada no preflight.

Após aprovação e criação real de network-compute, obtenha seus outputs com `cloudformation describe-stacks`. A resposta completa, com uma única stack Ohio da conta esperada, alimenta o segundo estágio:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\new-aws-foundation-parameters.ps1 `
  -Stage search -ExpectedAccountId $env:FCG_AWS_ACCOUNT_ID `
  -NetworkOutputsPath $env:FCG_NETWORK_OUTPUTS_PATH `
  -BootstrapRoleArn $env:FCG_BOOTSTRAP_ROLE_ARN -OutputPath $env:FCG_SEARCH_PARAMETERS_PATH
```

Esse estágio confere conta/região, nomes/formato dos IDs e produz os parâmetros de busca. Antes de criar o domínio, confirme também via AWS que subnet/SG pertencem à VPC indicada e que a subnet está na AZA; o gerador offline não verifica essas relações. Não use fixtures de teste como IDs reais. Nenhum dos comandos acima executa CloudFormation.

Os outputs expõem VPC/subnets/AZA, cluster/SG/NodeRole, URIs ECR e ARN/endpoint/SG do domínio. Não são criados valores fictícios para recursos futuros.

## Gates da próxima etapa

- Revisão independente dos templates/scripts, permissões efetivas e estimativa atual aceitas antes de executar qualquer criação.
- GitHub-hosted runners têm IP variável e não acessam o endpoint EKS privado diretamente. A conectividade ainda precisa de uma solução acordada; não ampliar o endpoint para `0.0.0.0/0` como atalho. Os workflows3b ainda não estão ativados.
- Addons Pod Identity/EBS CSI, identidades IAM de aplicações/controladores, PVCs SQL/Rabbit, bootstrap, adaptação SAM, NLB e certificado HTTPS são etapas seguintes. A fundação isolada não serve a aplicação.
- A policy do domínio autoriza somente o bootstrap fornecido. O papel Catalog futuro precisa de policy limitada ao índice; não recebe administração do cluster. Configurar/verificar `action.auto_create_index=false` por operação administrativa privada antes dos writers; essa chave não foi colocada em CFN AdvancedOptions.

### Direção para conectar o runner

A próxima implementação usará um túnel Session Manager pelo nó EC2 já previsto até o endpoint privado do EKS. Um documento SSM exclusivo deve fixar o host do EKS e a porta443; a role de deploy poderá iniciar somente esse documento no nó autorizado, sem shell, host alternativo ou alteração do documento. O kubeconfig apontará à porta local preservando a CA e `tls-server-name` do endpoint EKS. AccessEntry/RBAC próprios continuam obrigatórios; a sessão administrativa não será usada pelo workflow.

Isso exige agente SSM Online, saída HTTPS do nó, plugin no runner, permissões mínimas e teste real de conexão/negações. Não está implementado nos templates atuais e não libera o provisionamento. O Session Manager [não acrescenta cobrança de uso em instâncias EC2](https://aws.amazon.com/systems-manager/pricing/); nó, tráfego e demais componentes continuam sujeitos aos custos já estimados. Referências: [port forwarding remoto](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-sessions-start.html), [documentos Session](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-schema.html), [restrição de documento em IAM](https://docs.aws.amazon.com/systems-manager/latest/userguide/getting-started-specify-session-document.html).

## Retenção e encerramento

ECRs, domínio OpenSearch e seu SG usam retenção contra exclusão/substituição acidental. **Excluir stacks não encerra todos os custos.** O domínio retido mantém ENIs e depende da VPC; não excluir a rede antes de tratar essa dependência.

Na janela de encerramento acordada: exportar/preservar dados e evidências; identificar recursos e custos; executar exclusão explicitamente autorizada do domínio, aguardar remoção de suas ENIs e remover o SG retido; tratar imagens/repositórios retidos; então encerrar nodegroup/EKS/rede. PVCs/snapshots da etapa posterior terão seu próprio tratamento. Não há script de exclusão automática nesta etapa.

Um nó e uma AZ não oferecem alta disponibilidade contra perda do nó/zona. A continuidade de rollout das APIs é uma verificação diferente.

Referências: [serviços da experiência Free](https://docs.aws.amazon.com/accounts/latest/reference/supported-services-sign-up-new.html), [versões EKS](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html), [LaunchTemplate EKS](https://docs.aws.amazon.com/eks/latest/userguide/launch-templates.html), [limites OpenSearch](https://docs.aws.amazon.com/opensearch-service/latest/developerguide/limits.html), [policies do domínio](https://docs.aws.amazon.com/opensearch-service/latest/developerguide/ac.html).

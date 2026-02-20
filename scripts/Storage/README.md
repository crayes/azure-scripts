# Scripts de Azure Storage

Este diretório contém scripts PowerShell para gerenciamento e auditoria de Azure Storage.

## Remove-ExpiredImmutableBlobs.ps1

Avalia e remove blobs com políticas de imutabilidade (WORM) vencidas em Azure Blob Storage.

### Visão Geral

Políticas de imutabilidade são essenciais para compliance (SEC 17a-4, etc.), mas blobs com políticas expiradas podem consumir custos desnecessários. Este script automatiza a identificação e limpeza desses blobs, suportando tanto políticas a nível de container quanto a nível de versão (blob individual).

### Funcionalidades

- **Análise Abrangente**: Varre subscriptions, resource groups ou storage accounts específicas.
- **Dois Tipos de Imutabilidade**: Suporta políticas de contêiner (time-based) e de versão de blob.
- **Legal Hold**: Identifica e reporta blobs sob Legal Hold, que não são removidos automaticamente.
- **Modo Simulação (`-DryRun`)**: Permite visualizar quais blobs seriam removidos sem executar nenhuma ação destrutiva. É o modo padrão.
- **Remoção Segura**: Requer o parâmetro `-RemoveBlobs` e uma confirmação explícita para deletar os blobs.
- **Remoção de Política**: Permite remover apenas a política de imutabilidade com `-RemoveImmutabilityPolicyOnly`, mantendo o blob.
- **Filtro para Grandes Volumes**: Permite executar ações destrutivas somente em contas com volume analisado acima de um limiar (ex: `10TB+`) usando `-MinAccountSizeTB`.
- **Relatórios Detalhados**: Gera um relatório em HTML interativo e um CSV com os resultados da análise.

### Como Usar

1. **Conecte-se ao Azure**:
   ```powershell
   Connect-AzAccount
   ```

2. **Execução em Modo Simulação (Padrão)**:
   Analisa a subscription inteira e lista os blobs elegíveis.
   ```powershell
   .\Remove-ExpiredImmutableBlobs.ps1
   ```

3. **Simulação em um Storage Account Específico**:
   ```powershell
   .\Remove-ExpiredImmutableBlobs.ps1 -StorageAccountName "seu-storage-account"
   ```

4. **Remover Blobs com Imutabilidade Vencida**:
   **Atenção**: Esta ação é destrutiva. O script pedirá uma confirmação manual.
   ```powershell
   .\Remove-ExpiredImmutableBlobs.ps1 -StorageAccountName "seu-storage-account" -RemoveBlobs
   ```

5. **Remover Apenas a Política de Imutabilidade**:
   Mantém o blob, mas remove a trava de imutabilidade expirada.
   ```powershell
   .\Remove-ExpiredImmutableBlobs.ps1 -ContainerName "meu-container" -RemoveImmutabilityPolicyOnly
   ```

6. **Remoção em contas grandes (10TB+)**:
   Executa remoção apenas em Storage Accounts com pelo menos 10 TB analisados.
   ```powershell
   .\Remove-ExpiredImmutableBlobs.ps1 -RemoveBlobs -MinAccountSizeTB 10
   ```

### Parâmetros Principais

| Parâmetro                    | Descrição                                                                      |
|------------------------------|--------------------------------------------------------------------------------|
| `-SubscriptionId`            | ID da subscription a ser analisada.                                            |
| `-ResourceGroupName`         | Nome do Resource Group para filtrar a análise.                                 |
| `-StorageAccountName`        | Nome do Storage Account para filtrar a análise.                                |
| `-ContainerName`             | Nome do container para filtrar a análise.                                      |
| `-DryRun`                    | **(Padrão)** Modo de simulação que não remove nada.                            |
| `-RemoveBlobs`               | Ativa o modo de remoção de blobs. **Requer confirmação explícita.**             |
| `-RemoveImmutabilityPolicyOnly`| Ativa o modo que remove apenas a política, mantendo o blob.                    |
| `-OutputPath`                | Pasta para salvar os relatórios (padrão: `./Reports`).                          |
| `-ExportCsv`                 | Gera um relatório adicional em formato CSV.                                    |
| `-VerboseProgress`           | Ativa modo verbose com progresso detalhado, throughput e ETA em tempo real.   |
| `-MaxDaysExpired`            | Filtra para remover apenas blobs expirados há mais de `N` dias.                |
| `-MinAccountSizeTB`          | Em modo destrutivo, executa ação apenas em contas com volume analisado >= `N` TB. |

### Exemplo de Relatório HTML

O script gera um relatório HTML com um dashboard interativo, resumo das estatísticas e tabelas detalhadas dos blobs encontrados.

![Exemplo de Relatório](https://i.imgur.com/exemplo-relatorio.png) <!--- Placeholder for a real image -->

---

## Changelog

### v1.4.0 (20/02/2026)
- 🐛 **CORREÇÃO CRÍTICA**: Resolvido problema de loop infinito ao usar `-RemoveBlobs`
  - O script agora coleta todos os blobs primeiro, depois executa as ações
  - Evita modificar o container durante a iteração
- 🐛 **CORREÇÃO**: Modo verbose (`-VerboseProgress`) agora funciona corretamente
  - Corrigido escopo de variáveis dentro das funções
  - Todas as mensagens de log e barras de progresso agora aparecem quando o modo está ativo
- ✨ Melhorada barra de progresso com percentual real de conclusão
- 📝 Removida referência a paginação manual que causava problemas

### v1.3.0
- Adicionado suporte a `-MinAccountSizeTB` para filtrar por volume
- Modo verbose aprimorado com throughput e ETA


# Remove-ExpiredImmutableBlobs v2.0.0

Avalia e remove blobs com políticas de imutabilidade (WORM) vencidas em Azure Blob Storage.

## Estrutura

```
storage/
├── Remove-ExpiredImmutableBlobs.ps1   # Script principal
├── README.md
└── lib/
    ├── Helpers.ps1          # Logging, formatação, progresso, conexão Azure
    ├── AzureDiscovery.ps1   # Descoberta de Storage Accounts e containers
    ├── BlobPagination.ps1   # Listagem paginada (lotes de 5000) — CORREÇÃO CRÍTICA
    ├── BlobAnalysis.ps1     # Análise de imutabilidade + ações (delete/policy) — CORREÇÃO CRÍTICA
    └── Reports.ps1          # Geração de relatórios HTML e CSV
```

## Changelog v2.0.0 — Refatoração Completa

### 🔴 Correções Críticas

| Bug | Problema | Correção |
|-----|----------|----------|
| **Paginação** | `ContinuationToken` se perdia ao fazer `@($output)`, script processava só 1 página (5000 blobs) | Token capturado do output RAW antes de transformar em array. Parâmetro só adicionado quando não-null |
| **Deleção** | `Remove-AzStorageBlob` sem `-VersionId` falhava silenciosamente para blobs versionados | `VersionId` propagado no pipeline inteiro: coleta → análise → ação. Passado para `Remove-AzStorageBlob` e `Remove-AzStorageBlobImmutabilityPolicy` |
| **Política Locked** | Script pulava `Remove-AzStorageBlobImmutabilityPolicy` para políticas "Locked" (mesmo expiradas) | Remoção de política para AMBOS modos (Locked e Unlocked) quando expirada, antes de deletar o blob |

### 🟡 Correções Importantes

| Bug | Correção |
|-----|----------|
| `ShouldProcess` aninhado | Removido de `Invoke-BlobAction` — controle centralizado via `$script:DryRun`/`$script:RemoveBlobs` |
| `$script:MaxDaysExpired` | Todos os parâmetros copiados explicitamente para `$script:` scope |
| Modo padrão | Revertido para **DryRun** (v1.4 mudava para RemoveBlobs sem switch) |

### 🟢 Melhorias

- Script modularizado em 5 arquivos para manutenção
- `ErrorDetails` com contexto: `[RemoveBlob(arquivo.vhd)] mensagem de erro`
- Relatório HTML inclui coluna VersionId e bytes removidos
- `PageSize` configurável via parâmetro (100-5000)
- Contador de páginas processadas no resumo e relatório
- `BytesRemoved` rastreado separadamente

## Como Usar

```powershell
# Conectar ao Azure
Connect-AzAccount

# DryRun (padrão) — lista blobs elegíveis sem remover
.\Remove-ExpiredImmutableBlobs.ps1 -StorageAccountName "rfaabackup3"

# DryRun com verbose (para containers grandes)
.\Remove-ExpiredImmutableBlobs.ps1 -StorageAccountName "rfaabackup3" -VerboseProgress

# Remover blobs (pede confirmação)
.\Remove-ExpiredImmutableBlobs.ps1 -StorageAccountName "rfaabackup3" -RemoveBlobs

# Remover apenas políticas (mantém blob)
.\Remove-ExpiredImmutableBlobs.ps1 -StorageAccountName "rfaabackup3" -RemoveImmutabilityPolicyOnly

# Filtrar por dias expirados e gerar CSV
.\Remove-ExpiredImmutableBlobs.ps1 -RemoveBlobs -MaxDaysExpired 30 -ExportCsv

# Threshold: só agir em contas com 10TB+
.\Remove-ExpiredImmutableBlobs.ps1 -RemoveBlobs -MinAccountSizeTB 10

# Page size customizado
.\Remove-ExpiredImmutableBlobs.ps1 -StorageAccountName "rfaabackup3" -PageSize 2000 -VerboseProgress
```

## Parâmetros

| Parâmetro | Descrição | Padrão |
|-----------|-----------|--------|
| `-SubscriptionId` | ID da subscription Azure | Atual |
| `-ResourceGroupName` | Filtrar por Resource Group | Todos |
| `-StorageAccountName` | Filtrar por Storage Account | Todos |
| `-ContainerName` | Filtrar por container | Todos |
| `-DryRun` | Simulação (padrão) | ✅ |
| `-RemoveBlobs` | Remove blobs elegíveis | - |
| `-RemoveImmutabilityPolicyOnly` | Remove só a política | - |
| `-OutputPath` | Pasta dos relatórios | `./Reports` |
| `-ExportCsv` | Gera CSV adicional | - |
| `-IncludeSoftDeleted` | Incluir soft-deleted | - |
| `-VerboseProgress` | Progresso detalhado | - |
| `-MaxDaysExpired` | Filtro mínimo de dias expirados | 0 (todos) |
| `-MinAccountSizeTB` | Threshold de tamanho para ação | 0 (todos) |
| `-PageSize` | Blobs por página (100-5000) | 5000 |

## Fluxo de Execução

```
1. Conexão Azure
2. Descoberta de Storage Accounts e Containers
3. Para cada container:
   a. FASE 1 — Listagem paginada (lotes de PageSize)
      └── Get-BlobsPaginated com ContinuationToken
   b. FASE 2 — Análise blob a blob
      └── Test-BlobImmutabilityExpired (inclui VersionId)
   c. FASE 3 — Ações (se não DryRun)
      └── Invoke-BlobAction:
          1. Remove-AzStorageBlobImmutabilityPolicy (com -VersionId)
          2. Remove-AzStorageBlob (com -VersionId e -Force)
4. Threshold check (MinAccountSizeTB)
5. Relatórios HTML + CSV
```

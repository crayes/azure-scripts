# RemoveExpiredBlobs

Ferramenta .NET para deletar blobs com immutability policies (WORM) expiradas em Azure Blob Storage. Projetada para limpar backups Veeam em storage accounts com versioning e immutability habilitados.

## Por que .NET?

Este projeto começou como um script PowerShell (`Remove-ExpiredImmutableBlobs.ps1`) mas foi migrado para .NET pelos seguintes motivos:

| Aspecto | PowerShell | .NET |
|---|---|---|
| **Listagem 360K blobs** | ~5 min (5K blobs) + memory leak | **3.5 min (360K blobs)** |
| **Memória** | 3-60 GB (leak no SDK wrapper) | **~350 MB estável** |
| **Delete** | 1 blob/request + subprocess workaround | **256 blobs/request** (batch API) |
| **Concorrência** | Subprocesses isolados | **async/await nativo** (50+ simultâneos) |
| **VersionId** | ConvertTo-Json converte para DateTime | **Tipado nativamente** |

## Requisitos

- [.NET 8.0+](https://dotnet.microsoft.com/download) (testado com .NET 10)
- Acesso ao Azure (Account Key ou `az login`)

## Instalação

```bash
cd scripts/Storage/RemoveExpiredBlobs
dotnet restore
dotnet build
```

## Uso

### Dry-Run (auditoria — não deleta nada)

```bash
dotnet run -- -StorageAccountName <account> -ContainerName <container> -AccountKey "<key>"
```

### Deletar blobs expirados

```bash
dotnet run -- -StorageAccountName <account> -ContainerName <container> -AccountKey "<key>" -RemoveBlobs
```

### Apenas remover políticas de imutabilidade

```bash
dotnet run -- -StorageAccountName <account> -AccountKey "<key>" -RemovePolicyOnly
```

### Retomar de checkpoint

```bash
dotnet run -- -StorageAccountName <account> -AccountKey "<key>" -RemoveBlobs -ResumeFrom ./Reports/checkpoint_xxx.json
```

## Parâmetros

| Parâmetro | Descrição | Default |
|---|---|---|
| `-StorageAccountName` | Storage account específica | — |
| `-ResourceGroupName` | Filtrar por resource group | todas |
| `-SubscriptionId` | Azure subscription ID | default |
| `-ContainerName` | Filtrar por container | todos |
| `-BlobPrefix` | Filtrar por prefixo de blob | — |
| `-AccountKey` | Storage account key (bypasses RBAC) | — |
| `-RemoveBlobs` | Deletar blobs expirados | false (dry-run) |
| `-RemovePolicyOnly` | Apenas remover políticas | false |
| `-Force` | Pular confirmação interativa | false |
| `-ExportCsv` | Exportar relatório CSV detalhado | false |
| `-OutputPath` | Diretório de saída | `./Reports` |
| `-Concurrency` | Operações async simultâneas | 50 |
| `-BatchSize` | Blobs por batch delete (max 256) | 256 |
| `-MaxDaysExpired` | Mínimo dias expirado para elegibilidade | 0 (todos) |
| `-MaxErrors` | Parar após N erros | 0 (sem limite) |
| `-ResumeFrom` | Path do checkpoint para retomar | — |

## Funcionalidades

### Streaming Delete
Em vez de escanear todos os blobs e depois deletar, a ferramenta deleta em lotes de 5000 durante o scan. Isso mantém a memória constante independente do número de blobs.

### Batch Delete API
Usa `BlobBatchClient.DeleteBlobsAsync()` que envia até 256 deleções numa única request HTTP. ~100x mais rápido que deleção individual.

### Checkpoint/Resume
Salva progresso automaticamente em `./Reports/checkpoint_*.json`. Se o processo for interrompido, use `-ResumeFrom` para retomar de onde parou.

### Relatório HTML
Gera relatório visual com:
- Cards de resumo (blobs analisados, expirados, removidos, erros)
- Tabela de containers com detalhes
- Lista de erros

### Fallback Automático
Se a batch API falhar (ex: versioned blobs com formato incompatível), faz fallback automático para deleção individual com throttling.

## Autenticação

A ferramenta suporta dois métodos:

1. **Account Key** (recomendado para automação):
   ```bash
   -AccountKey "<sua-key>"
   ```

2. **DefaultAzureCredential** (Azure CLI, Managed Identity, etc.):
   ```bash
   az login --tenant "<tenant-id>"
   # Não precisa passar -AccountKey
   ```

## Arquitetura

```
┌─────────────────────────────────────┐
│         Scan (async stream)         │
│  GetBlobsAsync + ImmutabilityPolicy │
└──────────────┬──────────────────────┘
               │ a cada 5000 blobs
               ▼
┌─────────────────────────────────────┐
│     Remove Policies (async x50)     │
│  DeleteImmutabilityPolicyAsync()    │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│     Batch Delete (256/request)      │
│  BlobBatchClient.DeleteBlobsAsync() │
│  Fallback → Individual delete x50   │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│  Checkpoint + HTML Report + CSV     │
└─────────────────────────────────────┘
```

## Legacy

O script PowerShell original está em `legacy/` para referência. Não é mais mantido.

## Notas Técnicas

- Containers com versioning: `-VersionId` é obrigatório para delete e remove policy
- Blobs Veeam contêm `{chaves}` no path — o SDK lida com escape automaticamente
- Legal Hold: blobs com legal hold são detectados e reportados, mas nunca deletados
- Immutability policies WORM: só blobs com policy expirada são elegíveis

# Azure Blob Storage — Immutability Cleanup

Script PowerShell para identificar e remover blobs com políticas de imutabilidade (WORM) expiradas em Azure Blob Storage.

## Problema

Políticas de imutabilidade são essenciais para compliance (SEC 17a-4, LGPD, etc.), mas blobs com políticas **expiradas** continuam consumindo espaço e custos. Em ambientes de backup (Veeam, Commvault) com version-level WORM, containers podem acumular dezenas de TB de blobs imutáveis vencidos que não podem ser removidos manualmente sem antes remover a política.

Este script automatiza todo o processo: identifica blobs expirados, remove a política de imutabilidade, e deleta o blob — tudo com confirmação explícita e relatórios detalhados.

## Funcionalidades

- **Análise abrangente**: Varre subscriptions, resource groups ou storage accounts específicas
- **Version-level WORM**: Suporta imutabilidade a nível de container e de versão individual
- **Legal Hold**: Identifica e preserva blobs sob Legal Hold (nunca remove)
- **3 modos de operação**:
  - `DryRun` (padrão) — simula sem alterar nada
  - `RemoveBlobs` — remove blob + política (com confirmação)
  - `RemoveImmutabilityPolicyOnly` — remove só a política, mantém o blob
- **Paginação robusta**: Processa em lotes de até 5000 blobs via ContinuationToken
- **Progress inline**: Contador atualizado em tempo real durante análise (sem spam de linhas)
- **Relatório HTML**: Dashboard visual com estatísticas e tabela de blobs
- **Export CSV**: Dados estruturados para análise em Excel
- **Threshold mode**: Executa ações apenas em contas acima de N TB

## Pré-requisitos

```powershell
# PowerShell 7.0+
pwsh --version

# Módulos Azure
Install-Module -Name Az.Accounts -Force
Install-Module -Name Az.Storage -Force

# Conectar
Connect-AzAccount
```

## Uso

### Simulação (modo padrão)

```powershell
# Simular em um storage account específico
.\Remove-ExpiredImmutableBlobs.ps1 -StorageAccountName "meustorage" -DryRun

# Simular em um container específico
.\Remove-ExpiredImmutableBlobs.ps1 -StorageAccountName "meustorage" -ContainerName "backups" -DryRun

# Simular em toda a subscription
.\Remove-ExpiredImmutableBlobs.ps1 -DryRun
```

### Remoção de blobs

```powershell
# Remover blobs com imutabilidade vencida (pede confirmação)
.\Remove-ExpiredImmutableBlobs.ps1 -StorageAccountName "meustorage" -RemoveBlobs

# Remover apenas de contas com 10TB+
.\Remove-ExpiredImmutableBlobs.ps1 -RemoveBlobs -MinAccountSizeTB 10

# Remover apenas blobs expirados há mais de 30 dias
.\Remove-ExpiredImmutableBlobs.ps1 -RemoveBlobs -MaxDaysExpired 30

# Com verbose e export CSV
.\Remove-ExpiredImmutableBlobs.ps1 -RemoveBlobs -VerboseProgress -ExportCsv
```

### Remover apenas a política

```powershell
# Remove a trava de imutabilidade mas mantém o blob
.\Remove-ExpiredImmutableBlobs.ps1 -RemoveImmutabilityPolicyOnly
```

### PageSize para testes

```powershell
# PageSize menor para testes rápidos (mínimo 10)
.\Remove-ExpiredImmutableBlobs.ps1 -RemoveBlobs -PageSize 50 -VerboseProgress
```

## Parâmetros

| Parâmetro | Tipo | Padrão | Descrição |
|-----------|------|--------|-----------|
| `-SubscriptionId` | string | Atual | Subscription Azure |
| `-ResourceGroupName` | string | Todos | Filtro por Resource Group |
| `-StorageAccountName` | string | Todos | Filtro por Storage Account |
| `-ContainerName` | string | Todos | Filtro por container |
| `-DryRun` | switch | ✅ | Simulação — não altera nada |
| `-RemoveBlobs` | switch | | Remove blob + política. Requer confirmação |
| `-RemoveImmutabilityPolicyOnly` | switch | | Remove só a política |
| `-OutputPath` | string | `./Reports` | Pasta dos relatórios |
| `-ExportCsv` | switch | | Gera CSV adicional |
| `-VerboseProgress` | switch | | Logs extras e Write-Progress |
| `-MaxDaysExpired` | int | 0 | Só blobs expirados há N+ dias |
| `-MinAccountSizeTB` | int | 0 | Ação só em contas ≥ N TB |
| `-PageSize` | int | 5000 | Blobs por página (10–5000) |

## Como funciona

### Fluxo por página

```
Pág 1: requisitando 5000 blobs...
Pág 1: 5000 blobs recebidos → mais páginas

    [ANALISANDO] Pág 1: 3847/5000 | Expirados: 3200 | Elegíveis: 3200 | Ativos: 12 | 142.3/s

    Pág 1 analisada em 35.2s: 5000 blobs | Expirados: 4800 | Elegíveis: 4800 (2.31 GB)

    ► INICIANDO REMOÇÃO: 4800 blob(s) | 2.31 GB | Pág 1

    [1/4800] REMOVED: 'backup/archive/file001.vbk' [v:2025-12-21T15:16] (143.89 KB)
    [2/4800] REMOVED: 'backup/archive/file002.vbk' [v:2025-12-21T15:16] (161.58 KB)
    ...

    ✓ Pág 1 remoção concluída: 4800 ações em 2400.5s
```

**Fase 1 (Análise)**: Contador inline atualizado na mesma linha — sem spam de `[EXPIRED]`.

**Transição**: Mensagem clara com contagem e tamanho total.

**Fase 2 (Remoção)**: Cada blob removido logado individualmente com numeração `[N/total]`.

### Processo de remoção (2 passos)

1. **Remove política de imutabilidade** (`Remove-AzStorageBlobImmutabilityPolicy`)
   - Para versões não-current, retorna 404 — tratado silenciosamente
2. **Deleta o blob** (`Remove-AzStorageBlob -VersionId`)
   - Com VersionId para blobs versionados

### Relatório HTML

Gera dashboard em `./Reports/ImmutabilityAudit_<timestamp>.html` com:
- Cards: Accounts, Containers, Blobs analisados, Expirados, Ativos, Legal Hold, Elegíveis, Removidos, Erros
- Tabela de containers com status de política
- Tabela de blobs expirados com ação tomada

## Notas técnicas

- `Get-AzStorageBlob -MaxCount` tem teto de 5000 no SDK Azure
- `Remove-AzStorageBlobImmutabilityPolicy` não aceita `-VersionId` — opera na versão current
- Para versões não-current, o 404 na remoção de política é esperado e tratado
- Blobs já deletados (404 na deleção) são marcados como `AlreadyDeleted` sem erro
- Confirmação case-insensitive (`CONFIRMAR` / `confirmar`)
- Memória liberada página a página para containers grandes (10TB+)

## Permissões necessárias

| Permissão | Motivo |
|-----------|--------|
| `Reader` na subscription | Listar Storage Accounts |
| `Storage Blob Data Contributor` | Ler propriedades de imutabilidade |
| `Storage Blob Data Owner` | Remover políticas e deletar blobs |

> **Nota**: `Storage Blob Data Contributor` pode não ser suficiente para remover políticas de imutabilidade Locked. Use `Storage Blob Data Owner` ou role customizado.

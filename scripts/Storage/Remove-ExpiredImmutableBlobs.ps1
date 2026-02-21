<#
.SYNOPSIS
    Remove blobs com políticas de imutabilidade (WORM) expiradas em Azure Blob Storage.

.DESCRIPTION
    v4.1 — Fix streaming pipeline (memory leak fix)
    Invoke-WithRetry remov do pipeline de listagem para permitir streaming real.

.NOTES
    Versão: 4.1.0 | Requer: Az.Accounts, Az.Storage | PowerShell 7.0+
#>
# Full script pushed via separate commit due to size
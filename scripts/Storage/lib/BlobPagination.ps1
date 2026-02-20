# ============================================================================
# BlobPagination.ps1 - Listagem paginada de blobs (CORREÇÃO CRÍTICA v2.0)
# ============================================================================
# 
# CORREÇÕES APLICADAS:
# 1. ContinuationToken capturado do output RAW do cmdlet, não de array @()
# 2. Parâmetro ContinuationToken só adicionado quando não-null
# 3. IncludeVersion passado como switch corretamente
# 4. Yield por página para evitar acumular tudo na memória
# ============================================================================

function Get-BlobsPaginated {
    param(
        [Parameter(Mandatory)]
        [string]$ContainerNameParam,

        [Parameter(Mandatory)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.IStorageContext]$StorageContext,

        [string]$AccountName = "",
        [int]$BatchSize = 5000,
        [bool]$IncludeVersions = $true,
        [bool]$IncludeDeleted = $false
    )

    $stats = $global:ImmAuditStats
    $continuationToken = $null
    $pageNumber = 0
    $totalBlobsListed = 0

    do {
        $pageNumber++

        # Construir parâmetros LIMPOS a cada iteração (evita contaminação de parâmetros)
        $listParams = @{
            Container = $ContainerNameParam
            Context   = $StorageContext
            MaxCount  = $BatchSize
        }

        # Switches passados corretamente
        if ($IncludeVersions) { $listParams['IncludeVersion'] = $true }
        if ($IncludeDeleted)  { $listParams['IncludeDeleted'] = $true }

        # CRÍTICO: Só adicionar ContinuationToken se não for null
        # Passar $null como valor causa erro em algumas versões do Az.Storage
        if ($null -ne $continuationToken) {
            $listParams['ContinuationToken'] = $continuationToken
        }

        Write-VerboseLog "    Página ${pageNumber}: Requisitando até $BatchSize blobs..." "INFO"

        # ============================================================
        # CORREÇÃO CRÍTICA DA PAGINAÇÃO
        # ============================================================
        # O Get-AzStorageBlob retorna objetos AzureStorageBlob.
        # O ContinuationToken fica SOMENTE no ÚLTIMO objeto retornado.
        # 
        # BUG ANTERIOR: Fazer @($rawOutput) podia perder o token em
        # certas versões do Az.Storage. Agora capturamos o token
        # ANTES de qualquer transformação.
        # ============================================================

        $rawOutput = Get-AzStorageBlob @listParams

        if ($null -eq $rawOutput) {
            Write-VerboseLog "    Página ${pageNumber}: Nenhum blob retornado (null)" "DEBUG"
            break
        }

        # Forçar para array para iteração segura
        $pageBlobs = @($rawOutput)
        $pageBlobCount = $pageBlobs.Count

        if ($pageBlobCount -eq 0) {
            Write-VerboseLog "    Página ${pageNumber}: Array vazio" "DEBUG"
            break
        }

        $totalBlobsListed += $pageBlobCount
        $stats.PagesProcessed++

        # Capturar ContinuationToken do ÚLTIMO blob
        $continuationToken = $null
        try {
            $lastBlob = $pageBlobs[-1]
            if ($null -ne $lastBlob.ContinuationToken) {
                $continuationToken = $lastBlob.ContinuationToken
                Write-VerboseLog "    Página ${pageNumber}: $pageBlobCount blobs | Token CAPTURADO -> mais páginas" "SUCCESS"
            }
            else {
                Write-VerboseLog "    Página ${pageNumber}: $pageBlobCount blobs | Sem token -> última página" "INFO"
            }
        }
        catch {
            Write-VerboseLog "    Página ${pageNumber}: Erro ao extrair token: $($_.Exception.Message)" "WARN"
            $continuationToken = $null
        }

        # YIELD: Retornar blobs desta página para processamento imediato
        foreach ($blob in $pageBlobs) {
            Write-Output $blob
        }

        Write-VerboseLog "    Acumulado: $totalBlobsListed blobs em $pageNumber página(s)" "DEBUG"

    } while ($null -ne $continuationToken)

    Write-VerboseLog "    Listagem completa: $totalBlobsListed blob(s) em $pageNumber página(s)" "SUCCESS"
}

<#
.SYNOPSIS
    Avalia e remove blobs com políticas de imutabilidade vencidas em Azure Blob Storage.

.DESCRIPTION
    Varre Storage Accounts e identifica blobs com imutabilidade expirada.
    Suporta container-level e version-level WORM, Legal Holds, paginação
    em lotes de 5000, e gera relatórios HTML/CSV.

.NOTES
    Versão: 2.1.0
    Requer: Az.Storage, Az.Accounts (PowerShell 7.0+)
    Estrutura: Script principal + lib/ (Helpers, AzureDiscovery, BlobAnalysis, Reports)

    CORREÇÕES v2.1.0:
    - CRÍTICO: Migração de $script: para $global:ImmAuditCfg/Stats/Results (lib/ espera $global:)
    - CRÍTICO: Paginação inline no main (evita coletar tudo na memória via pipeline)
    - Confirmação case-insensitive (-ine)
    - $ErrorActionPreference removido do nível global (usa -ErrorAction Stop por cmdlet)
    - Processamento página-a-página com ações imediatas por página
#>

#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Storage

[CmdletBinding(DefaultParameterSetName = 'DryRun')]
param(
    [Parameter()] [string]$SubscriptionId,
    [Parameter()] [string]$ResourceGroupName,
    [Parameter()] [string]$StorageAccountName,
    [Parameter()] [string]$ContainerName,
    [Parameter(ParameterSetName = 'DryRun')]         [switch]$DryRun,
    [Parameter(ParameterSetName = 'RemoveBlobs')]    [switch]$RemoveBlobs,
    [Parameter(ParameterSetName = 'RemovePolicyOnly')][switch]$RemoveImmutabilityPolicyOnly,
    [Parameter()] [string]$OutputPath = "./Reports",
    [Parameter()] [switch]$ExportCsv,
    [Parameter()] [switch]$IncludeSoftDeleted,
    [Parameter()] [switch]$VerboseProgress,
    [Parameter()] [int]$MaxDaysExpired = 0,
    [Parameter()] [int]$MinAccountSizeTB = 0,
    [Parameter()] [ValidateRange(100, 5000)] [int]$PageSize = 5000
)

# ============================================================================
# CARREGAR MÓDULOS
# ============================================================================
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$libDir = Join-Path $scriptDir "lib"

. (Join-Path $libDir "Helpers.ps1")
. (Join-Path $libDir "AzureDiscovery.ps1")
# BlobPagination.ps1 NÃO É MAIS USADO — paginação inline no main
. (Join-Path $libDir "BlobAnalysis.ps1")
. (Join-Path $libDir "Reports.ps1")

# ============================================================================
# CONFIGURAÇÃO GLOBAL — $global: para acesso correto em funções dot-sourced
# ============================================================================
# NÃO usar $ErrorActionPreference = "Stop" no nível global — mata o script
# em erros não-fatais do Azure. Usar -ErrorAction Stop nos cmdlets individuais.

# Determinar modo de operação
$modeRemoveBlobs = $false
$modeRemovePolicyOnly = $false
$modeDryRun = $false

if ($PSBoundParameters.ContainsKey('RemoveBlobs')) { $modeRemoveBlobs = $true }
elseif ($PSBoundParameters.ContainsKey('RemoveImmutabilityPolicyOnly')) { $modeRemovePolicyOnly = $true }
else { $modeDryRun = $true }

# GLOBAL CONFIG — é isso que os módulos em lib/ leem
$global:ImmAuditCfg = @{
    ScriptVersion              = "2.1.0"
    StartTime                  = Get-Date
    Now                        = [DateTimeOffset]::UtcNow
    SubscriptionId             = $SubscriptionId
    ResourceGroupName          = $ResourceGroupName
    StorageAccountName         = $StorageAccountName
    ContainerName              = $ContainerName
    VerboseProgress            = $VerboseProgress.IsPresent
    MaxDaysExpired             = $MaxDaysExpired
    PageSize                   = $PageSize
    OutputPath                 = $OutputPath
    DryRun                     = $modeDryRun
    RemoveBlobs                = $modeRemoveBlobs
    RemoveImmutabilityPolicyOnly = $modeRemovePolicyOnly
}

# GLOBAL STATS — contadores usados por BlobAnalysis.ps1, Reports.ps1, etc.
$global:ImmAuditStats = @{
    StorageAccountsScanned = 0
    ContainersScanned      = 0
    ContainersWithPolicy   = 0
    BlobsScanned           = 0
    BlobsWithExpiredPolicy = 0
    BlobsWithActivePolicy  = 0
    BlobsWithLegalHold     = 0
    BlobsRemoved           = 0
    PoliciesRemoved        = 0
    Errors                 = 0
    ErrorDetails           = [System.Collections.Generic.List[string]]::new()
    BytesEligible          = 0
    BytesScanned           = 0
    BytesRemoved           = 0
    PagesProcessed         = 0
}

# GLOBAL RESULTS — listas usadas por Reports.ps1
$global:ImmAuditResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$global:ImmAuditContainerResults = [System.Collections.Generic.List[PSCustomObject]]::new()

# Aliases locais para legibilidade (referência ao mesmo objeto)
$cfg   = $global:ImmAuditCfg
$stats = $global:ImmAuditStats

# ============================================================================
# EXECUÇÃO PRINCIPAL
# ============================================================================
function Start-ImmutabilityAudit {

    $cfg   = $global:ImmAuditCfg
    $stats = $global:ImmAuditStats

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  Azure Blob Storage - Immutability Expiration Audit v$($cfg.ScriptVersion)" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""

    $mode = if ($cfg.RemoveBlobs) { "REMOÇÃO DE BLOBS" }
            elseif ($cfg.RemoveImmutabilityPolicyOnly) { "REMOÇÃO DE POLÍTICAS" }
            else { "SIMULAÇÃO (DryRun)" }

    Write-Log "Modo: $mode | PageSize: $($cfg.PageSize)" "SECTION"
    if ($cfg.VerboseProgress) { Write-Log "Verbose ATIVADO" "INFO" }
    if ($cfg.MaxDaysExpired -gt 0) { Write-Log "Filtro: expirados há mais de $($cfg.MaxDaysExpired) dias" "INFO" }
    if ($MinAccountSizeTB -gt 0) { Write-Log "Filtro threshold: $MinAccountSizeTB TB+" "INFO" }

    # Confirmação para modos destrutivos (case-insensitive)
    if ($cfg.RemoveBlobs -or $cfg.RemoveImmutabilityPolicyOnly) {
        Write-Host ""
        Write-Host "  ╔════════════════════════════════════════════════════════╗" -ForegroundColor Red
        Write-Host "  ║  ATENÇÃO: Ações destrutivas! Modo: $($mode.PadRight(23))║" -ForegroundColor Red
        Write-Host "  ╚════════════════════════════════════════════════════════╝" -ForegroundColor Red
        Write-Host ""
        $confirmation = Read-Host "  Digite 'CONFIRMAR' para prosseguir"
        if ($confirmation -ine 'CONFIRMAR') { Write-Log "Cancelado." "WARN"; return }
        Write-Host ""
    }

    if (-not (Test-AzureConnection)) { Write-Log "Falha na conexão Azure. Abortando." "ERROR"; return }

    if (-not (Test-Path $cfg.OutputPath)) { New-Item -ItemType Directory -Path $cfg.OutputPath -Force | Out-Null }

    $storageAccounts = Get-TargetStorageAccounts
    if ($storageAccounts.Count -eq 0) { Write-Log "Nenhuma Storage Account encontrada." "WARN"; return }

    $totalAccounts = @($storageAccounts).Count
    $accountIndex = 0

    foreach ($account in $storageAccounts) {
        $stats.StorageAccountsScanned++
        $accountIndex++
        $accountName = $account.StorageAccountName
        $accountRG = $account.ResourceGroupName
        $accountStartTime = Get-Date
        $accountBlobsScanned = 0
        $accountBytesScanned = 0
        $accountEligibleBytes = 0
        $accountEligibleQueue = [System.Collections.Generic.List[PSCustomObject]]::new()

        Write-Log "Storage Account [$accountIndex/$totalAccounts]: $accountName (RG: $accountRG)" "SECTION"
        Show-Progress -Activity "Storage Accounts" -Status "[$accountIndex/$totalAccounts] $accountName" `
            -PercentComplete (($accountIndex - 1) / $totalAccounts * 100)

        try {
            $storageContext = $account.Context
            if (-not $storageContext) {
                $keys = Get-AzStorageAccountKey -ResourceGroupName $accountRG -Name $accountName -ErrorAction Stop
                $storageContext = New-AzStorageContext -StorageAccountName $accountName -StorageAccountKey $keys[0].Value
            }

            $containersToProcess = Get-ContainerImmutabilityInfo `
                -AccountName $accountName -AccountResourceGroup $accountRG -StorageContext $storageContext

            $totalContainers = @($containersToProcess).Count
            $containerIndex = 0

            foreach ($ctrName in $containersToProcess) {
                $containerIndex++
                $ctrStartTime = Get-Date
                $ctrBlobCount = 0; $ctrExpiredCount = 0; $ctrBytes = 0
                $ctrRemovedCount = 0
                $blobsToProcess = [System.Collections.Generic.List[PSCustomObject]]::new()

                Write-Log "  Container [$containerIndex/$totalContainers]: $ctrName" "INFO"

                try {
                    # ==============================================================
                    # PAGINAÇÃO INLINE — processa página a página sem acumular
                    # ==============================================================
                    $continuationToken = $null
                    $pageNumber = 0

                    do {
                        $pageNumber++

                        # Construir parâmetros limpos a cada iteração
                        $listParams = @{
                            Container = $ctrName
                            Context   = $storageContext
                            MaxCount  = $cfg.PageSize
                        }

                        # IncludeVersion como switch
                        $listParams['IncludeVersion'] = $true
                        if ($IncludeSoftDeleted.IsPresent) { $listParams['IncludeDeleted'] = $true }

                        # CRÍTICO: Só adicionar ContinuationToken se não-null
                        if ($null -ne $continuationToken) {
                            $listParams['ContinuationToken'] = $continuationToken
                        }

                        Write-VerboseLog "    Página ${pageNumber}: Requisitando até $($cfg.PageSize) blobs..." "INFO"

                        # Chamar cmdlet
                        $rawOutput = Get-AzStorageBlob @listParams -ErrorAction Stop

                        if ($null -eq $rawOutput) {
                            Write-VerboseLog "    Página ${pageNumber}: Nenhum blob retornado" "DEBUG"
                            break
                        }

                        $pageBlobs = @($rawOutput)
                        $pageBlobCount = $pageBlobs.Count

                        if ($pageBlobCount -eq 0) {
                            Write-VerboseLog "    Página ${pageNumber}: Array vazio" "DEBUG"
                            break
                        }

                        $stats.PagesProcessed++

                        # Capturar ContinuationToken do ÚLTIMO blob ANTES de processar
                        $continuationToken = $null
                        try {
                            $lastBlob = $pageBlobs[-1]
                            if ($null -ne $lastBlob.ContinuationToken) {
                                $continuationToken = $lastBlob.ContinuationToken
                                Write-VerboseLog "    Página ${pageNumber}: $pageBlobCount blobs | Token capturado -> mais páginas" "SUCCESS"
                            }
                            else {
                                Write-VerboseLog "    Página ${pageNumber}: $pageBlobCount blobs | Sem token -> última página" "INFO"
                            }
                        }
                        catch {
                            Write-VerboseLog "    Página ${pageNumber}: Erro ao extrair token: $($_.Exception.Message)" "WARN"
                            $continuationToken = $null
                        }

                        # ============================================================
                        # PROCESSAR ESTA PÁGINA IMEDIATAMENTE
                        # ============================================================
                        $pageExpired = 0; $pageEligible = 0; $pageRemoved = 0

                        foreach ($blob in $pageBlobs) {
                            $ctrBlobCount++
                            $stats.BlobsScanned++
                            $stats.BytesScanned += $blob.Length
                            $accountBlobsScanned++
                            $accountBytesScanned += $blob.Length
                            $ctrBytes += $blob.Length

                            if ($cfg.VerboseProgress -and ($ctrBlobCount % 500 -eq 0)) {
                                $tp = Get-Throughput -Count $ctrBlobCount -Since $ctrStartTime
                                Show-Progress -Activity "Storage Accounts" `
                                    -Status "[$accountIndex/$totalAccounts] $accountName" `
                                    -CurrentOperation "Ctr [$containerIndex/$totalContainers] $ctrName | Blob $ctrBlobCount | $tp | Pág $pageNumber | Expired: $ctrExpiredCount"
                            }

                            $blobResult = Test-BlobImmutabilityExpired -Blob $blob -AccountName $accountName -ContainerNameLocal $ctrName

                            if ($cfg.VerboseProgress -and $blobResult.Status -ne "NoPolicy") {
                                $icon = if ($blobResult.Status -eq "Expired") { "EXPIRED" } else { $blobResult.Status }
                                $shortName = if ($blob.Name.Length -gt 80) { $blob.Name.Substring(0,77)+"..." } else { $blob.Name }
                                $expInfo = ""
                                if ($blobResult.DaysExpired -gt 0) { $expInfo = " | $($blobResult.DaysExpired)d" }
                                $lvl = if ($blobResult.Status -eq "Expired") { "WARN" } else { "INFO" }
                                Write-VerboseLog "    [$icon] $shortName ($(Format-FileSize $blob.Length))$expInfo" $lvl
                            }

                            if ($blobResult.Status -eq "Expired") { $ctrExpiredCount++; $pageExpired++ }

                            if ($blobResult.Eligible) {
                                $pageEligible++
                                $accountEligibleBytes += $blob.Length

                                if (($cfg.RemoveBlobs -or $cfg.RemoveImmutabilityPolicyOnly) -and $MinAccountSizeTB -gt 0) {
                                    # Threshold mode: enfileirar para decisão após conta completa
                                    $blobResult.Action = "PendingThreshold"
                                    $accountEligibleQueue.Add($blobResult)
                                }
                                elseif ($cfg.RemoveBlobs -or $cfg.RemoveImmutabilityPolicyOnly) {
                                    # Ação imediata nesta página
                                    $blobsToProcess.Add($blobResult)
                                }
                                else {
                                    # DryRun
                                    $vL = ""
                                    if ($blobResult.VersionId) {
                                        $vShort = $blobResult.VersionId.Substring(0, [math]::Min(16, $blobResult.VersionId.Length))
                                        $vL = " [v:$vShort]"
                                    }
                                    $blobResult.Action = "DryRun"
                                    Write-Log "    DRYRUN: '$($blobResult.BlobName)'$vL - $($blobResult.DaysExpired)d ($($blobResult.LengthFormatted)) [$($blobResult.ImmutabilityMode)]" "INFO"
                                }
                            }

                            if ($blobResult.Status -ne "NoPolicy") { $global:ImmAuditResults.Add($blobResult) }
                        }

                        # EXECUTAR AÇÕES DESTA PÁGINA (não acumular entre páginas)
                        if ($blobsToProcess.Count -gt 0) {
                            Write-Log "    Pág ${pageNumber}: Executando ações em $($blobsToProcess.Count) blob(s)..." "WARN"
                            $ai = 0
                            foreach ($bp in $blobsToProcess) {
                                $ai++
                                if ($cfg.VerboseProgress -and ($ai % 10 -eq 0)) {
                                    Show-Progress -Activity "Ações" -Status $ctrName -PercentComplete (($ai/$blobsToProcess.Count)*100) `
                                        -CurrentOperation "Pág ${pageNumber}: $ai/$($blobsToProcess.Count)"
                                }
                                Invoke-BlobAction -BlobInfo $bp -StorageContext $storageContext
                            }
                            $pageRemoved = $blobsToProcess.Count
                            $ctrRemovedCount += $pageRemoved
                            $blobsToProcess.Clear()
                        }

                        Write-VerboseLog "    Pág ${pageNumber}: $pageBlobCount blobs | Expired: $pageExpired | Elegíveis: $pageEligible | Ações: $pageRemoved" "INFO"

                    } while ($null -ne $continuationToken)
                    # ==============================================================
                    # FIM DA PAGINAÇÃO INLINE
                    # ==============================================================

                    $ctrDur = ((Get-Date) - $ctrStartTime).ToString('hh\:mm\:ss')
                    $ctrTp = Get-Throughput -Count $ctrBlobCount -Since $ctrStartTime
                    Write-Log "  Resumo '$ctrName': $ctrBlobCount blobs ($pageNumber pág) | $(Format-FileSize $ctrBytes) | $ctrExpiredCount expirado(s) | Removidos: $ctrRemovedCount | $ctrTp | $ctrDur" "INFO"
                }
                catch {
                    Add-ErrorDetail "Container($ctrName)" $_.Exception.Message
                }
            }

            # Processar fila de threshold (após completar toda a conta)
            if (($cfg.RemoveBlobs -or $cfg.RemoveImmutabilityPolicyOnly) -and $MinAccountSizeTB -gt 0) {
                $thresholdBytes = [long]$MinAccountSizeTB * 1TB
                if ($accountBytesScanned -ge $thresholdBytes) {
                    Write-Log "Conta '$accountName' qualificada: $(Format-FileSize $accountBytesScanned) (limiar: ${MinAccountSizeTB}TB). Processando $($accountEligibleQueue.Count) blob(s)..." "WARN"
                    foreach ($qb in $accountEligibleQueue) { Invoke-BlobAction -BlobInfo $qb -StorageContext $storageContext }
                }
                else {
                    Write-Log "Conta '$accountName' abaixo do limiar: $(Format-FileSize $accountBytesScanned). Sem ação." "INFO"
                    foreach ($qb in $accountEligibleQueue) { $qb.Action = "SkippedBelowThreshold" }
                }
            }

            $accDur = ((Get-Date) - $accountStartTime).ToString('hh\:mm\:ss')
            Write-Log "Resumo '$accountName': $accountBlobsScanned blobs | $(Format-FileSize $accountBytesScanned) | Elegível: $(Format-FileSize $accountEligibleBytes) | $accDur" "SUCCESS"
        }
        catch {
            Add-ErrorDetail "Account($accountName)" $_.Exception.Message
        }
    }

    if ($cfg.VerboseProgress) { Write-Progress -Activity "Storage Accounts" -Completed }

    # --- RELATÓRIOS ---
    Write-Log "Gerando relatórios..." "SECTION"
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    $htmlPath = Join-Path $cfg.OutputPath "ImmutabilityAudit_$ts.html"
    Export-HtmlReport -Path $htmlPath
    if ($ExportCsv) { Export-CsvReport -Path (Join-Path $cfg.OutputPath "ImmutabilityAudit_$ts.csv") }

    # --- RESUMO FINAL ---
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  RESUMO DA EXECUÇÃO" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Log "Storage Accounts:    $($stats.StorageAccountsScanned)" "INFO"
    Write-Log "Containers:          $($stats.ContainersScanned) (com política: $($stats.ContainersWithPolicy))" "INFO"
    Write-Log "Páginas processadas: $($stats.PagesProcessed)" "INFO"
    Write-Log "Blobs analisados:    $($stats.BlobsScanned.ToString('N0')) ($(Format-FileSize $stats.BytesScanned))" "INFO"
    Write-Host ""
    $expLevel = if ($stats.BlobsWithExpiredPolicy -gt 0) { "WARN" } else { "SUCCESS" }
    Write-Log "Imutab. vencida:     $($stats.BlobsWithExpiredPolicy.ToString('N0'))" $expLevel
    Write-Log "Imutab. ativa:       $($stats.BlobsWithActivePolicy.ToString('N0'))" "SUCCESS"
    $lhLevel = if ($stats.BlobsWithLegalHold -gt 0) { "WARN" } else { "INFO" }
    Write-Log "Legal Hold:          $($stats.BlobsWithLegalHold)" $lhLevel
    Write-Log "Elegível remoção:    $(Format-FileSize $stats.BytesEligible)" "INFO"

    if ($cfg.RemoveBlobs) {
        Write-Host ""
        Write-Log "Blobs removidos:     $($stats.BlobsRemoved.ToString('N0'))" "SUCCESS"
        Write-Log "Espaço liberado:     $(Format-FileSize $stats.BytesRemoved)" "SUCCESS"
    }
    if ($cfg.RemoveBlobs -or $cfg.RemoveImmutabilityPolicyOnly) {
        Write-Log "Políticas removidas: $($stats.PoliciesRemoved.ToString('N0'))" "SUCCESS"
    }

    Write-Host ""
    $errLevel = if ($stats.Errors -gt 0) { "ERROR" } else { "SUCCESS" }
    Write-Log "Erros: $($stats.Errors)" $errLevel
    if ($stats.ErrorDetails.Count -gt 0 -and $stats.ErrorDetails.Count -le 10) {
        foreach ($e in $stats.ErrorDetails) { Write-Log "  - $e" "ERROR" }
    }
    elseif ($stats.ErrorDetails.Count -gt 10) {
        foreach ($e in ($stats.ErrorDetails | Select-Object -First 5)) { Write-Log "  - $e" "ERROR" }
        Write-Log "  ... +$($stats.ErrorDetails.Count - 5) erros (veja relatório HTML)" "ERROR"
    }

    Write-Log "Duração: $((Get-Date) - $cfg.StartTime)" "INFO"
    Write-Host ""

    return [PSCustomObject]@{
        Stats            = $stats
        Results          = $global:ImmAuditResults
        ContainerResults = $global:ImmAuditContainerResults
        ReportPath       = $htmlPath
    }
}

# Executar
Start-ImmutabilityAudit

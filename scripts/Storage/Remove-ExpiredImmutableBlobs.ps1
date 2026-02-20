<#
.SYNOPSIS
    Avalia e remove blobs com políticas de imutabilidade vencidas em Azure Blob Storage.

.DESCRIPTION
    Varre Storage Accounts e identifica blobs com imutabilidade expirada.
    Suporta container-level e version-level WORM, Legal Holds, paginação
    em lotes de 5000, e gera relatórios HTML/CSV.

.NOTES
    Versão: 2.0.0
    Requer: Az.Storage, Az.Accounts (PowerShell 7.0+)
    Estrutura: Script principal + lib/ (Helpers, AzureDiscovery, BlobPagination, BlobAnalysis, Reports)
#>

#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Storage

[CmdletBinding(DefaultParameterSetName = 'DryRun')]
param(
    [Parameter()] [string]$SubscriptionId,
    [Parameter()] [string]$ResourceGroupName,
    [Parameter()] [string]$StorageAccountName,
    [Parameter()] [string]$ContainerName,
    [Parameter(ParameterSetName = 'DryRun')]        [switch]$DryRun,
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
. (Join-Path $libDir "BlobPagination.ps1")
. (Join-Path $libDir "BlobAnalysis.ps1")
. (Join-Path $libDir "Reports.ps1")

# ============================================================================
# CONFIGURAÇÃO GLOBAL
# ============================================================================
# Usa $global:ImmAuditCfg (hashtable) para garantir acesso em funções dot-sourced.
# $script: pode falhar em certas condições de scoping entre arquivos.
# ============================================================================
$ErrorActionPreference = "Stop"

$_dryRun = $false
$_removeBlobs = $false
$_removePolicyOnly = $false
if ($PSBoundParameters.ContainsKey('RemoveBlobs')) { $_removeBlobs = $true }
elseif ($PSBoundParameters.ContainsKey('RemoveImmutabilityPolicyOnly')) { $_removePolicyOnly = $true }
else { $_dryRun = $true }

$global:ImmAuditCfg = @{
    ScriptVersion              = "2.0.0"
    StartTime                  = Get-Date
    Now                        = [DateTimeOffset]::UtcNow
    SubscriptionId             = $SubscriptionId
    ResourceGroupName          = $ResourceGroupName
    StorageAccountName         = $StorageAccountName
    ContainerName              = $ContainerName
    # Aceita tanto -VerboseProgress quanto -Verbose (Common Parameter)
    VerboseProgress            = ($VerboseProgress.IsPresent -or $PSBoundParameters.ContainsKey('Verbose'))
    MaxDaysExpired             = $MaxDaysExpired
    PageSize                   = $PageSize
    DryRun                     = $_dryRun
    RemoveBlobs                = $_removeBlobs
    RemoveImmutabilityPolicyOnly = $_removePolicyOnly
}

# Aliases curtos para legibilidade (apontam para o mesmo objeto)
$script:Cfg = $global:ImmAuditCfg

# Contadores e resultados — global para acesso nas libs
$global:ImmAuditStats = @{
    StorageAccountsScanned = 0; ContainersScanned = 0; BlobsScanned = 0
    ContainersWithPolicy = 0; BlobsWithExpiredPolicy = 0; BlobsWithActivePolicy = 0
    BlobsWithLegalHold = 0; BlobsRemoved = 0; PoliciesRemoved = 0
    Errors = 0; ErrorDetails = [System.Collections.Generic.List[string]]::new()
    BytesEligible = 0; BytesScanned = 0; BytesRemoved = 0; PagesProcessed = 0
}

$global:ImmAuditResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$global:ImmAuditContainerResults = [System.Collections.Generic.List[PSCustomObject]]::new()

# ============================================================================
# EXECUÇÃO PRINCIPAL
# ============================================================================
function Start-ImmutabilityAudit {
    $cfg = $global:ImmAuditCfg
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

    # Confirmação para modos destrutivos
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

    if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

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
                $keys = Get-AzStorageAccountKey -ResourceGroupName $accountRG -Name $accountName
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
                $blobsToProcess = [System.Collections.Generic.List[PSCustomObject]]::new()

                Write-Log "  Container [$containerIndex/$totalContainers]: $ctrName" "INFO"

                try {
                    # ============================================================
                    # PROCESSAMENTO PÁGINA A PÁGINA (não acumula antes de agir)
                    # ============================================================
                    $continuationToken = $null
                    $pageNumber = 0

                    do {
                        $pageNumber++
                        $listParams = @{
                            Container = $ctrName
                            Context   = $storageContext
                            MaxCount  = $cfg.PageSize
                            IncludeVersion = $true
                        }
                        if ($IncludeSoftDeleted.IsPresent) { $listParams['IncludeDeleted'] = $true }
                        if ($null -ne $continuationToken) { $listParams['ContinuationToken'] = $continuationToken }

                        Write-Log "    Página ${pageNumber}: Requisitando até $($cfg.PageSize) blobs..." "INFO"
                        $rawOutput = Get-AzStorageBlob @listParams

                        if ($null -eq $rawOutput) { break }
                        $pageBlobs = @($rawOutput)
                        if ($pageBlobs.Count -eq 0) { break }

                        # Capturar token ANTES de processar
                        $continuationToken = $null
                        $lastBlob = $pageBlobs[-1]
                        if ($null -ne $lastBlob.ContinuationToken) {
                            $continuationToken = $lastBlob.ContinuationToken
                        }
                        $stats.PagesProcessed++

                        $pageExpired = 0; $pageEligible = 0

                        # Processar blobs DESTA página imediatamente
                        foreach ($blob in $pageBlobs) {
                            $ctrBlobCount++
                            $stats.BlobsScanned++
                            $stats.BytesScanned += $blob.Length
                            $accountBlobsScanned++
                            $accountBytesScanned += $blob.Length
                            $ctrBytes += $blob.Length

                            $blobResult = Test-BlobImmutabilityExpired -Blob $blob -AccountName $accountName -ContainerNameLocal $ctrName

                            if ($blobResult.Status -eq "Expired") {
                                $ctrExpiredCount++
                                $pageExpired++
                            }

                            if ($blobResult.Eligible) {
                                $pageEligible++
                                $accountEligibleBytes += $blob.Length

                                if (($cfg.RemoveBlobs -or $cfg.RemoveImmutabilityPolicyOnly) -and $MinAccountSizeTB -gt 0) {
                                    $blobResult.Action = "PendingThreshold"
                                    $accountEligibleQueue.Add($blobResult)
                                }
                                elseif ($cfg.RemoveBlobs -or $cfg.RemoveImmutabilityPolicyOnly) {
                                    # EXECUTAR AÇÃO IMEDIATAMENTE (não enfileira)
                                    Invoke-BlobAction -BlobInfo $blobResult -StorageContext $storageContext
                                }
                                else {
                                    $vL = if ($blobResult.VersionId) { " [v:$($blobResult.VersionId.Substring(0,[math]::Min(16,$blobResult.VersionId.Length)))]" } else { "" }
                                    $blobResult.Action = "DryRun"
                                    Write-Log "    DRYRUN: '$($blobResult.BlobName)'$vL - $($blobResult.DaysExpired)d ($($blobResult.LengthFormatted)) [$($blobResult.ImmutabilityMode)]" "INFO"
                                }
                            }

                            if ($blobResult.Status -ne "NoPolicy") { $global:ImmAuditResults.Add($blobResult) }
                        }

                        # Log de resumo da página
                        $tokenStatus = if ($null -ne $continuationToken) { 'mais páginas' } else { 'última página' }
                        Write-Log "    Página ${pageNumber}: $($pageBlobs.Count) blobs | Expired: $pageExpired | Elegíveis: $pageEligible | Removidos: $($stats.BlobsRemoved) | [$tokenStatus]" "SUCCESS"

                    } while ($null -ne $continuationToken)

                    Write-Log "    Listagem completa: $ctrBlobCount blob(s) em $pageNumber página(s)" "INFO"

                    # Nenhum elegível?
                    if ($ctrExpiredCount -eq 0) {
                        Write-VerboseLog "  Nenhum blob elegível neste container" "INFO"
                    }

                    $ctrDur = ((Get-Date) - $ctrStartTime).ToString('hh\:mm\:ss')
                    $ctrTp = Get-Throughput -Count $ctrBlobCount -Since $ctrStartTime
                    Write-Log "  Resumo '$ctrName': $ctrBlobCount blobs | $(Format-FileSize $ctrBytes) | $ctrExpiredCount expirado(s) | $ctrTp | $ctrDur" "INFO"
                }
                catch {
                    Add-ErrorDetail "Container($ctrName)" $_.Exception.Message
                }
            }

            # Processar fila de threshold
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
    $htmlPath = Join-Path $OutputPath "ImmutabilityAudit_$ts.html"
    Export-HtmlReport -Path $htmlPath
    if ($ExportCsv) { Export-CsvReport -Path (Join-Path $OutputPath "ImmutabilityAudit_$ts.csv") }

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
    Write-Log "Imutab. vencida:     $($stats.BlobsWithExpiredPolicy.ToString('N0'))" $(if($stats.BlobsWithExpiredPolicy -gt 0){"WARN"}else{"SUCCESS"})
    Write-Log "Imutab. ativa:       $($stats.BlobsWithActivePolicy.ToString('N0'))" "SUCCESS"
    Write-Log "Legal Hold:          $($stats.BlobsWithLegalHold)" $(if($stats.BlobsWithLegalHold -gt 0){"WARN"}else{"INFO"})
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
    Write-Log "Erros: $($stats.Errors)" $(if($stats.Errors -gt 0){"ERROR"}else{"SUCCESS"})
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
        Stats = $stats; Results = $global:ImmAuditResults
        ContainerResults = $global:ImmAuditContainerResults; ReportPath = $htmlPath
    }
}

# Executar
Start-ImmutabilityAudit

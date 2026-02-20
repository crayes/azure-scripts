<#
.SYNOPSIS
    Remove blobs com políticas de imutabilidade (WORM) expiradas em Azure Blob Storage.

.DESCRIPTION
    Varre Storage Accounts, identifica blobs com imutabilidade expirada, e os remove.
    Processa em lotes de $PageSize blobs (máximo 5000 do Azure SDK) para suportar containers 10TB+.
    Arquivo único — sem dependências externas.

.PARAMETER StorageAccountName
    Nome do Storage Account. Se omitido, varre todos na subscription.

.PARAMETER ContainerName
    Nome do container. Se omitido, varre todos no Storage Account.

.PARAMETER DryRun
    Modo simulação — lista blobs elegíveis sem remover nada. É o padrão.

.PARAMETER RemoveBlobs
    Remove blobs com imutabilidade expirada. Pede confirmação antes de executar.

.PARAMETER RemoveImmutabilityPolicyOnly
    Remove apenas a política de imutabilidade, mantendo o blob.

.EXAMPLE
    .\Remove-ExpiredImmutableBlobs.ps1 -StorageAccountName "storage2025v2" -DryRun
    .\Remove-ExpiredImmutableBlobs.ps1 -StorageAccountName "storage2025v2" -RemoveBlobs
    .\Remove-ExpiredImmutableBlobs.ps1 -RemoveBlobs -MinAccountSizeTB 10

.NOTES
    Versão: 3.1.0 | Requer: Az.Accounts, Az.Storage | PowerShell 7.0+
#>

#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Storage

[CmdletBinding(DefaultParameterSetName = 'DryRun')]
param(
    [string]$SubscriptionId,
    [string]$ResourceGroupName,
    [string]$StorageAccountName,
    [string]$ContainerName,

    [Parameter(ParameterSetName = 'DryRun')]         [switch]$DryRun,
    [Parameter(ParameterSetName = 'RemoveBlobs')]    [switch]$RemoveBlobs,
    [Parameter(ParameterSetName = 'RemovePolicyOnly')][switch]$RemoveImmutabilityPolicyOnly,

    [string]$OutputPath = "./Reports",
    [switch]$ExportCsv,
    [switch]$VerboseProgress,
    [int]$MaxDaysExpired = 0,
    [int]$MinAccountSizeTB = 0,
    [ValidateRange(10, 5000)] [int]$PageSize = 5000
)

# ============================================================================
# CONFIGURAÇÃO
# ============================================================================
$version = "3.1.0"
$now = [DateTimeOffset]::UtcNow
$startTime = Get-Date

# Determinar modo
$modeDryRun = -not $RemoveBlobs.IsPresent -and -not $RemoveImmutabilityPolicyOnly.IsPresent
$modeRemove = $RemoveBlobs.IsPresent
$modePolicyOnly = $RemoveImmutabilityPolicyOnly.IsPresent
$verbose = $VerboseProgress.IsPresent

# Contadores
$stats = @{
    Accounts = 0; Containers = 0; ContainersWithPolicy = 0
    Blobs = 0; Pages = 0
    Expired = 0; Active = 0; LegalHold = 0
    Eligible = 0; Removed = 0; PoliciesRemoved = 0; Errors = 0
    BytesScanned = [long]0; BytesEligible = [long]0; BytesRemoved = [long]0
    ErrorList = [System.Collections.Generic.List[string]]::new()
}

# Resultados para relatório
$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$containerInfo = [System.Collections.Generic.List[PSCustomObject]]::new()

# ============================================================================
# FUNÇÕES AUXILIARES (inline — sem módulos externos)
# ============================================================================
function Log {
    param([string]$Msg, [string]$Level = "INFO")
    $ts = Get-Date -Format "HH:mm:ss"
    $pre = switch ($Level) {
        "INFO"    { "[i]" } "WARN"  { "[!]" } "ERROR" { "[X]" }
        "SUCCESS" { "[+]" } "SECTION" { "[=]" } "DEBUG" { "[D]" }
        default   { "[-]" }
    }
    $color = switch ($Level) {
        "INFO"    { "Cyan" }    "WARN"  { "Yellow" } "ERROR" { "Red" }
        "SUCCESS" { "Green" }   "SECTION" { "Magenta" } "DEBUG" { "DarkGray" }
        default   { "White" }
    }
    Write-Host "$ts $pre $Msg" -ForegroundColor $color
}

function VLog { param([string]$Msg, [string]$Level = "INFO"); if ($verbose) { Log $Msg $Level } }

function FmtSize {
    param([long]$B)
    if ($B -ge 1TB) { return "{0:N2} TB" -f ($B / 1TB) }
    if ($B -ge 1GB) { return "{0:N2} GB" -f ($B / 1GB) }
    if ($B -ge 1MB) { return "{0:N2} MB" -f ($B / 1MB) }
    if ($B -ge 1KB) { return "{0:N2} KB" -f ($B / 1KB) }
    return "$B B"
}

function Throughput { param([int]$N, [datetime]$Since); $s = ((Get-Date)-$Since).TotalSeconds; if($s -gt 0){"$([math]::Round($N/$s,1))/s"}else{"--"} }

function AddError { param([string]$Ctx, [string]$Err); $stats.Errors++; $stats.ErrorList.Add("[$Ctx] $Err"); Log "[$Ctx] $Err" "ERROR" }

# Inline progress — escreve na mesma linha sem pular
function InlineProgress {
    param([string]$Msg, [string]$Color = "Yellow")
    Write-Host "`r$(' ' * 130)`r" -NoNewline
    Write-Host $Msg -ForegroundColor $Color -NoNewline
}

# ============================================================================
# BANNER
# ============================================================================
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "  Azure Blob Storage — Immutability Cleanup v$version" -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host ""

$modeLabel = if ($modeRemove) { "REMOVER BLOBS" } elseif ($modePolicyOnly) { "REMOVER POLÍTICAS" } else { "SIMULAÇÃO (DryRun)" }
Log "Modo: $modeLabel | PageSize: $PageSize" "SECTION"
if ($verbose) { Log "Verbose: ATIVADO" "INFO" }
if ($MaxDaysExpired -gt 0) { Log "Filtro: apenas expirados há >$MaxDaysExpired dias" "INFO" }
if ($MinAccountSizeTB -gt 0) { Log "Threshold: ação apenas em contas >=${MinAccountSizeTB}TB" "INFO" }

# ============================================================================
# CONFIRMAÇÃO (modos destrutivos)
# ============================================================================
if ($modeRemove -or $modePolicyOnly) {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "  ║  ATENÇÃO: MODO DESTRUTIVO — $($modeLabel.PadRight(28))║" -ForegroundColor Red
    Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Red
    Write-Host ""
    $confirm = Read-Host "  Digite 'CONFIRMAR' para prosseguir"
    if ($confirm -ine 'CONFIRMAR') { Log "Cancelado pelo usuário." "WARN"; exit 0 }
    Write-Host ""
}

# ============================================================================
# CONEXÃO AZURE
# ============================================================================
Log "Verificando conexão Azure..." "INFO"
try {
    $ctx = Get-AzContext
    if (-not $ctx) { Log "Não conectado. Iniciando login..." "WARN"; Connect-AzAccount; $ctx = Get-AzContext }
    if ($SubscriptionId) { Set-AzContext -SubscriptionId $SubscriptionId 3>$null | Out-Null; $ctx = Get-AzContext }
    Log "Conectado: $($ctx.Account.Id) | Sub: $($ctx.Subscription.Name)" "SUCCESS"
}
catch { Log "Falha ao conectar: $($_.Exception.Message)" "ERROR"; exit 1 }

# ============================================================================
# DESCOBERTA DE STORAGE ACCOUNTS
# ============================================================================
Log "Buscando Storage Accounts..." "SECTION"
$saParams = @{}
if ($ResourceGroupName) { $saParams['ResourceGroupName'] = $ResourceGroupName }

try {
    $accounts = @(Get-AzStorageAccount @saParams -ErrorAction Stop)
    if ($StorageAccountName) { $accounts = @($accounts | Where-Object StorageAccountName -eq $StorageAccountName) }
    $accounts = @($accounts | Where-Object Kind -in 'StorageV2','BlobStorage','BlockBlobStorage')
    Log "Encontradas $($accounts.Count) Storage Account(s)" "INFO"
    if ($accounts.Count -eq 0) { Log "Nenhuma conta encontrada. Verifique os filtros." "WARN"; exit 0 }
}
catch { Log "Erro ao buscar Storage Accounts: $($_.Exception.Message)" "ERROR"; exit 1 }

# ============================================================================
# PROCESSAMENTO PRINCIPAL
# ============================================================================
$totalAccounts = $accounts.Count
$acctIdx = 0

foreach ($account in $accounts) {
    $acctIdx++
    $acctName = $account.StorageAccountName
    $acctRG   = $account.ResourceGroupName
    $acctStart = Get-Date
    $acctBlobCount = 0
    $acctBytes = [long]0
    $acctEligibleBytes = [long]0
    $thresholdQueue = [System.Collections.Generic.List[PSCustomObject]]::new()

    $stats.Accounts++
    Log "Storage Account [$acctIdx/$totalAccounts]: $acctName (RG: $acctRG)" "SECTION"

    try {
        # Obter contexto de storage
        $storageCtx = $account.Context
        if (-not $storageCtx) {
            $keys = Get-AzStorageAccountKey -ResourceGroupName $acctRG -Name $acctName -ErrorAction Stop
            $storageCtx = New-AzStorageContext -StorageAccountName $acctName -StorageAccountKey $keys[0].Value
        }

        # Listar containers (ARM para obter info de imutabilidade)
        $armContainers = @(Get-AzRmStorageContainer -ResourceGroupName $acctRG -StorageAccountName $acctName -ErrorAction Stop)
        if ($ContainerName) { $armContainers = @($armContainers | Where-Object Name -eq $ContainerName) }

        $totalCtrs = $armContainers.Count
        $ctrIdx = 0

        foreach ($armCtr in $armContainers) {
            $ctrIdx++
            $ctrName = $armCtr.Name
            $stats.Containers++

            # Registrar info do container para relatório
            $cInfo = [PSCustomObject]@{
                Name = $ctrName
                HasPolicy = [bool]$armCtr.HasImmutabilityPolicy
                PolicyState = $null; RetentionDays = $null
                VersionWorm = [bool]$armCtr.ImmutableStorageWithVersioning
                HasLegalHold = [bool]$armCtr.HasLegalHold
                LegalHoldTags = @()
            }

            if ($armCtr.HasImmutabilityPolicy) {
                $stats.ContainersWithPolicy++
                try {
                    $pol = Get-AzRmStorageContainerImmutabilityPolicy -ResourceGroupName $acctRG `
                        -StorageAccountName $acctName -ContainerName $ctrName -ErrorAction Stop
                    $cInfo.PolicyState = $pol.State
                    $cInfo.RetentionDays = $pol.ImmutabilityPeriodSinceCreationInDays
                } catch { VLog "  Erro ao ler política de '$ctrName': $($_.Exception.Message)" "WARN" }
            }

            if ($armCtr.HasLegalHold) {
                $cInfo.LegalHoldTags = @($armCtr.LegalHold.Tags | ForEach-Object { $_.Tag })
            }

            $containerInfo.Add($cInfo)
            Log "  Container [$ctrIdx/$totalCtrs]: $ctrName $(if($cInfo.HasPolicy){"| Política: $($cInfo.PolicyState) ($($cInfo.RetentionDays)d)"}else{'| Sem política'})" "INFO"

            # ==================================================================
            # PAGINAÇÃO — lotes de $PageSize, processamento imediato por página
            # ==================================================================
            $ctrStart = Get-Date
            $ctrBlobs = 0; $ctrExpired = 0; $ctrRemoved = 0; $ctrBytes = [long]0
            $token = $null
            $pageNum = 0

            do {
                $pageNum++

                $listP = @{
                    Container      = $ctrName
                    Context        = $storageCtx
                    MaxCount       = $PageSize
                    IncludeVersion = $true
                }
                if ($null -ne $token) { $listP['ContinuationToken'] = $token }

                Log "    Pág ${pageNum}: requisitando até $PageSize blobs..." "INFO"

                $raw = $null
                try { $raw = Get-AzStorageBlob @listP -ErrorAction Stop }
                catch { AddError "ListBlobs($ctrName/pág$pageNum)" $_.Exception.Message; break }

                if ($null -eq $raw) { VLog "    Pág ${pageNum}: vazio (null)" "DEBUG"; break }

                $blobs = @($raw)
                $blobCount = $blobs.Count
                if ($blobCount -eq 0) { VLog "    Pág ${pageNum}: vazio (0)" "DEBUG"; break }

                $stats.Pages++

                # Capturar ContinuationToken ANTES de processar
                $token = $null
                try { if ($null -ne $blobs[-1].ContinuationToken) { $token = $blobs[-1].ContinuationToken } } catch { $token = $null }

                $hasMore = if ($null -ne $token) { "→ mais páginas" } else { "→ última página" }
                Log "    Pág ${pageNum}: $blobCount blobs recebidos $hasMore" "SUCCESS"

                # ==============================================================
                # FASE 1: ANALISAR blobs desta página
                # ==============================================================
                $pageEligible = [System.Collections.Generic.List[PSCustomObject]]::new()
                $pageExpired = 0; $pageActive = 0; $pageNoPolicy = 0; $pageLH = 0
                $pageBytesEligible = [long]0
                $analyzeStart = Get-Date
                $blobIdx = 0

                foreach ($blob in $blobs) {
                    $blobIdx++
                    $ctrBlobs++; $stats.Blobs++
                    $stats.BytesScanned += $blob.Length
                    $acctBlobCount++; $acctBytes += $blob.Length; $ctrBytes += $blob.Length

                    # Inline progress — uma linha atualizando
                    $progressInterval = if ($PageSize -le 200) { 10 } else { 100 }
                    if ($blobIdx % $progressInterval -eq 0 -or $blobIdx -eq $blobCount) {
                        $tp = Throughput $blobIdx $analyzeStart
                        InlineProgress "    [ANALISANDO] Pág ${pageNum}: $blobIdx/$blobCount | Expirados: $pageExpired | Elegíveis: $($pageEligible.Count) | Ativos: $pageActive | $tp"
                    }

                    # --- Extrair info de imutabilidade ---
                    $versionId = $null; try { $versionId = $blob.VersionId } catch {}
                    $isCurrent = $null; try { $isCurrent = $blob.IsCurrentVersion } catch {}
                    $immPol = $null; try { $immPol = $blob.BlobProperties.ImmutabilityPolicy } catch {}
                    $hasLH = $false; try { $hasLH = [bool]$blob.BlobProperties.HasLegalHold } catch {}

                    $r = [PSCustomObject]@{
                        Account    = $acctName;   Container = $ctrName
                        Blob       = $blob.Name;  VersionId = $versionId; IsCurrent = $isCurrent
                        Size       = $blob.Length; SizeFmt   = FmtSize $blob.Length
                        Tier       = $blob.AccessTier
                        ExpiresOn  = $null; Mode = $null; DaysExp = 0
                        LegalHold  = $hasLH
                        Status     = "NoPolicy"; Eligible = $false; Action = "None"
                    }

                    $days = 0

                    if ($null -ne $immPol -and $null -ne $immPol.ExpiresOn) {
                        $r.ExpiresOn = $immPol.ExpiresOn
                        $r.Mode = $immPol.PolicyMode
                        $expDate = [DateTimeOffset]$immPol.ExpiresOn

                        if ($expDate -lt $now) {
                            $days = [math]::Floor(($now - $expDate).TotalDays)
                            $r.DaysExp = $days
                            $r.Status = "Expired"
                            $ctrExpired++; $stats.Expired++
                            $pageExpired++

                            if ($MaxDaysExpired -gt 0 -and $days -lt $MaxDaysExpired) {
                                $r.Action = "SkippedMinDays"
                            }
                            elseif ($hasLH) {
                                $r.Action = "SkippedLegalHold"
                                $stats.LegalHold++; $pageLH++
                            }
                            else {
                                $r.Eligible = $true
                                $stats.Eligible++
                                $stats.BytesEligible += $blob.Length
                                $acctEligibleBytes += $blob.Length
                                $pageBytesEligible += $blob.Length
                            }
                        }
                        else {
                            $r.Status = "Active"
                            $stats.Active++; $pageActive++
                        }
                    }
                    elseif ($hasLH) {
                        $r.Status = "LegalHold"; $r.LegalHold = $true
                        $stats.LegalHold++; $pageLH++
                    }
                    else { $pageNoPolicy++ }

                    # Coletar elegíveis desta página
                    if ($r.Eligible) {
                        if ($MinAccountSizeTB -gt 0 -and ($modeRemove -or $modePolicyOnly)) {
                            $r.Action = "PendingThreshold"
                            $thresholdQueue.Add($r)
                        }
                        elseif ($modeRemove -or $modePolicyOnly) {
                            $pageEligible.Add($r)
                        }
                        else { $r.Action = "DryRun" }
                    }

                    if ($r.Status -ne "NoPolicy") { $allResults.Add($r) }
                }

                # Limpar linha de progresso inline
                Write-Host "`r$(' ' * 130)`r" -NoNewline
                Write-Host ""

                # Resumo da análise da página
                $analyzeDur = ((Get-Date) - $analyzeStart).TotalSeconds
                Log "    Pág ${pageNum} analisada em $([math]::Round($analyzeDur,1))s: $blobCount blobs | Expirados: $pageExpired | Elegíveis: $($pageEligible.Count) ($(FmtSize $pageBytesEligible)) | Ativos: $pageActive | Sem política: $pageNoPolicy" "INFO"

                # DryRun: listar os elegíveis desta página
                if ($modeDryRun) {
                    $dryItems = @($allResults | Where-Object { $_.Action -eq "DryRun" })
                    if ($dryItems.Count -gt 0) {
                        Log "    DryRun — $($dryItems.Count) blob(s) seriam removidos:" "WARN"
                        foreach ($di in $dryItems) {
                            $vL = if ($di.VersionId) { " [v:$($di.VersionId.Substring(0,[math]::Min(16,$di.VersionId.Length)))]" } else { "" }
                            Log "      '$($di.Blob)'$vL — $($di.DaysExp)d expirado ($($di.SizeFmt)) [$($di.Mode)]" "INFO"
                            $di.Action = "DryRunLogged"
                        }
                    }
                }

                # ==============================================================
                # FASE 2: EXECUTAR AÇÕES desta página
                # ==============================================================
                if ($pageEligible.Count -gt 0) {
                    Write-Host ""
                    Log "    ► INICIANDO REMOÇÃO: $($pageEligible.Count) blob(s) | $(FmtSize $pageBytesEligible) | Pág $pageNum" "WARN"
                    Write-Host ""
                    $actionIdx = 0
                    $actionStart = Get-Date

                    foreach ($item in $pageEligible) {
                        $actionIdx++

                        $vLabel = ""
                        if ($item.VersionId) {
                            $vLabel = " [v:$($item.VersionId.Substring(0,[math]::Min(16,$item.VersionId.Length)))]"
                        }

                        $polP = @{ Container = $item.Container; Blob = $item.Blob; Context = $storageCtx }

                        if ($modePolicyOnly) {
                            try {
                                Remove-AzStorageBlobImmutabilityPolicy @polP -ErrorAction Stop
                                $item.Action = "PolicyRemoved"
                                $stats.PoliciesRemoved++
                                Log "    [$actionIdx/$($pageEligible.Count)] POLICY REMOVED: '$($item.Blob)'$vLabel" "SUCCESS"
                            }
                            catch {
                                $item.Action = "Error: $($_.Exception.Message)"
                                AddError "RemovePolicy($($item.Blob))" $_.Exception.Message
                            }
                        }
                        elseif ($modeRemove) {
                            try {
                                # Passo 1: remover política de imutabilidade expirada
                                if ($item.Mode) {
                                    try {
                                        Remove-AzStorageBlobImmutabilityPolicy @polP -ErrorAction Stop
                                        $stats.PoliciesRemoved++
                                    }
                                    catch {
                                        $e = $_.Exception.Message
                                        if (-not ($e -match 'BlobNotFound|404|does not exist')) {
                                            Log "    [$actionIdx/$($pageEligible.Count)] Aviso política: $e" "WARN"
                                        }
                                    }
                                }

                                # Passo 2: deletar o blob
                                $delP = @{
                                    Container = $item.Container; Blob = $item.Blob
                                    Context = $storageCtx; Force = $true
                                }
                                if ($item.VersionId) { $delP['VersionId'] = $item.VersionId }

                                Remove-AzStorageBlob @delP -ErrorAction Stop

                                $item.Action = "Removed"
                                $stats.Removed++
                                $stats.BytesRemoved += $item.Size
                                $ctrRemoved++
                                Log "    [$actionIdx/$($pageEligible.Count)] REMOVED: '$($item.Blob)'$vLabel ($($item.SizeFmt))" "SUCCESS"
                            }
                            catch {
                                $e = $_.Exception.Message
                                if ($e -match 'BlobNotFound|404|does not exist') {
                                    $item.Action = "AlreadyDeleted"
                                    VLog "    [$actionIdx/$($pageEligible.Count)] Já removido: '$($item.Blob)'$vLabel" "DEBUG"
                                } else {
                                    $item.Action = "Error: $e"
                                    AddError "RemoveBlob($($item.Blob))" $e
                                }
                            }
                        }
                    }

                    $actionDur = ((Get-Date) - $actionStart).TotalSeconds
                    Write-Host ""
                    Log "    ✓ Pág ${pageNum} remoção concluída: $actionIdx ações em $([math]::Round($actionDur,1))s" "SUCCESS"
                }
                else {
                    if (-not $modeDryRun) {
                        VLog "    Pág ${pageNum}: nenhum blob elegível para remoção" "INFO"
                    }
                }

                # Liberar memória da página
                $blobs = $null; $raw = $null; $pageEligible = $null

            } while ($null -ne $token)
            # ============== FIM DA PAGINAÇÃO DO CONTAINER ==============

            $ctrDur = ((Get-Date) - $ctrStart).ToString('hh\:mm\:ss')
            $ctrTp = Throughput $ctrBlobs $ctrStart
            Write-Host ""
            Log "  Resumo '$ctrName': $ctrBlobs blobs ($pageNum pág) | $(FmtSize $ctrBytes) | Expired: $ctrExpired | Removidos: $ctrRemoved | $ctrTp | $ctrDur" "INFO"
            Write-Host ""
        }

        # Processar fila de threshold (após completar toda a conta)
        if ($MinAccountSizeTB -gt 0 -and ($modeRemove -or $modePolicyOnly) -and $thresholdQueue.Count -gt 0) {
            $thresholdBytes = [long]$MinAccountSizeTB * 1TB
            if ($acctBytes -ge $thresholdBytes) {
                Log "Conta '$acctName' qualificada: $(FmtSize $acctBytes) >= ${MinAccountSizeTB}TB. Processando $($thresholdQueue.Count) blob(s)..." "WARN"
                $tIdx = 0
                foreach ($qItem in $thresholdQueue) {
                    $tIdx++
                    $polP = @{ Container = $qItem.Container; Blob = $qItem.Blob; Context = $storageCtx }
                    try {
                        if ($qItem.Mode) {
                            try { Remove-AzStorageBlobImmutabilityPolicy @polP -ErrorAction Stop; $stats.PoliciesRemoved++ }
                            catch { <# ignora BlobNotFound para versões não-current #> }
                        }
                        if ($modeRemove) {
                            $delP = @{ Container = $qItem.Container; Blob = $qItem.Blob; Context = $storageCtx; Force = $true }
                            if ($qItem.VersionId) { $delP['VersionId'] = $qItem.VersionId }
                            Remove-AzStorageBlob @delP -ErrorAction Stop
                            $qItem.Action = "Removed"; $stats.Removed++; $stats.BytesRemoved += $qItem.Size
                            Log "    [$tIdx/$($thresholdQueue.Count)] REMOVED: '$($qItem.Blob)' ($($qItem.SizeFmt))" "SUCCESS"
                        } else {
                            $qItem.Action = "PolicyRemoved"; $stats.PoliciesRemoved++
                            Log "    [$tIdx/$($thresholdQueue.Count)] POLICY REMOVED: '$($qItem.Blob)'" "SUCCESS"
                        }
                    }
                    catch {
                        $e = $_.Exception.Message
                        if ($e -match 'BlobNotFound|404') { $qItem.Action = "AlreadyDeleted" }
                        else { $qItem.Action = "Error: $e"; AddError "Threshold($($qItem.Blob))" $e }
                    }
                }
            }
            else {
                Log "Conta '$acctName' abaixo do limiar: $(FmtSize $acctBytes) < ${MinAccountSizeTB}TB. Sem ação." "INFO"
                foreach ($qItem in $thresholdQueue) { $qItem.Action = "SkippedThreshold" }
            }
        }

        $acctDur = ((Get-Date) - $acctStart).ToString('hh\:mm\:ss')
        Log "Resumo '$acctName': $acctBlobCount blobs | $(FmtSize $acctBytes) | Elegível: $(FmtSize $acctEligibleBytes) | $acctDur" "SUCCESS"
    }
    catch {
        Log "EXCEÇÃO na conta '$acctName': $($_.Exception.Message)" "ERROR"
        Log "StackTrace: $($_.ScriptStackTrace)" "ERROR"
        AddError "Account($acctName)" $_.Exception.Message
    }
}

if ($verbose) { Write-Progress -Activity "Concluído" -Completed }

# ============================================================================
# RELATÓRIO HTML
# ============================================================================
Log "Gerando relatórios..." "SECTION"
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$ts = Get-Date -Format "yyyyMMdd_HHmmss"

$duration = (Get-Date) - $startTime
$modeBadge = if ($modeDryRun) { '<span style="background:#fff3cd;color:#856404;padding:4px 12px;border-radius:12px;font-weight:600">SIMULAÇÃO</span>' }
             else { '<span style="background:#f8d7da;color:#721c24;padding:4px 12px;border-radius:12px;font-weight:600">' + $modeLabel + '</span>' }

$ctrRows = ($containerInfo | ForEach-Object {
    $lh = if ($_.HasLegalHold) { "<span style='color:#f39c12;font-weight:600'>Sim</span>" } else { "Não" }
    $ps = if ($_.PolicyState) { $_.PolicyState } else { "-" }
    $rd = if ($_.RetentionDays) { $_.RetentionDays } else { "-" }
    "<tr><td>$($_.Name)</td><td>$(if($_.HasPolicy){'Sim'}else{'Não'})</td><td>$ps</td><td>$rd</td><td>$(if($_.VersionWorm){'Sim'}else{'Não'})</td><td>$lh</td></tr>"
}) -join "`n"

$expBlobs = $allResults | Where-Object Status -eq "Expired"
$expRows = ($expBlobs | ForEach-Object {
    $short = if ($_.Blob.Length -gt 60) { $_.Blob.Substring(0,57)+'...' } else { $_.Blob }
    $vShort = if ($_.VersionId) { $_.VersionId.Substring(0,[math]::Min(16,$_.VersionId.Length))+'...' } else { '-' }
    $expD = if ($_.ExpiresOn) { ([DateTimeOffset]$_.ExpiresOn).ToString('dd/MM/yyyy HH:mm') } else { '-' }
    $ac = switch -Wildcard ($_.Action) { "DryRun*"{"color:#3498db"} "*Removed*"{"color:#e74c3c"} "Skipped*"{"color:#95a5a6"} "Error*"{"color:#e74c3c;font-weight:600"} default{""} }
    "<tr><td>$($_.Account)</td><td>$($_.Container)</td><td title='$($_.Blob)'>$short</td><td style='font-family:monospace;font-size:11px' title='$($_.VersionId)'>$vShort</td><td>$($_.SizeFmt)</td><td>$expD</td><td style='color:#e74c3c;font-weight:600'>$($_.DaysExp)</td><td>$($_.Mode)</td><td style='$ac'>$($_.Action)</td></tr>"
}) -join "`n"

$expSection = ""
if ($expBlobs.Count -gt 0) {
    $expSection = @"
<div class="section"><h2>Blobs com Imutabilidade Vencida ($($expBlobs.Count))</h2>
<div class="scroll"><table>
<thead><tr><th>Account</th><th>Container</th><th>Blob</th><th>Version</th><th>Tamanho</th><th>Expirou</th><th>Dias</th><th>Modo</th><th>Ação</th></tr></thead>
<tbody>$expRows</tbody></table></div></div>
"@
}

$errSection = ""
if ($stats.ErrorList.Count -gt 0) {
    $errItems = ($stats.ErrorList | ForEach-Object { "<li>$([System.Net.WebUtility]::HtmlEncode($_))</li>" }) -join "`n"
    $errSection = "<div class='section'><h2>Erros ($($stats.Errors))</h2><div style='padding:16px'><ul style='color:#721c24'>$errItems</ul></div></div>"
}

$errCard = if ($stats.Errors -gt 0) { "warning" } else { "" }

$html = @"
<!DOCTYPE html>
<html lang="pt-BR">
<head><meta charset="UTF-8"><title>Immutability Audit v$version</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Segoe UI',sans-serif;background:#f5f5f5;color:#333;padding:20px}
.hdr{background:linear-gradient(135deg,#0078d4,#005a9e);color:#fff;padding:30px;border-radius:8px;margin-bottom:20px}
.hdr h1{font-size:22px;margin-bottom:8px}.hdr p{opacity:.9;font-size:13px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:14px;margin-bottom:20px}
.card{background:#fff;padding:18px;border-radius:8px;box-shadow:0 2px 4px rgba(0,0,0,.1)}
.card .v{font-size:26px;font-weight:700;color:#0078d4}.card .l{font-size:12px;color:#666;margin-top:4px}
.card.warning .v{color:#e74c3c}.card.success .v{color:#27ae60}
.section{background:#fff;border-radius:8px;box-shadow:0 2px 4px rgba(0,0,0,.1);margin-bottom:20px;overflow:hidden}
.section h2{padding:14px 18px;background:#f8f9fa;border-bottom:1px solid #dee2e6;font-size:15px}
table{width:100%;border-collapse:collapse;font-size:12px}
th{background:#e9ecef;padding:8px 10px;text-align:left;font-weight:600;position:sticky;top:0}
td{padding:7px 10px;border-bottom:1px solid #f0f0f0}tr:hover{background:#f8f9fa}
.scroll{max-height:600px;overflow-y:auto}
.ft{text-align:center;padding:16px;color:#999;font-size:11px}
</style></head>
<body>
<div class="hdr">
<h1>Relatório — Immutability Cleanup v$version</h1>
<p>$(Get-Date -Format 'dd/MM/yyyy HH:mm:ss') | Duração: $($duration.ToString('hh\:mm\:ss')) | Páginas: $($stats.Pages) | PageSize: $PageSize</p>
$modeBadge
</div>
<div class="grid">
<div class="card"><div class="v">$($stats.Accounts)</div><div class="l">Storage Accounts</div></div>
<div class="card"><div class="v">$($stats.Containers)</div><div class="l">Containers</div></div>
<div class="card"><div class="v">$($stats.Blobs.ToString('N0'))</div><div class="l">Blobs Analisados</div></div>
<div class="card warning"><div class="v">$($stats.Expired.ToString('N0'))</div><div class="l">Imutab. Vencida</div></div>
<div class="card success"><div class="v">$($stats.Active.ToString('N0'))</div><div class="l">Imutab. Ativa</div></div>
<div class="card"><div class="v">$($stats.LegalHold)</div><div class="l">Legal Hold</div></div>
<div class="card warning"><div class="v">$(FmtSize $stats.BytesEligible)</div><div class="l">Elegível Remoção</div></div>
<div class="card success"><div class="v">$($stats.Removed.ToString('N0'))</div><div class="l">Removidos</div></div>
<div class="card success"><div class="v">$(FmtSize $stats.BytesRemoved)</div><div class="l">Espaço Liberado</div></div>
<div class="card $errCard"><div class="v">$($stats.Errors)</div><div class="l">Erros</div></div>
</div>
<div class="section"><h2>Containers ($($containerInfo.Count))</h2>
<div class="scroll"><table>
<thead><tr><th>Container</th><th>Política</th><th>Estado</th><th>Retenção</th><th>Version WORM</th><th>Legal Hold</th></tr></thead>
<tbody>$ctrRows</tbody></table></div></div>
$expSection
$errSection
<div class="ft">Azure Immutability Cleanup v$version</div>
</body></html>
"@

$htmlPath = Join-Path $OutputPath "ImmutabilityAudit_$ts.html"
$html | Out-File -FilePath $htmlPath -Encoding utf8
Log "Relatório HTML: $htmlPath" "SUCCESS"

if ($ExportCsv) {
    $csvPath = Join-Path $OutputPath "ImmutabilityAudit_$ts.csv"
    $allResults | Where-Object Status -ne "NoPolicy" | Select-Object Account, Container, Blob, VersionId, IsCurrent,
        SizeFmt, Tier, @{N='ExpiresOn';E={if($_.ExpiresOn){([DateTimeOffset]$_.ExpiresOn).ToString('yyyy-MM-dd HH:mm:ss')}else{''}}},
        Mode, LegalHold, Status, DaysExp, Eligible, Action |
        Export-Csv -Path $csvPath -NoTypeInformation -Encoding utf8
    Log "Relatório CSV: $csvPath" "SUCCESS"
}

# ============================================================================
# RESUMO FINAL
# ============================================================================
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "  RESUMO" -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host ""
Log "Accounts: $($stats.Accounts) | Containers: $($stats.Containers) (com política: $($stats.ContainersWithPolicy))" "INFO"
Log "Páginas: $($stats.Pages) | Blobs analisados: $($stats.Blobs.ToString('N0')) ($(FmtSize $stats.BytesScanned))" "INFO"
Write-Host ""
$el = if ($stats.Expired -gt 0) { "WARN" } else { "SUCCESS" }
Log "Expirados: $($stats.Expired.ToString('N0')) | Ativos: $($stats.Active.ToString('N0')) | Legal Hold: $($stats.LegalHold)" $el
Log "Elegível remoção: $($stats.Eligible.ToString('N0')) ($(FmtSize $stats.BytesEligible))" "INFO"

if ($modeRemove) {
    Write-Host ""
    Log "REMOVIDOS: $($stats.Removed.ToString('N0')) | Espaço liberado: $(FmtSize $stats.BytesRemoved)" "SUCCESS"
    Log "Políticas removidas: $($stats.PoliciesRemoved.ToString('N0'))" "SUCCESS"
}
if ($modePolicyOnly) {
    Write-Host ""
    Log "Políticas removidas: $($stats.PoliciesRemoved.ToString('N0'))" "SUCCESS"
}

Write-Host ""
$el2 = if ($stats.Errors -gt 0) { "ERROR" } else { "SUCCESS" }
Log "Erros: $($stats.Errors)" $el2
Log "Duração: $($duration.ToString('hh\:mm\:ss'))" "INFO"
Write-Host ""

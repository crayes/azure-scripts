<#
.SYNOPSIS
    Remove blobs com políticas de imutabilidade (WORM) expiradas em Azure Blob Storage.

.DESCRIPTION
    Varre Storage Accounts, identifica blobs com imutabilidade expirada, e os remove.
    v4.0 — reescrita focada em estabilidade de memória:
      • Pipeline streaming: processa um blob por vez, sem acumular arrays
      • Resultados em disco: CSV temporário, não acumula em RAM
      • Checkpoint/resume: salva progresso por página, retoma de onde parou
      • Deleção paralela: configurable ThrottleLimit com ForEach-Object -Parallel
    Arquivo único — sem dependências externas.

.PARAMETER ResumeFrom
    Caminho do arquivo de checkpoint para retomar execução interrompida.

.PARAMETER ThrottleLimit
    Número de threads paralelas para deleção. Padrão: 1 (sequencial). Recomendado: 4-8.

.PARAMETER MaxErrors
    Máximo de erros antes de abortar. Padrão: 0 (sem limite).

.EXAMPLE
    .\Remove-ExpiredImmutableBlobs.ps1 -StorageAccountName "storage2025v2" -DryRun
    .\Remove-ExpiredImmutableBlobs.ps1 -StorageAccountName "storage2025v2" -RemoveBlobs -ThrottleLimit 8
    .\Remove-ExpiredImmutableBlobs.ps1 -ResumeFrom "./Reports/checkpoint_20260221.json"
    .\Remove-ExpiredImmutableBlobs.ps1 -RemoveBlobs -ExecutionProfile Balanced -Force -Confirm:$false

.NOTES
    Versão: 4.0.0 | Requer: Az.Accounts, Az.Storage | PowerShell 7.0+
#>

#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Storage

[CmdletBinding(DefaultParameterSetName = 'DryRun', SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$SubscriptionId,
    [string]$ResourceGroupName,
    [string]$StorageAccountName,
    [string]$ContainerName,
    [string]$BlobPrefix,

    [Parameter(ParameterSetName = 'DryRun')]          [switch]$DryRun,
    [Parameter(ParameterSetName = 'RemoveBlobs')]     [switch]$RemoveBlobs,
    [Parameter(ParameterSetName = 'RemovePolicyOnly')][switch]$RemoveImmutabilityPolicyOnly,

    [string]$OutputPath = "./Reports",
    [switch]$ExportCsv,
    [switch]$VerboseProgress,
    [switch]$EnableAzCmdletVerbose,
    [switch]$Force,
    [ValidateSet('Manual', 'Conservative', 'Balanced', 'Aggressive')]
    [string]$ExecutionProfile = 'Manual',
    [ValidateRange(1, 10)] [int]$MaxRetryAttempts = 3,
    [ValidateRange(1, 30)] [int]$RetryDelaySeconds = 2,
    [int]$MaxDaysExpired = 0,
    [int]$MinAccountSizeTB = 0,
    [ValidateRange(10, 5000)] [int]$PageSize = 5000,
    [ValidateRange(1, 32)] [int]$ThrottleLimit = 1,
    [int]$MaxErrors = 0,
    [string]$ResumeFrom,
    [switch]$DisableCheckpoint,
    [ValidateRange(10, 10000)] [int]$MaxReportRows = 5000
)

# ============================================================================
# CONFIGURAÇÃO
# ============================================================================
$version = "4.0.0"
$now = [DateTimeOffset]::UtcNow
$startTime = Get-Date

$modeDryRun = -not $RemoveBlobs.IsPresent -and -not $RemoveImmutabilityPolicyOnly.IsPresent
$modeRemove = $RemoveBlobs.IsPresent
$modePolicyOnly = $RemoveImmutabilityPolicyOnly.IsPresent
$verbose = $VerboseProgress.IsPresent

# Perfis operacionais
if ($ExecutionProfile -ne 'Manual') {
    $profileSettings = switch ($ExecutionProfile) {
        'Conservative' { @{ PageSize = 1000; MaxRetryAttempts = 5; RetryDelaySeconds = 3; ThrottleLimit = 2 } }
        'Balanced'     { @{ PageSize = 2500; MaxRetryAttempts = 4; RetryDelaySeconds = 2; ThrottleLimit = 4 } }
        'Aggressive'   { @{ PageSize = 5000; MaxRetryAttempts = 3; RetryDelaySeconds = 1; ThrottleLimit = 8 } }
        default        { $null }
    }
    if ($null -ne $profileSettings) {
        if (-not $PSBoundParameters.ContainsKey('PageSize'))        { $PageSize = $profileSettings.PageSize }
        if (-not $PSBoundParameters.ContainsKey('MaxRetryAttempts')){ $MaxRetryAttempts = $profileSettings.MaxRetryAttempts }
        if (-not $PSBoundParameters.ContainsKey('RetryDelaySeconds')){ $RetryDelaySeconds = $profileSettings.RetryDelaySeconds }
        if (-not $PSBoundParameters.ContainsKey('ThrottleLimit'))   { $ThrottleLimit = $profileSettings.ThrottleLimit }
    }
}

# Contadores
$stats = @{
    Accounts = 0; Containers = 0; ContainersWithPolicy = 0
    Blobs = 0; Pages = 0
    Expired = 0; Active = 0; LegalHold = 0
    Eligible = 0; Removed = 0; PoliciesRemoved = 0; Errors = 0; ConsecutiveErrors = 0
    BytesScanned = [long]0; BytesEligible = [long]0; BytesRemoved = [long]0
    ErrorList = [System.Collections.Generic.List[string]]::new()
}

# Container info para relatório (lightweight — um registro por container, não por blob)
$containerInfo = [System.Collections.Generic.List[PSCustomObject]]::new()

# Arquivo temporário para resultados detalhados (DISCO, não memória)
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$tempCsvPath = Join-Path $OutputPath ".temp_results_$ts.csv"
$reportRowsWritten = 0

# Inicializar CSV temporário com headers
"Account,Container,Blob,VersionId,IsCurrent,Size,SizeFmt,Tier,ExpiresOn,Mode,LegalHold,Status,DaysExp,Eligible,Action" |
    Out-File -FilePath $tempCsvPath -Encoding utf8

# Checkpoint
$checkpointPath = Join-Path $OutputPath "checkpoint_$ts.json"
$resumeState = $null

# ============================================================================
# FUNÇÕES AUXILIARES
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

function AddError {
    param([string]$Ctx, [string]$Err)
    $stats.Errors++
    $stats.ConsecutiveErrors++
    if ($stats.ErrorList.Count -lt 200) { $stats.ErrorList.Add("[$Ctx] $Err") }
    Log "[$Ctx] $Err" "ERROR"
}

function ResetConsecutiveErrors { $stats.ConsecutiveErrors = 0 }

function Test-MaxErrorsReached {
    if ($MaxErrors -gt 0 -and $stats.Errors -ge $MaxErrors) {
        Log "ABORTANDO: limite de $MaxErrors erros atingido." "ERROR"
        return $true
    }
    return $false
}

function InlineProgress {
    param([string]$Msg, [string]$Color = "Yellow")
    Write-Host "`r$(' ' * 140)`r" -NoNewline
    Write-Host $Msg -ForegroundColor $Color -NoNewline
}

function Test-BlobNotFoundError {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }
    return ($Message -match '(?i)\bBlobNotFound\b' -or $Message -match '(?i)\bStatus:\s*404\b' -or $Message -match '(?i)\bThe specified blob does not exist\b')
}

function Test-TransientAzError {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }
    if (Test-BlobNotFoundError -Message $Message) { return $false }
    $patterns = @('(?i)\bStatus:\s*429\b','(?i)\bStatus:\s*5\d{2}\b','(?i)\bTooManyRequests\b','(?i)\bServerBusy\b','(?i)\bOperationTimedOut\b','(?i)\btimed?\s*out\b','(?i)\btemporar','(?i)\bInternalServerError\b','(?i)\bServiceUnavailable\b','(?i)\bBadGateway\b','(?i)\bGatewayTimeout\b')
    foreach ($p in $patterns) { if ($Message -match $p) { return $true } }
    return $false
}

function Invoke-WithRetry {
    param([scriptblock]$Operation, [string]$Context, [int]$Attempts = 3, [int]$BaseDelaySeconds = 2)
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try { return & $Operation }
        catch {
            $msg = $_.Exception.Message
            if ($attempt -ge $Attempts -or -not (Test-TransientAzError -Message $msg)) { throw }
            $delay = [math]::Min(30, [math]::Max(1, ($BaseDelaySeconds * [math]::Pow(2, $attempt - 1))))
            Log "[$Context] falha transitória ($attempt/$Attempts): $msg | retry em ${delay}s" "WARN"
            Start-Sleep -Seconds $delay
        }
    }
}

# Escrever uma linha no CSV temporário em disco (não acumula em memória)
function Write-ResultToDisk {
    param([hashtable]$R)
    if ($script:reportRowsWritten -ge $MaxReportRows) { return }
    $expOn = if ($R.ExpiresOn) { ([DateTimeOffset]$R.ExpiresOn).ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
    $line = '"{0}","{1}","{2}","{3}","{4}",{5},"{6}","{7}","{8}","{9}",{10},"{11}",{12},{13},"{14}"' -f `
        $R.Account, $R.Container, ($R.Blob -replace '"','""'), $R.VersionId, $R.IsCurrent,
        $R.Size, (FmtSize $R.Size), $R.Tier, $expOn, $R.Mode, $R.HasLegalHold,
        $R.Status, $R.DaysExp, $R.Eligible, $R.Action
    $line | Out-File -FilePath $tempCsvPath -Encoding utf8 -Append
    $script:reportRowsWritten++
}

# Checkpoint: salvar estado para resume
function Save-Checkpoint {
    param(
        [string]$AccountName, [string]$Container,
        [int]$PageNum, $Token, [hashtable]$Stats,
        [string]$Phase  # 'scanning' or 'complete'
    )
    if ($DisableCheckpoint.IsPresent) { return }
    $cp = @{
        Version        = $version
        Timestamp      = (Get-Date -Format 'o')
        Phase          = $Phase
        AccountName    = $AccountName
        ContainerName  = $Container
        PageNum        = $PageNum
        HasToken       = ($null -ne $Token)
        Stats          = @{
            Accounts = $Stats.Accounts; Containers = $Stats.Containers
            Blobs = $Stats.Blobs; Pages = $Stats.Pages
            Expired = $Stats.Expired; Active = $Stats.Active; LegalHold = $Stats.LegalHold
            Eligible = $Stats.Eligible; Removed = $Stats.Removed; PoliciesRemoved = $Stats.PoliciesRemoved
            Errors = $Stats.Errors
            BytesScanned = $Stats.BytesScanned; BytesEligible = $Stats.BytesEligible; BytesRemoved = $Stats.BytesRemoved
        }
        Parameters     = @{
            SubscriptionId     = $SubscriptionId
            ResourceGroupName  = $ResourceGroupName
            StorageAccountName = $StorageAccountName
            ContainerName      = $ContainerName
            PageSize           = $PageSize
            MaxDaysExpired     = $MaxDaysExpired
            MinAccountSizeTB   = $MinAccountSizeTB
            BlobPrefix         = $BlobPrefix
        }
    }
    $cp | ConvertTo-Json -Depth 5 | Out-File -FilePath $checkpointPath -Encoding utf8 -Force
}

function Load-Checkpoint {
    param([string]$Path)
    if (-not (Test-Path $Path)) { Log "Checkpoint não encontrado: $Path" "ERROR"; exit 1 }
    $cp = Get-Content $Path -Raw | ConvertFrom-Json
    Log "Checkpoint carregado: conta='$($cp.AccountName)' container='$($cp.ContainerName)' página=$($cp.PageNum) blobs=$($cp.Stats.Blobs)" "SUCCESS"
    return $cp
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
Log "Modo: $modeLabel | PageSize: $PageSize | Threads: $ThrottleLimit" "SECTION"
Log "Perfil: $ExecutionProfile | Retry: ${MaxRetryAttempts}x, delay base ${RetryDelaySeconds}s" "INFO"
if ($ThrottleLimit -gt 1) { Log "Deleção PARALELA: $ThrottleLimit threads" "INFO" }
if ($MaxErrors -gt 0)     { Log "Abort após $MaxErrors erros" "INFO" }
if ($BlobPrefix)           { Log "Prefixo: '$BlobPrefix'" "INFO" }
if ($MaxDaysExpired -gt 0) { Log "Filtro: expirados há >$MaxDaysExpired dias" "INFO" }
if ($MinAccountSizeTB -gt 0) { Log "Threshold: contas >=${MinAccountSizeTB}TB" "INFO" }
if ($verbose) { Log "Verbose: ATIVADO" "INFO" }

Log "Resultados em disco: $tempCsvPath (max $MaxReportRows linhas)" "INFO"
if (-not $DisableCheckpoint.IsPresent) { Log "Checkpoint: $checkpointPath" "INFO" }

# Carregar checkpoint de resume se fornecido
if ($ResumeFrom) {
    $resumeState = Load-Checkpoint -Path $ResumeFrom
    $stats.Accounts        = $resumeState.Stats.Accounts
    $stats.Containers      = $resumeState.Stats.Containers
    $stats.Blobs           = $resumeState.Stats.Blobs
    $stats.Pages           = $resumeState.Stats.Pages
    $stats.Expired         = $resumeState.Stats.Expired
    $stats.Active          = $resumeState.Stats.Active
    $stats.LegalHold       = $resumeState.Stats.LegalHold
    $stats.Eligible        = $resumeState.Stats.Eligible
    $stats.Removed         = $resumeState.Stats.Removed
    $stats.PoliciesRemoved = $resumeState.Stats.PoliciesRemoved
    $stats.Errors          = $resumeState.Stats.Errors
    $stats.BytesScanned    = $resumeState.Stats.BytesScanned
    $stats.BytesEligible   = $resumeState.Stats.BytesEligible
    $stats.BytesRemoved    = $resumeState.Stats.BytesRemoved
    Log "Stats restaurados: $($stats.Blobs) blobs, $($stats.Removed) removidos, $($stats.Errors) erros" "INFO"
}

# ============================================================================
# CONFIRMAÇÃO
# ============================================================================
if (($modeRemove -or $modePolicyOnly) -and -not $ResumeFrom) {
    if (-not $Force) {
        $canPrompt = $true
        try { $null = $Host.UI.RawUI } catch { $canPrompt = $false }
        if (-not $canPrompt) { Log "Sessão não-interativa. Use -Force." "ERROR"; exit 1 }
        Write-Host ""
        Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Red
        Write-Host "  ║  ATENÇÃO: MODO DESTRUTIVO — $($modeLabel.PadRight(28)) ║" -ForegroundColor Red
        Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Red
        Write-Host ""
        $confirm = Read-Host "  Digite 'CONFIRMAR' para prosseguir"
        if ($confirm -ine 'CONFIRMAR') { Log "Cancelado." "WARN"; exit 0 }
        Write-Host ""
    } else {
        Log "Flag -Force: pulando confirmação." "WARN"
    }
}

# ============================================================================
# CONEXÃO AZURE
# ============================================================================
Log "Verificando conexão Azure..." "INFO"
try {
    $ctx = Get-AzContext
    if (-not $ctx) {
        Log "Não conectado. Iniciando login..." "WARN"
        try { Connect-AzAccount -ErrorAction Stop | Out-Null }
        catch { Connect-AzAccount -UseDeviceAuthentication -ErrorAction Stop | Out-Null }
        $ctx = Get-AzContext
    }
    if ($SubscriptionId) {
        Set-AzContext -SubscriptionId $SubscriptionId -Scope Process -ErrorAction Stop 3>$null | Out-Null
        $ctx = Get-AzContext
    }
    Log "Conectado: $($ctx.Account.Id) | Sub: $($ctx.Subscription.Name)" "SUCCESS"
}
catch { Log "Falha ao conectar: $($_.Exception.Message)" "ERROR"; exit 1 }

# ============================================================================
# DESCOBERTA
# ============================================================================
Log "Buscando Storage Accounts..." "SECTION"
$saParams = @{}
if ($ResourceGroupName) { $saParams['ResourceGroupName'] = $ResourceGroupName }
try {
    $accounts = @(Get-AzStorageAccount @saParams -ErrorAction Stop)
    if ($StorageAccountName) { $accounts = @($accounts | Where-Object StorageAccountName -eq $StorageAccountName) }
    $accounts = @($accounts | Where-Object Kind -in 'StorageV2','BlobStorage','BlockBlobStorage')
    Log "Encontradas $($accounts.Count) Storage Account(s)" "INFO"
    if ($accounts.Count -eq 0) { Log "Nenhuma conta encontrada." "WARN"; exit 0 }
}
catch { Log "Erro: $($_.Exception.Message)" "ERROR"; exit 1 }

# ============================================================================
# PROCESSAMENTO PRINCIPAL
# ============================================================================
$totalAccounts = $accounts.Count
$acctIdx = 0

:accountLoop foreach ($account in $accounts) {
    $acctIdx++
    $acctName = $account.StorageAccountName
    $acctRG   = $account.ResourceGroupName
    $acctStart = Get-Date
    $acctBlobCount = 0
    $acctBytes = [long]0
    $acctEligibleBytes = [long]0
    $thresholdQueue = [System.Collections.Generic.List[hashtable]]::new()

    # Resume: pular contas já processadas
    if ($resumeState -and $resumeState.Phase -ne 'complete') {
        if ($acctName -ne $resumeState.AccountName) {
            VLog "Resume: pulando conta '$acctName' (já processada)" "DEBUG"
            continue
        }
    }

    $stats.Accounts++
    Log "Storage Account [$acctIdx/$totalAccounts]: $acctName (RG: $acctRG)" "SECTION"

    try {
        $storageCtx = $account.Context
        $storageKey = $null

        if (-not $storageCtx) {
            $keys = Get-AzStorageAccountKey -ResourceGroupName $acctRG -Name $acctName -ErrorAction Stop
            $storageKey = $keys[0].Value
            $storageCtx = New-AzStorageContext -StorageAccountName $acctName -StorageAccountKey $storageKey
        }

        # Extrair key para parallel (se necessário)
        if ($ThrottleLimit -gt 1 -and -not $storageKey) {
            try {
                $keys = Get-AzStorageAccountKey -ResourceGroupName $acctRG -Name $acctName -ErrorAction Stop
                $storageKey = $keys[0].Value
            } catch {
                Log "Não foi possível obter key para paralelismo. Usando sequencial." "WARN"
                $storageKey = $null
            }
        }

        $armContainers = @(Get-AzRmStorageContainer -ResourceGroupName $acctRG -StorageAccountName $acctName -ErrorAction Stop)
        if ($ContainerName) { $armContainers = @($armContainers | Where-Object Name -eq $ContainerName) }

        $totalCtrs = $armContainers.Count
        $ctrIdx = 0

        foreach ($armCtr in $armContainers) {
            $ctrIdx++
            $ctrName = $armCtr.Name
            $stats.Containers++

            # Resume: pular containers já processados
            if ($resumeState -and $resumeState.Phase -ne 'complete' -and $acctName -eq $resumeState.AccountName) {
                if ($ctrName -ne $resumeState.ContainerName) {
                    VLog "Resume: pulando container '$ctrName' (já processado)" "DEBUG"
                    continue
                }
            }

            # Info do container
            $cInfo = [PSCustomObject]@{
                Name = $ctrName; HasPolicy = [bool]$armCtr.HasImmutabilityPolicy
                PolicyState = $null; RetentionDays = $null
                VersionWorm = [bool]$armCtr.ImmutableStorageWithVersioning
                HasLegalHold = [bool]$armCtr.HasLegalHold
            }
            if ($armCtr.HasImmutabilityPolicy) {
                $stats.ContainersWithPolicy++
                try {
                    $pol = Get-AzRmStorageContainerImmutabilityPolicy -ResourceGroupName $acctRG `
                        -StorageAccountName $acctName -ContainerName $ctrName -ErrorAction Stop
                    $cInfo.PolicyState = $pol.State
                    $cInfo.RetentionDays = $pol.ImmutabilityPeriodSinceCreationInDays
                } catch {}
            }
            $containerInfo.Add($cInfo)
            Log "  Container [$ctrIdx/$totalCtrs]: $ctrName $(if($cInfo.HasPolicy){"| $($cInfo.PolicyState) ($($cInfo.RetentionDays)d)"}else{'| Sem política'})" "INFO"

            # ==============================================================
            # PAGINAÇÃO com pipeline streaming
            # ==============================================================
            $ctrStart = Get-Date
            $ctrBlobs = 0; $ctrExpired = 0; $ctrRemoved = 0; $ctrBytes = [long]0
            $token = $null
            $pageNum = 0

            # Resume: pular até a página do checkpoint
            $resumePage = 0
            if ($resumeState -and $acctName -eq $resumeState.AccountName -and $ctrName -eq $resumeState.ContainerName) {
                $resumePage = $resumeState.PageNum
                Log "  Resume: retomando da página $($resumePage + 1)" "WARN"
            }

            do {
                $pageNum++
                if (Test-MaxErrorsReached) { break accountLoop }

                $listP = @{
                    Container      = $ctrName
                    Context        = $storageCtx
                    MaxCount       = $PageSize
                    IncludeVersion = $true
                    Verbose        = $false  # NUNCA verbose nos cmdlets Az (memória!)
                }
                if ($BlobPrefix) { $listP['Prefix'] = $BlobPrefix }
                if ($null -ne $token) { $listP['ContinuationToken'] = $token }

                # Se em modo resume, páginas anteriores são apenas escaneadas para avançar o token
                $isSkipPage = ($resumePage -gt 0 -and $pageNum -le $resumePage)
                if ($isSkipPage) {
                    Log "    Pág ${pageNum}: avançando token (resume)..." "DEBUG"
                }
                else {
                    Log "    Pág ${pageNum}: lendo até $PageSize blobs..." "INFO"
                }

                # ==========================================================
                # PIPELINE STREAMING — Um blob por vez, sem array
                # ==========================================================
                $pageEligible = [System.Collections.Generic.List[hashtable]]::new()
                $pageBlobCount = 0
                $pageExpired = 0; $pageActive = 0; $pageLH = 0; $pageNoPolicy = 0
                $pageBytesEligible = [long]0
                $analyzeStart = Get-Date
                $token = $null  # Reset antes do pipeline
                $pipelineError = $null

                try {
                    Invoke-WithRetry -Context "ListBlobs($ctrName/pág$pageNum)" -Attempts $MaxRetryAttempts -BaseDelaySeconds $RetryDelaySeconds -Operation {
                        Get-AzStorageBlob @listP -ErrorAction Stop
                    } | ForEach-Object {
                        # CRITICAL: $_ é o SDK blob object. Extrair TUDO que precisamos e soltar.
                        $pageBlobCount++

                        # Capturar token de CADA blob (o último ganha)
                        try { $script:token = $_.ContinuationToken } catch { $script:token = $null }

                        if ($isSkipPage) {
                            $script:ctrBlobs++
                            return  # Next in pipeline
                        }

                        # Extrair campos leves do blob pesado
                        $bName = $_.Name
                        $bVersionId = $null; try { $bVersionId = $_.VersionId } catch {}
                        $bIsCurrent = $null; try { $bIsCurrent = $_.IsCurrentVersion } catch {}
                        $bLength = $_.Length
                        $bTier = $_.AccessTier
                        $bExpOn = $null; $bMode = $null; $bHasLH = $false
                        try { $bExpOn = $_.BlobProperties.ImmutabilityPolicy.ExpiresOn } catch {}
                        try { $bMode = $_.BlobProperties.ImmutabilityPolicy.PolicyMode } catch {}
                        try { $bHasLH = [bool]$_.BlobProperties.HasLegalHold } catch {}

                        # >>> $_ (SDK object) NÃO É MAIS NECESSÁRIO APÓS ESTE PONTO <<<

                        $script:ctrBlobs++
                        $script:stats.Blobs++
                        $script:stats.BytesScanned += $bLength
                        $script:acctBlobCount++
                        $script:acctBytes += $bLength
                        $script:ctrBytes += $bLength

                        # Inline progress
                        $progressInterval = if ($PageSize -le 200) { 10 } else { 100 }
                        if ($pageBlobCount % $progressInterval -eq 0) {
                            $tp = Throughput $pageBlobCount $analyzeStart
                            InlineProgress "    [ANALISANDO] Pág ${pageNum}: $pageBlobCount | Exp: $pageExpired | Elig: $($pageEligible.Count) | $tp"
                        }

                        # Análise de imutabilidade
                        $status = "NoPolicy"; $eligible = $false; $action = "None"; $days = 0

                        if ($null -ne $bExpOn) {
                            $expDate = [DateTimeOffset]$bExpOn
                            if ($expDate -lt $now) {
                                $days = [math]::Floor(($now - $expDate).TotalDays)
                                $status = "Expired"
                                $script:ctrExpired++
                                $script:stats.Expired++
                                $pageExpired++

                                if ($MaxDaysExpired -gt 0 -and $days -lt $MaxDaysExpired) {
                                    $action = "SkippedMinDays"
                                }
                                elseif ($bHasLH) {
                                    $action = "SkippedLegalHold"
                                    $script:stats.LegalHold++; $pageLH++
                                }
                                else {
                                    $eligible = $true
                                    $script:stats.Eligible++
                                    $script:stats.BytesEligible += $bLength
                                    $script:acctEligibleBytes += $bLength
                                    $pageBytesEligible += $bLength
                                }
                            }
                            else {
                                $status = "Active"
                                $script:stats.Active++; $pageActive++
                            }
                        }
                        elseif ($bHasLH) {
                            $status = "LegalHold"
                            $script:stats.LegalHold++; $pageLH++
                        }
                        else { $pageNoPolicy++ }

                        # Coletar elegíveis como hashtable LEVE
                        if ($eligible) {
                            $item = @{
                                Container = $ctrName; Blob = $bName; VersionId = $bVersionId
                                Size = $bLength; Mode = $bMode
                            }

                            if ($MinAccountSizeTB -gt 0 -and ($modeRemove -or $modePolicyOnly)) {
                                $action = "PendingThreshold"
                                $thresholdQueue.Add($item)
                            }
                            elseif ($modeRemove -or $modePolicyOnly) {
                                $pageEligible.Add($item)
                            }
                            else {
                                $action = "DryRun"
                            }
                        }

                        # Salvar resultado em disco (se tem política)
                        if ($status -ne "NoPolicy") {
                            Write-ResultToDisk @{
                                Account = $acctName; Container = $ctrName; Blob = $bName
                                VersionId = $bVersionId; IsCurrent = $bIsCurrent
                                Size = $bLength; Tier = $bTier; ExpiresOn = $bExpOn
                                Mode = $bMode; HasLegalHold = $bHasLH
                                Status = $status; DaysExp = $days; Eligible = $eligible; Action = $action
                            }
                        }

                        # DryRun log
                        if ($modeDryRun -and $eligible) {
                            $vL = if ($bVersionId) { " [v:$($bVersionId.Substring(0,[math]::Min(16,$bVersionId.Length)))]" } else { "" }
                            Log "    DRYRUN: '$bName'$vL — ${days}d expirado ($(FmtSize $bLength)) [$bMode]" "INFO"
                        }
                    }
                }
                catch {
                    $pipelineError = $_.Exception.Message
                    AddError "ListBlobs($ctrName/pág$pageNum)" $pipelineError
                }

                # Limpar progress inline
                Write-Host "`r$(' ' * 140)`r" -NoNewline
                if ($pageBlobCount -gt 0 -and -not $isSkipPage) { Write-Host "" }

                $stats.Pages++
                $hasMore = if ($null -ne $token) { "→ mais" } else { "→ fim" }

                if ($isSkipPage) {
                    VLog "    Pág ${pageNum}: $pageBlobCount blobs (skip) $hasMore" "DEBUG"
                }
                else {
                    $analyzeDur = ((Get-Date) - $analyzeStart).TotalSeconds
                    Log "    Pág ${pageNum}: $pageBlobCount blobs em $([math]::Round($analyzeDur,1))s | Exp: $pageExpired | Elig: $($pageEligible.Count) ($(FmtSize $pageBytesEligible)) | Ativos: $pageActive $hasMore" "INFO"
                }

                if ($null -ne $pipelineError) {
                    if ($null -eq $token) { break }
                }

                # ==========================================================
                # FASE 2: DELEÇÃO (paralela ou sequencial) desta página
                # ==========================================================
                if ($pageEligible.Count -gt 0 -and -not $isSkipPage) {
                    Write-Host ""
                    Log "    ► REMOVENDO: $($pageEligible.Count) blob(s) | $(FmtSize $pageBytesEligible) | Pág $pageNum | Threads: $ThrottleLimit" "WARN"

                    $actionStart = Get-Date
                    $pageRemoved = 0
                    $pageErrors = 0

                    if ($ThrottleLimit -gt 1 -and $null -ne $storageKey) {
                        # =============================================
                        # DELEÇÃO PARALELA
                        # =============================================
                        $parallelResults = $pageEligible | ForEach-Object -Parallel {
                            $item = $_
                            $saName = $using:acctName
                            $saKey = $using:storageKey
                            $doRemove = $using:modeRemove
                            $doPolicyOnly = $using:modePolicyOnly

                            $result = @{ Blob = $item.Blob; Size = $item.Size; Action = "Error"; ErrorMsg = $null }

                            try {
                                $ctx = New-AzStorageContext -StorageAccountName $saName -StorageAccountKey $saKey
                                $polP = @{ Container = $item.Container; Blob = $item.Blob; Context = $ctx }

                                if ($doPolicyOnly) {
                                    Remove-AzStorageBlobImmutabilityPolicy @polP -ErrorAction Stop
                                    $result.Action = "PolicyRemoved"
                                }
                                elseif ($doRemove) {
                                    if ($item.Mode) {
                                        try { Remove-AzStorageBlobImmutabilityPolicy @polP -ErrorAction Stop }
                                        catch {
                                            if ($_.Exception.Message -notmatch 'BlobNotFound|404|does not exist') { }
                                        }
                                    }
                                    $delP = @{ Container = $item.Container; Blob = $item.Blob; Context = $ctx; Force = $true }
                                    if ($item.VersionId) { $delP['VersionId'] = $item.VersionId }
                                    Remove-AzStorageBlob @delP -ErrorAction Stop
                                    $result.Action = "Removed"
                                }
                            }
                            catch {
                                $e = $_.Exception.Message
                                if ($e -match 'BlobNotFound|404|does not exist') {
                                    $result.Action = "AlreadyDeleted"
                                }
                                else {
                                    $result.Action = "Error"
                                    $result.ErrorMsg = $e
                                }
                            }
                            $result
                        } -ThrottleLimit $ThrottleLimit

                        foreach ($pr in $parallelResults) {
                            switch ($pr.Action) {
                                "Removed" {
                                    $pageRemoved++; $stats.Removed++; $stats.PoliciesRemoved++
                                    $stats.BytesRemoved += $pr.Size
                                    ResetConsecutiveErrors
                                }
                                "PolicyRemoved" {
                                    $stats.PoliciesRemoved++
                                    ResetConsecutiveErrors
                                }
                                "AlreadyDeleted" {
                                    ResetConsecutiveErrors
                                }
                                "Error" {
                                    $pageErrors++
                                    AddError "ParallelRemove($($pr.Blob))" $pr.ErrorMsg
                                }
                            }
                        }
                        $parallelResults = $null
                    }
                    else {
                        # =============================================
                        # DELEÇÃO SEQUENCIAL
                        # =============================================
                        $actionIdx = 0
                        foreach ($item in $pageEligible) {
                            $actionIdx++
                            if (Test-MaxErrorsReached) { break }

                            $vLabel = if ($item.VersionId) { " [v:$($item.VersionId.Substring(0,[math]::Min(16,$item.VersionId.Length)))]" } else { "" }
                            $target = "$($item.Container)/$($item.Blob)"

                            if (-not $PSCmdlet.ShouldProcess($target, "Remover blob com imutabilidade expirada")) {
                                continue
                            }

                            $polP = @{ Container = $item.Container; Blob = $item.Blob; Context = $storageCtx }

                            if ($modePolicyOnly) {
                                try {
                                    Invoke-WithRetry -Context "RemovePolicy" -Attempts $MaxRetryAttempts -BaseDelaySeconds $RetryDelaySeconds -Operation {
                                        Remove-AzStorageBlobImmutabilityPolicy @polP -ErrorAction Stop
                                    } | Out-Null
                                    $stats.PoliciesRemoved++
                                    ResetConsecutiveErrors
                                    if ($verbose -or $actionIdx -le 5 -or $actionIdx % 100 -eq 0 -or $actionIdx -eq $pageEligible.Count) {
                                        Log "    [$actionIdx/$($pageEligible.Count)] POLICY: '$($item.Blob)'$vLabel" "SUCCESS"
                                    }
                                }
                                catch {
                                    $e = $_.Exception.Message
                                    if (Test-BlobNotFoundError -Message $e) { ResetConsecutiveErrors }
                                    else { AddError "RemovePolicy($($item.Blob))" $e }
                                }
                            }
                            elseif ($modeRemove) {
                                try {
                                    if ($item.Mode) {
                                        try {
                                            Invoke-WithRetry -Context "Policy" -Attempts $MaxRetryAttempts -BaseDelaySeconds $RetryDelaySeconds -Operation {
                                                Remove-AzStorageBlobImmutabilityPolicy @polP -ErrorAction Stop
                                            } | Out-Null
                                            $stats.PoliciesRemoved++
                                        }
                                        catch {
                                            if ($_.Exception.Message -notmatch 'BlobNotFound|404|does not exist') {
                                                Log "    Aviso policy: $($_.Exception.Message)" "WARN"
                                            }
                                        }
                                    }

                                    $delP = @{ Container = $item.Container; Blob = $item.Blob; Context = $storageCtx; Force = $true }
                                    if ($item.VersionId) { $delP['VersionId'] = $item.VersionId }

                                    Invoke-WithRetry -Context "Delete" -Attempts $MaxRetryAttempts -BaseDelaySeconds $RetryDelaySeconds -Operation {
                                        Remove-AzStorageBlob @delP -ErrorAction Stop
                                    } | Out-Null

                                    $pageRemoved++; $stats.Removed++; $stats.BytesRemoved += $item.Size
                                    $ctrRemoved++
                                    ResetConsecutiveErrors

                                    if ($verbose -or $actionIdx -le 5 -or $actionIdx % 100 -eq 0 -or $actionIdx -eq $pageEligible.Count) {
                                        Log "    [$actionIdx/$($pageEligible.Count)] REMOVED: '$($item.Blob)'$vLabel ($(FmtSize $item.Size))" "SUCCESS"
                                    }
                                }
                                catch {
                                    $e = $_.Exception.Message
                                    if ($e -match 'BlobNotFound|404|does not exist') { ResetConsecutiveErrors }
                                    else { AddError "RemoveBlob($($item.Blob))" $e }
                                }
                            }
                        }
                    }

                    $actionDur = ((Get-Date) - $actionStart).TotalSeconds
                    Write-Host ""
                    Log "    ✓ Pág ${pageNum}: $pageRemoved removidos, $pageErrors erros em $([math]::Round($actionDur,1))s" "SUCCESS"
                }

                # Liberar memória da página AGRESSIVAMENTE
                $pageEligible.Clear()
                $pageEligible = $null
                [System.GC]::Collect([System.GC]::MaxGeneration, [System.GCCollectionMode]::Forced, $true)
                [System.GC]::WaitForPending
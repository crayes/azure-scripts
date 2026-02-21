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
$version = "4.2.0"
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
$OutputPath = (Resolve-Path $OutputPath).Path   # Absoluto — .NET APIs (WriteAllLines, StreamReader) não resolvem PWD do PowerShell
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
        # ContinuationToken é um objeto complexo; serializar como base64 se existir
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
    # Restaurar stats
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
            $ctrLabel = if ($cInfo.HasPolicy) { "| $($cInfo.PolicyState) ($($cInfo.RetentionDays)d)" } else { '| Sem política' }
            Log "  Container [$ctrIdx/$totalCtrs]: $ctrName $ctrLabel" "INFO"

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
                # Precisamos re-paginar até chegar na página certa
                # Não temos o token serializado, então re-escaneamos rapidamente
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

                $pageRetry = 0
                :pageRetryLoop while ($true) {
                try {
                    # STREAMING DIRETO — sem Invoke-WithRetry que quebra o pipeline!
                    # Get-AzStorageBlob emite objetos um-a-um no pipeline.
                    # ForEach-Object processa cada um e solta imediatamente.
                    Get-AzStorageBlob @listP -ErrorAction Stop | ForEach-Object {
                        # CRITICAL: $_ é o SDK blob object. Extrair TUDO que precisamos e soltar.
                        $pageBlobCount++

                        # Capturar token de CADA blob (o último ganha)
                        try { $script:token = $_.ContinuationToken } catch { $script:token = $null }

                        if ($isSkipPage) {
                            # Modo resume skip: só avançar token, não processar
                            $script:ctrBlobs++
                            return  # Next in pipeline
                        }

                        # Extrair campos leves do blob pesado
                        $bName = $_.Name
                        $bVersionId = $null; try { $vid = $_.VersionId; if ($vid) { $bVersionId = if ($vid -is [string]) { $vid } else { $vid.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ") } } } catch {}
                        $bIsCurrent = $null; try { $bIsCurrent = $_.IsCurrentVersion } catch {}
                        $bLength = $_.Length
                        $bTier = $_.AccessTier
                        $bExpOn = $null; $bMode = $null; $bHasLH = $false
                        try { $bExpOn = $_.BlobProperties.ImmutabilityPolicy.ExpiresOn } catch {}
                        try { $bMode = $_.BlobProperties.ImmutabilityPolicy.PolicyMode } catch {}
                        try { $bHasLH = [bool]$_.BlobProperties.HasLegalHold } catch {}

                        # >>> $_ (SDK object) NÃO É MAIS NECESSÁRIO APÓS ESTE PONTO <<<
                        # O pipeline libera a referência automaticamente na próxima iteração.

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

                        # Coletar elegíveis como hashtable LEVE (não PSCustomObject pesado)
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
                    # Retry transiente no nível da página inteira
                    if ($pageRetry -lt $MaxRetryAttempts -and (Test-TransientAzError -Message $pipelineError)) {
                        $pageRetry++
                        $delay = [math]::Min(30, [math]::Max(1, ($RetryDelaySeconds * [math]::Pow(2, $pageRetry - 1))))
                        Log "    Pág ${pageNum}: erro transitório ($pageRetry/$MaxRetryAttempts): $pipelineError | retry em ${delay}s" "WARN"
                        Start-Sleep -Seconds $delay
                        # Reset contadores da página para re-processar
                        $pageBlobCount = 0; $pageExpired = 0; $pageActive = 0; $pageLH = 0; $pageNoPolicy = 0
                        $pageBytesEligible = [long]0; $pageEligible.Clear()
                        $token = $null  # Re-fetch da mesma página (token anterior)
                        if ($null -ne $listP['ContinuationToken']) { $token = $listP['ContinuationToken'] }
                        continue pageRetryLoop
                    }
                    AddError "ListBlobs($ctrName/pág$pageNum)" $pipelineError
                }
                break  # Sucesso ou erro não-transitório: sair do retry loop
                }  # fim :pageRetryLoop

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
                    if ($null -eq $token) { break }  # Sem token = não pode continuar
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
                            $retryMax = $using:MaxRetryAttempts
                            $retryDelay = $using:RetryDelaySeconds

                            $result = @{ Blob = $item.Blob; Size = $item.Size; Action = "Error"; ErrorMsg = $null }

                            try {
                                # Contexto leve criado dentro do runspace
                                $ctx = New-AzStorageContext -StorageAccountName $saName -StorageAccountKey $saKey
                                $polP = @{ Container = $item.Container; Blob = $item.Blob; Context = $ctx }

                                if ($doPolicyOnly) {
                                    Remove-AzStorageBlobImmutabilityPolicy @polP -ErrorAction Stop
                                    $result.Action = "PolicyRemoved"
                                }
                                elseif ($doRemove) {
                                    # Passo 1: remover política
                                    if ($item.Mode) {
                                        try { Remove-AzStorageBlobImmutabilityPolicy @polP -ErrorAction Stop }
                                        catch {
                                            if ($_.Exception.Message -notmatch 'BlobNotFound|404|does not exist') {
                                                # Não bloquear — tentar delete mesmo assim
                                            }
                                        }
                                    }
                                    # Passo 2: deletar blob
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

                        # Processar resultados do parallel
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
                        # Liberar resultados do parallel
                        $parallelResults = $null
                    }
                    else {
                        # =============================================
                        # =============================================
                        # DELEÇÃO VIA SUBPROCESS (v4.2 — memória isolada)
                        # Cada batch roda num processo pwsh separado.
                        # Quando o processo morre, o OS libera TODA a memória.
                        # =============================================
                        $batchSize = 200
                        $totalEligible = $pageEligible.Count
                        $batchNum = 0

                        # Obter storage key se não temos (necessário para subprocess)
                        if (-not $storageKey) {
                            try {
                                $keys = Get-AzStorageAccountKey -ResourceGroupName $acctRG -Name $acctName -ErrorAction Stop
                                $storageKey = $keys[0].Value
                            } catch {
                                Log "    ERRO: Não foi possível obter key para subprocess. Abortando deleção." "ERROR"
                                AddError "GetKey($acctName)" $_.Exception.Message
                                $storageKey = $null
                            }
                        }

                        if ($storageKey) {
                            # Dir para batches e script helper
                            $batchDir = Join-Path $OutputPath ".batches_$ts"
                            if (-not (Test-Path $batchDir)) { New-Item -ItemType Directory -Path $batchDir -Force | Out-Null }

                            # Gerar script helper em disco (executado por cada subprocess)
                            $helperScript = Join-Path $batchDir "delete_helper.ps1"
                            $helperContent = @'
param(
    [string]$AccountName,
    [string]$AccountKey,
    [string]$BatchFile,
    [string]$ResultFile,
    [int]$DoRemove,
    [int]$DoPolicyOnly
)
$ErrorActionPreference = 'Continue'
Import-Module Az.Storage -ErrorAction Stop
$ctx = New-AzStorageContext -StorageAccountName $AccountName -StorageAccountKey $AccountKey
# Parse JSON manual — ConvertFrom-Json converte VersionId ISO para DateTime local, Azure rejeita
$items = [System.Collections.Generic.List[hashtable]]::new()
foreach ($line in [System.IO.File]::ReadAllLines($BatchFile)) {
    $line = $line.Trim().TrimEnd(',')
    if ($line -match '^\{') {
        $h = @{}
        foreach ($m in [regex]::Matches($line, '"(\w+)"\s*:\s*(?:"([^"]*)"|([\d.]+)|null)')) {
            $k = $m.Groups[1].Value
            if ($m.Groups[2].Success) { $h[$k] = $m.Groups[2].Value }
            elseif ($m.Groups[3].Success) { $h[$k] = [long]$m.Groups[3].Value }
        }
        $items.Add($h)
    }
}
$removed = 0; $errors = 0; $polRemoved = 0; $bytesRemoved = [long]0; $errList = @()
foreach ($item in $items) {
    try {
        $polP = @{ Container = $item.Container; Blob = $item.Blob; Context = $ctx }
        if ($item.VersionId) { $polP['VersionId'] = $item.VersionId }
        if ($DoPolicyOnly) {
            $null = Remove-AzStorageBlobImmutabilityPolicy @polP -ErrorAction Stop
            $polRemoved++
        } elseif ($DoRemove) {
            if ($item.Mode) {
                try { $null = Remove-AzStorageBlobImmutabilityPolicy @polP -ErrorAction Stop; $polRemoved++ }
                catch { if ($_.Exception.Message -notmatch 'BlobNotFound|404|does not exist') {} }
            }
            $delP = @{ Container = $item.Container; Blob = $item.Blob; Context = $ctx; Force = $true }
            if ($item.VersionId) { $delP['VersionId'] = $item.VersionId }
            $null = Remove-AzStorageBlob @delP -ErrorAction Stop
            $removed++; $bytesRemoved += $item.Size
        }
    } catch {
        $e = $_.Exception.Message
        if ($e -match 'BlobNotFound|404|does not exist') { <# OK - already deleted #> }
        else { $errors++; if ($errList.Count -lt 10) { $errList += $e } }
    }
}
@{ Removed = $removed; Errors = $errors; PoliciesRemoved = $polRemoved; BytesRemoved = $bytesRemoved; ErrorList = $errList } |
    ConvertTo-Json -Depth 3 -Compress | Out-File -FilePath $ResultFile -Encoding utf8
'@
                            $helperContent | Out-File -FilePath $helperScript -Encoding utf8

                            for ($bi = 0; $bi -lt $totalEligible; $bi += $batchSize) {
                                $batchNum++
                                $batchEnd = [math]::Min($bi + $batchSize, $totalEligible)
                                $batchItems = $pageEligible.GetRange($bi, $batchEnd - $bi)
                                $batchFile = Join-Path $batchDir "batch_${pageNum}_${batchNum}.json"
                                $resultFile = Join-Path $batchDir "result_${pageNum}_${batchNum}.json"

                                # Escrever batch em disco (JSON manual para preservar VersionId como string)
                                $jsonLines = [System.Collections.Generic.List[string]]::new()
                                $jsonLines.Add("[")
                                for ($ji = 0; $ji -lt $batchItems.Count; $ji++) {
                                    $it = $batchItems[$ji]
                                    $jBlob = ($it.Blob -replace '\\','\\' -replace '"','\"')
                                    $jVer = if ($it.VersionId) { "`"$($it.VersionId)`"" } else { "null" }
                                    $jMode = if ($it.Mode) { "`"$($it.Mode)`"" } else { "null" }
                                    $comma = if ($ji -lt $batchItems.Count - 1) { "," } else { "" }
                                    $jsonLines.Add("{`"Container`":`"$($it.Container)`",`"Blob`":`"$jBlob`",`"VersionId`":$jVer,`"Size`":$($it.Size),`"Mode`":$jMode}$comma")
                                }
                                $jsonLines.Add("]")
                                [System.IO.File]::WriteAllLines($batchFile, $jsonLines)

                                Log "    Batch $batchNum [$($bi+1)..$batchEnd/$totalEligible]: spawning subprocess..." "INFO"

                                # Executar helper script em subprocess isolado
                                $stderrFile = [System.IO.Path]::GetTempFileName()
                                $subProc = Start-Process -FilePath "pwsh" -ArgumentList @(
                                    "-NoProfile", "-NonInteractive", "-File", $helperScript,
                                    "-AccountName", $acctName,
                                    "-AccountKey", $storageKey,
                                    "-BatchFile", $batchFile,
                                    "-ResultFile", $resultFile,
                                    "-DoRemove", $(if($modeRemove){"1"}else{"0"}),
                                    "-DoPolicyOnly", $(if($modePolicyOnly){"1"}else{"0"})
                                ) -Wait -PassThru -NoNewWindow -RedirectStandardError $stderrFile

                                # Ler resultado
                                if (Test-Path $resultFile) {
                                    try {
                                        $bResult = Get-Content $resultFile -Raw | ConvertFrom-Json
                                        $pageRemoved += $bResult.Removed
                                        $stats.Removed += $bResult.Removed
                                        $stats.BytesRemoved += $bResult.BytesRemoved
                                        $stats.PoliciesRemoved += $bResult.PoliciesRemoved
                                        $ctrRemoved += $bResult.Removed
                                        $pageErrors += $bResult.Errors
                                        $stats.Errors += $bResult.Errors
                                        if ($bResult.Removed -gt 0) { ResetConsecutiveErrors }
                                        foreach ($errMsg in @($bResult.ErrorList)) {
                                            if ($errMsg -and $stats.ErrorList.Count -lt 200) { $stats.ErrorList.Add("[SubBatch$batchNum] $errMsg") }
                                        }
                                        $batchLogLevel = if ($bResult.Errors -gt 0) { "WARN" } else { "SUCCESS" }
                                        Log "    Batch ${batchNum}: $($bResult.Removed) removidos, $($bResult.Errors) erros ($(FmtSize $bResult.BytesRemoved))" $batchLogLevel
                                        if ($bResult.ErrorList -and @($bResult.ErrorList).Count -gt 0) {
                                            @($bResult.ErrorList) | Select-Object -First 3 | ForEach-Object {
                                                Log "      ERRO: $_" "ERROR"
                                            }
                                        }
                                    } catch {
                                        Log "    Batch ${batchNum}: erro lendo resultado: $($_.Exception.Message)" "ERROR"
                                        $pageErrors++; $stats.Errors++
                                    }
                                    Remove-Item $resultFile -Force -ErrorAction SilentlyContinue
                                } else {
                                    # Ler stderr para diagnóstico
                                    $stderrContent = if (Test-Path $stderrFile) { (Get-Content $stderrFile -Raw) -replace "`r`n|`n"," " } else { "N/A" }
                                    $stderrSnippet = if ($stderrContent.Length -gt 300) { $stderrContent.Substring(0, 300) } else { $stderrContent }
                                    Log "    Batch ${batchNum}: subprocess falhou (exit: $($subProc.ExitCode)) stderr: $stderrSnippet" "ERROR"
                                    $pageErrors += $batchItems.Count; $stats.Errors += $batchItems.Count
                                }
                                Remove-Item $batchFile -Force -ErrorAction SilentlyContinue
                                Remove-Item $stderrFile -Force -ErrorAction SilentlyContinue

                                if (Test-MaxErrorsReached) { break }
                            }
                            # Limpar dir de batches
                            Remove-Item $batchDir -Recurse -Force -ErrorAction SilentlyContinue
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
                [System.GC]::WaitForPendingFinalizers()
                [System.GC]::Collect([System.GC]::MaxGeneration, [System.GCCollectionMode]::Forced, $true)

                # Checkpoint após cada página
                Save-Checkpoint -AccountName $acctName -Container $ctrName -PageNum $pageNum `
                    -Token $token -Stats $stats -Phase 'scanning'

            } while ($null -ne $token)
            # ============== FIM PAGINAÇÃO ==============

            $ctrDur = ((Get-Date) - $ctrStart).ToString('hh\:mm\:ss')
            $ctrTp = Throughput $ctrBlobs $ctrStart
            Write-Host ""
            Log "  Resumo '$ctrName': $ctrBlobs blobs ($pageNum pág) | $(FmtSize $ctrBytes) | Exp: $ctrExpired | Rem: $ctrRemoved | $ctrTp | $ctrDur" "INFO"

            # Limpar após container completo
            $resumeState = $null  # Não precisa mais do resume state após retomar
        }

        # Threshold queue (após toda a conta)
        if ($MinAccountSizeTB -gt 0 -and ($modeRemove -or $modePolicyOnly) -and $thresholdQueue.Count -gt 0) {
            $thresholdBytes = [long]$MinAccountSizeTB * 1TB
            if ($acctBytes -ge $thresholdBytes) {
                Log "Conta '$acctName' >= ${MinAccountSizeTB}TB. Processando $($thresholdQueue.Count) blob(s)..." "WARN"
                $tIdx = 0
                foreach ($qItem in $thresholdQueue) {
                    $tIdx++
                    if (Test-MaxErrorsReached) { break }
                    $target = "$($qItem.Container)/$($qItem.Blob)"
                    if (-not $PSCmdlet.ShouldProcess($target, "Threshold remove")) { continue }
                    $polP = @{ Container = $qItem.Container; Blob = $qItem.Blob; Context = $storageCtx }
                    try {
                        if ($qItem.Mode) {
                            try { Remove-AzStorageBlobImmutabilityPolicy @polP -ErrorAction Stop; $stats.PoliciesRemoved++ } catch {}
                        }
                        if ($modeRemove) {
                            $delP = @{ Container = $qItem.Container; Blob = $qItem.Blob; Context = $storageCtx; Force = $true }
                            if ($qItem.VersionId) { $delP['VersionId'] = $qItem.VersionId }
                            Remove-AzStorageBlob @delP -ErrorAction Stop
                            $stats.Removed++; $stats.BytesRemoved += $qItem.Size
                        } else { $stats.PoliciesRemoved++ }
                    }
                    catch {
                        $e = $_.Exception.Message
                        if ($e -notmatch 'BlobNotFound|404') { AddError "Threshold($($qItem.Blob))" $e }
                    }
                }
            } else {
                Log "Conta '$acctName' < ${MinAccountSizeTB}TB ($(FmtSize $acctBytes)). Sem ação." "INFO"
            }
        }
        $thresholdQueue.Clear()
        $thresholdQueue = $null

        $acctDur = ((Get-Date) - $acctStart).ToString('hh\:mm\:ss')
        Log "Resumo '$acctName': $acctBlobCount blobs | $(FmtSize $acctBytes) | Elegível: $(FmtSize $acctEligibleBytes) | $acctDur" "SUCCESS"
    }
    catch {
        Log "EXCEÇÃO '$acctName': $($_.Exception.Message)" "ERROR"
        Log "StackTrace: $($_.ScriptStackTrace)" "ERROR"
        AddError "Account($acctName)" $_.Exception.Message
    }
}

# Checkpoint final
Save-Checkpoint -AccountName '' -Container '' -PageNum 0 -Token $null -Stats $stats -Phase 'complete'

# ============================================================================
# RELATÓRIO HTML (lendo do CSV temporário em disco)
# ============================================================================
Log "Gerando relatórios..." "SECTION"
$duration = (Get-Date) - $startTime
$modeBadge = if ($modeDryRun) { '<span style="background:#fff3cd;color:#856404;padding:4px 12px;border-radius:12px;font-weight:600">SIMULAÇÃO</span>' }
             else { '<span style="background:#f8d7da;color:#721c24;padding:4px 12px;border-radius:12px;font-weight:600">' + $modeLabel + '</span>' }

$ctrRows = ($containerInfo | ForEach-Object {
    $lh = if ($_.HasLegalHold) { "<span style='color:#f39c12;font-weight:600'>Sim</span>" } else { "Não" }
    $ps = if ($_.PolicyState) { $_.PolicyState } else { "-" }
    $rd = if ($_.RetentionDays) { $_.RetentionDays } else { "-" }
    "<tr><td>$([System.Net.WebUtility]::HtmlEncode($_.Name))</td><td>$(if($_.HasPolicy){'Sim'}else{'Não'})</td><td>$ps</td><td>$rd</td><td>$(if($_.VersionWorm){'Sim'}else{'Não'})</td><td>$lh</td></tr>"
}) -join "`n"

# Ler resultados do disco para gerar tabela HTML (stream — uma linha por vez)
$expRowsBuilder = [System.Text.StringBuilder]::new()
$expCount = 0
if (Test-Path $tempCsvPath) {
    $reader = [System.IO.StreamReader]::new($tempCsvPath, [System.Text.Encoding]::UTF8)
    $header = $reader.ReadLine()  # Skip header
    while ($null -ne ($line = $reader.ReadLine())) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $fields = $line | ConvertFrom-Csv -Header Account,Container,Blob,VersionId,IsCurrent,Size,SizeFmt,Tier,ExpiresOn,Mode,LegalHold,Status,DaysExp,Eligible,Action
            $f = $fields
            if ($f.Status -ne 'Expired') { continue }
            $expCount++
            $short = if ($f.Blob.Length -gt 60) { $f.Blob.Substring(0,57)+'...' } else { $f.Blob }
            $vShort = if ($f.VersionId -and $f.VersionId.Length -gt 0) { $f.VersionId.Substring(0,[math]::Min(16,$f.VersionId.Length))+'...' } else { '-' }
            $ac = switch -Wildcard ($f.Action) { "DryRun*"{"color:#3498db"} "*Removed*"{"color:#e74c3c"} "Skipped*"{"color:#95a5a6"} "Error*"{"color:#e74c3c;font-weight:600"} default{""} }
            $null = $expRowsBuilder.Append("<tr><td>$([System.Net.WebUtility]::HtmlEncode($f.Account))</td><td>$([System.Net.WebUtility]::HtmlEncode($f.Container))</td><td title='$([System.Net.WebUtility]::HtmlEncode($f.Blob))'>$([System.Net.WebUtility]::HtmlEncode($short))</td><td style='font-family:monospace;font-size:11px'>$([System.Net.WebUtility]::HtmlEncode($vShort))</td><td>$($f.SizeFmt)</td><td>$($f.ExpiresOn)</td><td style='color:#e74c3c;font-weight:600'>$($f.DaysExp)</td><td>$($f.Mode)</td><td style='$ac'>$($f.Action)</td></tr>`n")
        } catch { <# skip malformed lines #> }
    }
    $reader.Close()
    $reader.Dispose()
}

$expSection = ""
if ($expCount -gt 0) {
    $expSection = @"
<div class="section"><h2>Blobs com Imutabilidade Vencida ($expCount)</h2>
<div class="scroll"><table>
<thead><tr><th>Account</th><th>Container</th><th>Blob</th><th>Version</th><th>Tamanho</th><th>Expirou</th><th>Dias</th><th>Modo</th><th>Ação</th></tr></thead>
<tbody>$($expRowsBuilder.ToString())</tbody></table></div></div>
"@
}
$expRowsBuilder = $null

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
<p>$(Get-Date -Format 'dd/MM/yyyy HH:mm:ss') | Duração: $($duration.ToString('hh\:mm\:ss')) | Páginas: $($stats.Pages) | PageSize: $PageSize | Threads: $ThrottleLimit</p>
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
<div class="ft">Azure Immutability Cleanup v$version | Resultados: $tempCsvPath</div>
</body></html>
"@

$htmlPath = Join-Path $OutputPath "ImmutabilityAudit_$ts.html"
$html | Out-File -FilePath $htmlPath -Encoding utf8
$html = $null  # Liberar string HTML
Log "Relatório HTML: $htmlPath" "SUCCESS"

# CSV final (renomear o temp se exportar, ou limpar)
if ($ExportCsv) {
    $csvPath = Join-Path $OutputPath "ImmutabilityAudit_$ts.csv"
    Move-Item -Path $tempCsvPath -Destination $csvPath -Force
    Log "Relatório CSV: $csvPath" "SUCCESS"
} else {
    Remove-Item -Path $tempCsvPath -Force -ErrorAction SilentlyContinue
}

# Limpar checkpoint se completou sem erros
if ($stats.Errors -eq 0 -and -not $DisableCheckpoint.IsPresent) {
    Remove-Item -Path $checkpointPath -Force -ErrorAction SilentlyContinue
    Log "Checkpoint removido (execução limpa)" "INFO"
} else {
    Log "Checkpoint mantido: $checkpointPath (use -ResumeFrom para retomar)" "WARN"
}

# ============================================================================
# RESUMO FINAL
# ============================================================================
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "  RESUMO v$version" -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host ""
Log "Accounts: $($stats.Accounts) | Containers: $($stats.Containers) (com política: $($stats.ContainersWithPolicy))" "INFO"
Log "Páginas: $($stats.Pages) | Blobs: $($stats.Blobs.ToString('N0')) ($(FmtSize $stats.BytesScanned))" "INFO"
Write-Host ""
$el = if ($stats.Expired -gt 0) { "WARN" } else { "SUCCESS" }
Log "Expirados: $($stats.Expired.ToString('N0')) | Ativos: $($stats.Active.ToString('N0')) | Legal Hold: $($stats.LegalHold)" $el
Log "Elegível: $($stats.Eligible.ToString('N0')) ($(FmtSize $stats.BytesEligible))" "INFO"

if ($modeRemove -or $modePolicyOnly) {
    Write-Host ""
    Log "REMOVIDOS: $($stats.Removed.ToString('N0')) | Espaço: $(FmtSize $stats.BytesRemoved) | Políticas: $($stats.PoliciesRemoved.ToString('N0'))" "SUCCESS"
}

Write-Host ""
$el2 = if ($stats.Errors -gt 0) { "ERROR" } else { "SUCCESS" }
Log "Erros: $($stats.Errors)" $el2
Log "Duração: $($duration.ToString('hh\:mm\:ss'))" "INFO"
Write-Host ""


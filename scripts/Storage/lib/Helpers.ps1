# ============================================================================
# Helpers.ps1 - Funções auxiliares de logging, formatação e progresso
# ============================================================================
# Todas as funções acessam config via $global:ImmAuditCfg (hashtable)
# ============================================================================

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR","SUCCESS","SECTION","DEBUG")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $colors = @{
        "INFO"="Cyan"; "WARN"="Yellow"; "ERROR"="Red"
        "SUCCESS"="Green"; "SECTION"="Magenta"; "DEBUG"="DarkGray"
    }
    $prefix = switch ($Level) {
        "INFO"{"[i]"} "WARN"{"[!]"} "ERROR"{"[X]"}
        "SUCCESS"{"[+]"} "SECTION"{"[=]"} "DEBUG"{"[D]"}
    }
    Write-Host "$timestamp $prefix $Message" -ForegroundColor $colors[$Level]
}

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1TB) { return "{0:N2} TB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes Bytes"
}

function Write-VerboseLog {
    param([string]$Message, [string]$Level = "INFO")
    if ($global:ImmAuditCfg.VerboseProgress) { Write-Log $Message $Level }
}

function Show-Progress {
    param(
        [string]$Activity,
        [string]$Status,
        [int]$PercentComplete = -1,
        [string]$CurrentOperation = ""
    )
    if (-not $global:ImmAuditCfg.VerboseProgress) { return }
    $params = @{ Activity = $Activity; Status = $Status }
    if ($PercentComplete -ge 0) { $params['PercentComplete'] = [math]::Min($PercentComplete, 100) }
    if ($CurrentOperation) { $params['CurrentOperation'] = $CurrentOperation }
    Write-Progress @params
}

function Get-ElapsedFormatted {
    param([datetime]$Since)
    $elapsed = (Get-Date) - $Since
    return "{0:hh\:mm\:ss}" -f $elapsed
}

function Get-Throughput {
    param([int]$Count, [datetime]$Since)
    $elapsed = ((Get-Date) - $Since).TotalSeconds
    if ($elapsed -le 0) { return "--" }
    return "$([math]::Round($Count / $elapsed, 1))/s"
}

function Get-ETA {
    param([int]$Processed, [int]$Total, [datetime]$Since)
    if ($Processed -le 0 -or $Total -le 0) { return "calculando..." }
    $elapsed = ((Get-Date) - $Since).TotalSeconds
    if ($elapsed -le 0) { return "calculando..." }
    $remaining = ($Total - $Processed) / ($Processed / $elapsed)
    if ($remaining -lt 60) { return "{0:N0}s" -f $remaining }
    if ($remaining -lt 3600) { return "{0:N0}min {1:N0}s" -f [math]::Floor($remaining/60), ($remaining%60) }
    return "{0:N0}h {1:N0}min" -f [math]::Floor($remaining/3600), [math]::Floor(($remaining%3600)/60)
}

function Add-ErrorDetail {
    param([string]$Context, [string]$ErrorMessage)
    $global:ImmAuditStats.Errors++
    $detail = "[$Context] $ErrorMessage"
    $global:ImmAuditStats.ErrorDetails.Add($detail)
    Write-Log $detail "ERROR"
}

function Test-AzureConnection {
    Write-Log "Verificando conexão com Azure..." "INFO"
    try {
        $context = Get-AzContext
        if (-not $context) {
            Write-Log "Não conectado ao Azure. Iniciando login..." "WARN"
            Connect-AzAccount
            $context = Get-AzContext
        }
        if ($global:ImmAuditCfg.SubscriptionId) {
            Write-Log "Selecionando subscription: $($global:ImmAuditCfg.SubscriptionId)" "INFO"
            Set-AzContext -SubscriptionId $global:ImmAuditCfg.SubscriptionId 3>$null | Out-Null
            $context = Get-AzContext
        }
        Write-Log "Conectado: $($context.Account.Id) | Subscription: $($context.Subscription.Name) ($($context.Subscription.Id))" "SUCCESS"
        return $true
    }
    catch {
        Write-Log "Falha ao conectar no Azure: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

<#
.SYNOPSIS
    Avalia e remove blobs com políticas de imutabilidade vencidas em Azure Blob Storage.

.DESCRIPTION
    Este script conecta ao Azure e varre Storage Accounts, containers e blobs para identificar
    políticas de imutabilidade (time-based retention) que já expiraram. Suporta:
    - Imutabilidade a nível de container (container-level WORM)
    - Imutabilidade a nível de blob/versão (version-level WORM)
    - Legal Holds (apenas relatório — remoção requer ação manual)
    - Modo DryRun para simulação sem remoção
    - Geração de relatório HTML e CSV
    - Filtro por Storage Account, Resource Group ou Subscription

.PARAMETER SubscriptionId
    ID da subscription Azure. Se não informado, usa a subscription atual.

.PARAMETER ResourceGroupName
    Filtrar por Resource Group específico. Se não informado, varre todos.

.PARAMETER StorageAccountName
    Filtrar por Storage Account específico. Se não informado, varre todos.

.PARAMETER ContainerName
    Filtrar por container específico. Se não informado, varre todos.

.PARAMETER DryRun
    Modo simulação: apenas lista blobs elegíveis sem remover nada. (Padrão: $true)

.PARAMETER RemoveBlobs
    Remove os blobs com imutabilidade vencida. Requer confirmação explícita.

.PARAMETER RemoveImmutabilityPolicyOnly
    Remove apenas a política de imutabilidade dos blobs, sem deletar o blob em si.

.PARAMETER OutputPath
    Caminho para salvar os relatórios. Padrão: ./Reports

.PARAMETER ExportCsv
    Exporta relatório em CSV além do HTML.

.PARAMETER IncludeSoftDeleted
    Inclui blobs soft-deleted na análise.

.PARAMETER VerboseProgress
    Ativa modo verbose com progresso detalhado em tempo real.
    Mostra barra de progresso, contadores por container, throughput (blobs/s),
    e log de cada blob analisado.
    Ideal para acompanhar Storage Accounts muito grandes (10TB+).
    
    IMPORTANTE: O script coleta TODOS os blobs primeiro e depois executa as ações.
    Isso evita loops infinitos ao remover blobs durante a iteração.

.PARAMETER MaxDaysExpired
    Filtra apenas blobs cuja imutabilidade expirou há mais de N dias.

.PARAMETER MinAccountSizeTB
    Executa ações destrutivas apenas em Storage Accounts com volume analisado igual ou superior a N TB.
    Útil para focar em contas grandes (ex: 10 TB+).

.EXAMPLE
    .\Remove-ExpiredImmutableBlobs.ps1
    Executa em modo DryRun, listando todos os blobs com imutabilidade vencida.

.EXAMPLE
    .\Remove-ExpiredImmutableBlobs.ps1 -StorageAccountName "mystorageaccount" -DryRun
    Lista blobs com imutabilidade vencida em uma Storage Account específica.

.EXAMPLE
    .\Remove-ExpiredImmutableBlobs.ps1 -StorageAccountName "mystorageaccount" -RemoveBlobs -Confirm
    Remove blobs com imutabilidade vencida após confirmação.

.EXAMPLE
    .\Remove-ExpiredImmutableBlobs.ps1 -RemoveImmutabilityPolicyOnly -MaxDaysExpired 30
    Remove apenas políticas de imutabilidade vencidas há mais de 30 dias.

.EXAMPLE
    .\Remove-ExpiredImmutableBlobs.ps1 -StorageAccountName "mystorageaccount" -VerboseProgress
    Executa com progresso detalhado em tempo real para acompanhar Storage Accounts grandes.

.EXAMPLE
    .\Remove-ExpiredImmutableBlobs.ps1 -RemoveBlobs -MinAccountSizeTB 10
    Remove blobs elegíveis apenas em Storage Accounts com 10 TB ou mais de volume analisado.

.NOTES
    Versão: 1.4.0
    Autor: M365 Security Toolkit
    Requer: Az.Storage, Az.Accounts (PowerShell 7.0+)
    Licença: MIT
    
    Changelog v1.4.0:
    - Corrigido loop infinito ao remover blobs (coleta todos os blobs primeiro, executa ações depois)
    - Removida paginação manual incorreta que causava problemas
    - Melhorada barra de progresso com percentual real
#>

#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Storage

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'DryRun')]
param(
    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$ResourceGroupName,

    [Parameter()]
    [string]$StorageAccountName,

    [Parameter()]
    [string]$ContainerName,

    [Parameter(ParameterSetName = 'DryRun')]
    [switch]$DryRun,

    [Parameter(ParameterSetName = 'RemoveBlobs')]
    [switch]$RemoveBlobs,

    [Parameter(ParameterSetName = 'RemovePolicyOnly')]
    [switch]$RemoveImmutabilityPolicyOnly,

    [Parameter()]
    [string]$OutputPath = "./Reports",

    [Parameter()]
    [switch]$ExportCsv,

    [Parameter()]
    [switch]$IncludeSoftDeleted,

    [Parameter()]
    [switch]$VerboseProgress,

    [Parameter()]
    [int]$MaxDaysExpired = 0,

    [Parameter()]
    [int]$MinAccountSizeTB = 0
)

# ============================================================================
# CONFIGURAÇÃO E CONSTANTES
# ============================================================================

$ErrorActionPreference = "Stop"
$script:ScriptVersion = "1.4.0"
$script:StartTime = Get-Date
$script:Now = [DateTimeOffset]::UtcNow

# Contadores globais
$script:Stats = @{
    StorageAccountsScanned = 0
    ContainersScanned      = 0
    BlobsScanned           = 0
    ContainersWithPolicy   = 0
    BlobsWithExpiredPolicy = 0
    BlobsWithActivePolicy  = 0
    BlobsWithLegalHold     = 0
    BlobsRemoved           = 0
    PoliciesRemoved        = 0
    Errors                 = 0
    BytesEligible          = 0
    BytesScanned           = 0
}

# Resultados para relatório
$script:Results = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:ContainerResults = [System.Collections.Generic.List[PSCustomObject]]::new()

# ============================================================================
# FUNÇÕES AUXILIARES
# ============================================================================

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS", "SECTION")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $colors = @{
        "INFO"    = "Cyan"
        "WARN"    = "Yellow"
        "ERROR"   = "Red"
        "SUCCESS" = "Green"
        "SECTION" = "Magenta"
    }

    $prefix = switch ($Level) {
        "INFO"    { "[i]" }
        "WARN"    { "[!]" }
        "ERROR"   { "[X]" }
        "SUCCESS" { "[+]" }
        "SECTION" { "[=]" }
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
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    if ($VerboseProgress) {
        Write-Log $Message $Level
    }
}

function Show-Progress {
    param(
        [string]$Activity,
        [string]$Status,
        [int]$PercentComplete = -1,
        [string]$CurrentOperation = ""
    )
    if (-not $VerboseProgress) { return }

    $params = @{
        Activity = $Activity
        Status   = $Status
    }
    if ($PercentComplete -ge 0) {
        $params['PercentComplete'] = [math]::Min($PercentComplete, 100)
    }
    if ($CurrentOperation) {
        $params['CurrentOperation'] = $CurrentOperation
    }
    Write-Progress @params
}

function Get-ElapsedFormatted {
    param([datetime]$Since)
    $elapsed = (Get-Date) - $Since
    return "{0:hh\:mm\:ss}" -f $elapsed
}

function Get-Throughput {
    param(
        [int]$Count,
        [datetime]$Since
    )
    $elapsed = ((Get-Date) - $Since).TotalSeconds
    if ($elapsed -le 0) { return "--" }
    $rate = [math]::Round($Count / $elapsed, 1)
    return "$rate/s"
}

function Get-ETA {
    param(
        [int]$Processed,
        [int]$Total,
        [datetime]$Since
    )
    if ($Processed -le 0 -or $Total -le 0) { return "calculando..." }
    $elapsed = ((Get-Date) - $Since).TotalSeconds
    if ($elapsed -le 0) { return "calculando..." }
    $rate = $Processed / $elapsed
    $remaining = ($Total - $Processed) / $rate
    if ($remaining -lt 60) { return "{0:N0}s" -f $remaining }
    if ($remaining -lt 3600) { return "{0:N0}min {1:N0}s" -f [math]::Floor($remaining / 60), ($remaining % 60) }
    return "{0:N0}h {1:N0}min" -f [math]::Floor($remaining / 3600), [math]::Floor(($remaining % 3600) / 60)
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

        if ($SubscriptionId) {
            Write-Log "Selecionando subscription: $SubscriptionId" "INFO"
            Set-AzContext -SubscriptionId $SubscriptionId 3>$null | Out-Null
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

function Get-TargetStorageAccounts {
    Write-Log "Buscando Storage Accounts..." "SECTION"

    $params = @{}
    if ($ResourceGroupName) {
        $params['ResourceGroupName'] = $ResourceGroupName
        Write-Log "Filtro Resource Group: $ResourceGroupName" "INFO"
    }

    try {
        $accounts = Get-AzStorageAccount @params

        if ($StorageAccountName) {
            $accounts = $accounts | Where-Object { $_.StorageAccountName -eq $StorageAccountName }
            Write-Log "Filtro Storage Account: $StorageAccountName" "INFO"
        }

        # Filtrar apenas contas BlobStorage ou StorageV2 que suportam imutabilidade
        $accounts = $accounts | Where-Object {
            $_.Kind -in @('StorageV2', 'BlobStorage', 'BlockBlobStorage')
        }

        Write-Log "Encontradas $($accounts.Count) Storage Account(s) compatíveis" "INFO"
        return $accounts
    }
    catch {
        Write-Log "Erro ao listar Storage Accounts: $($_.Exception.Message)" "ERROR"
        $script:Stats.Errors++
        return @()
    }
}

function Get-ContainerImmutabilityInfo {
    param(
        [string]$AccountName,
        [string]$AccountResourceGroup,
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.IStorageContext]$StorageContext
    )

    $containersToProcess = @()

    try {
        # Obter containers com informações de imutabilidade via ARM
        $armContainers = Get-AzRmStorageContainer -ResourceGroupName $AccountResourceGroup -StorageAccountName $AccountName

        if ($ContainerName) {
            $armContainers = $armContainers | Where-Object { $_.Name -eq $ContainerName }
        }

        foreach ($armContainer in $armContainers) {
            $script:Stats.ContainersScanned++

            $containerInfo = [PSCustomObject]@{
                Name                    = $armContainer.Name
                HasImmutabilityPolicy   = $armContainer.HasImmutabilityPolicy
                HasLegalHold            = $armContainer.HasLegalHold
                ImmutabilityPolicyState = $null
                RetentionDays           = $null
                PolicyExpired           = $false
                LegalHoldTags           = @()
            }

            # Verificar política de imutabilidade do container
            if ($armContainer.HasImmutabilityPolicy) {
                $script:Stats.ContainersWithPolicy++

                try {
                    $policy = Get-AzRmStorageContainerImmutabilityPolicy `
                        -ResourceGroupName $AccountResourceGroup `
                        -StorageAccountName $AccountName `
                        -ContainerName $armContainer.Name

                    $containerInfo.ImmutabilityPolicyState = $policy.State
                    $containerInfo.RetentionDays = $policy.ImmutabilityPeriodSinceCreationInDays

                    Write-Log "  Container '$($armContainer.Name)': Política=$($policy.State), Retenção=$($policy.ImmutabilityPeriodSinceCreationInDays) dias" "INFO"
                }
                catch {
                    Write-Log "  Container '$($armContainer.Name)': Erro ao obter política - $($_.Exception.Message)" "WARN"
                }
            }

            # Verificar Legal Hold
            if ($armContainer.HasLegalHold) {
                $containerInfo.LegalHoldTags = $armContainer.LegalHold.Tags | ForEach-Object { $_.Tag }
                Write-Log "  Container '$($armContainer.Name)': Legal Hold ativo (Tags: $($containerInfo.LegalHoldTags -join ', '))" "WARN"
            }

            $script:ContainerResults.Add($containerInfo)

            # Adicionar à lista de containers para processar blobs
            if ($armContainer.HasImmutabilityPolicy -or $armContainer.ImmutableStorageWithVersioning) {
                $containersToProcess += $armContainer.Name
            }
            else {
                # Mesmo sem política no container, blobs individuais podem ter políticas (version-level)
                $containersToProcess += $armContainer.Name
            }
        }
    }
    catch {
        Write-Log "Erro ao listar containers para $AccountName : $($_.Exception.Message)" "ERROR"
        $script:Stats.Errors++
    }

    return $containersToProcess
}

function Test-BlobImmutabilityExpired {
    param(
        [Microsoft.WindowsAzure.Commands.Common.Storage.ResourceModel.AzureStorageBlob]$Blob,
        [string]$AccountName,
        [string]$ContainerNameLocal
    )

    $result = [PSCustomObject]@{
        StorageAccount       = $AccountName
        Container            = $ContainerNameLocal
        BlobName             = $Blob.Name
        BlobType             = $Blob.BlobType
        Length               = $Blob.Length
        LengthFormatted      = Format-FileSize $Blob.Length
        LastModified         = $Blob.LastModified
        AccessTier           = $Blob.AccessTier
        ImmutabilityExpiresOn = $null
        ImmutabilityMode     = $null
        HasLegalHold         = $false
        Status               = "Unknown"
        DaysExpired          = 0
        Eligible             = $false
        Action               = "None"
    }

    try {
        # Verificar política de imutabilidade do blob
        $immutabilityPolicy = $Blob.BlobProperties.ImmutabilityPolicy

        if ($null -ne $immutabilityPolicy -and $null -ne $immutabilityPolicy.ExpiresOn) {
            $result.ImmutabilityExpiresOn = $immutabilityPolicy.ExpiresOn
            $result.ImmutabilityMode = $immutabilityPolicy.PolicyMode

            $expiresOn = [DateTimeOffset]$immutabilityPolicy.ExpiresOn

            if ($expiresOn -lt $script:Now) {
                # Política expirada
                $daysExpired = [math]::Floor(($script:Now - $expiresOn).TotalDays)
                $result.DaysExpired = $daysExpired
                $result.Status = "Expired"

                if ($MaxDaysExpired -gt 0 -and $daysExpired -lt $MaxDaysExpired) {
                    $result.Eligible = $false
                    $result.Action = "SkippedMinDays"
                }
                else {
                    $result.Eligible = $true
                    $script:Stats.BlobsWithExpiredPolicy++
                    $script:Stats.BytesEligible += $Blob.Length
                }
            }
            else {
                # Política ainda ativa
                $result.Status = "Active"
                $result.DaysExpired = 0
                $script:Stats.BlobsWithActivePolicy++
            }
        }
        else {
            $result.Status = "NoPolicy"
        }

        # Verificar Legal Hold no blob
        if ($Blob.BlobProperties.HasLegalHold) {
            $result.HasLegalHold = $true
            $result.Eligible = $false
            $result.Action = "LegalHoldActive"
            $script:Stats.BlobsWithLegalHold++
        }
    }
    catch {
        $result.Status = "Error"
        $result.Action = "ErrorChecking: $($_.Exception.Message)"
        $script:Stats.Errors++
    }

    return $result
}

function Invoke-BlobAction {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [PSCustomObject]$BlobInfo,
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.IStorageContext]$StorageContext
    )

    if (-not $BlobInfo.Eligible) { return }

    if ($BlobInfo.HasLegalHold) {
        Write-Log "    SKIP: '$($BlobInfo.BlobName)' - Legal Hold ativo (requer remoção manual)" "WARN"
        $BlobInfo.Action = "SkippedLegalHold"
        return
    }

    # Modo DryRun
    if ($DryRun -or (-not $RemoveBlobs -and -not $RemoveImmutabilityPolicyOnly)) {
        $BlobInfo.Action = "DryRun"
        Write-Log "    DRYRUN: '$($BlobInfo.BlobName)' - Expirado há $($BlobInfo.DaysExpired) dias ($($BlobInfo.LengthFormatted))" "INFO"
        return
    }

    # Remover apenas a política de imutabilidade
    if ($RemoveImmutabilityPolicyOnly) {
        try {
            if ($PSCmdlet.ShouldProcess($BlobInfo.BlobName, "Remover política de imutabilidade")) {
                Remove-AzStorageBlobImmutabilityPolicy `
                    -Container $BlobInfo.Container `
                    -Blob $BlobInfo.BlobName `
                    -Context $StorageContext

                $BlobInfo.Action = "PolicyRemoved"
                $script:Stats.PoliciesRemoved++
                Write-Log "    REMOVED POLICY: '$($BlobInfo.BlobName)'" "SUCCESS"
            }
        }
        catch {
            $BlobInfo.Action = "ErrorRemovingPolicy: $($_.Exception.Message)"
            $script:Stats.Errors++
            Write-Log "    ERROR: Falha ao remover política de '$($BlobInfo.BlobName)': $($_.Exception.Message)" "ERROR"
        }
        return
    }

    # Remover blob completo
    if ($RemoveBlobs) {
        try {
            if ($PSCmdlet.ShouldProcess($BlobInfo.BlobName, "Remover blob com imutabilidade vencida")) {
                # Primeiro, remover a política de imutabilidade (se existir e estiver unlocked)
                if ($BlobInfo.ImmutabilityMode -eq "Unlocked") {
                    Remove-AzStorageBlobImmutabilityPolicy `
                        -Container $BlobInfo.Container `
                        -Blob $BlobInfo.BlobName `
                        -Context $StorageContext
                    $script:Stats.PoliciesRemoved++
                }

                Remove-AzStorageBlob `
                    -Container $BlobInfo.Container `
                    -Blob $BlobInfo.BlobName `
                    -Context $StorageContext `
                    -Force

                $BlobInfo.Action = "BlobRemoved"
                $script:Stats.BlobsRemoved++
                Write-Log "    REMOVED: '$($BlobInfo.BlobName)' ($($BlobInfo.LengthFormatted))" "SUCCESS"
            }
        }
        catch {
            $BlobInfo.Action = "ErrorRemoving: $($_.Exception.Message)"
            $script:Stats.Errors++
            Write-Log "    ERROR: Falha ao remover '$($BlobInfo.BlobName)': $($_.Exception.Message)" "ERROR"
        }
    }
}

function Export-HtmlReport {
    param([string]$Path)

    $duration = (Get-Date) - $script:StartTime
    $modeLabel = if ($RemoveBlobs) { "REMOÇÃO" } elseif ($RemoveImmutabilityPolicyOnly) { "REMOÇÃO DE POLÍTICAS" } else { "SIMULAÇÃO (DryRun)" }

    $expiredBlobs = $script:Results | Where-Object { $_.Status -eq "Expired" }
    $legalHoldBlobs = $script:Results | Where-Object { $_.HasLegalHold -eq $true }

    $html = @"
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <title>Relatório - Blobs com Imutabilidade Vencida</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: #f5f5f5; color: #333; padding: 20px; }
        .header { background: linear-gradient(135deg, #0078d4, #005a9e); color: white; padding: 30px; border-radius: 8px; margin-bottom: 20px; }
        .header h1 { font-size: 24px; margin-bottom: 8px; }
        .header p { opacity: 0.9; font-size: 14px; }
        .mode-badge { display: inline-block; padding: 4px 12px; border-radius: 12px; font-size: 12px; font-weight: 600; margin-top: 8px; }
        .mode-dryrun { background: #fff3cd; color: #856404; }
        .mode-remove { background: #f8d7da; color: #721c24; }
        .stats-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; margin-bottom: 20px; }
        .stat-card { background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .stat-card .value { font-size: 28px; font-weight: 700; color: #0078d4; }
        .stat-card .label { font-size: 13px; color: #666; margin-top: 4px; }
        .stat-card.warning .value { color: #e74c3c; }
        .stat-card.success .value { color: #27ae60; }
        .section { background: white; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); margin-bottom: 20px; overflow: hidden; }
        .section h2 { padding: 16px 20px; background: #f8f9fa; border-bottom: 1px solid #dee2e6; font-size: 16px; }
        table { width: 100%; border-collapse: collapse; font-size: 13px; }
        th { background: #e9ecef; padding: 10px 12px; text-align: left; font-weight: 600; position: sticky; top: 0; }
        td { padding: 8px 12px; border-bottom: 1px solid #f0f0f0; }
        tr:hover { background: #f8f9fa; }
        .status-expired { color: #e74c3c; font-weight: 600; }
        .status-active { color: #27ae60; font-weight: 600; }
        .status-legalhold { color: #f39c12; font-weight: 600; }
        .action-removed { color: #e74c3c; }
        .action-dryrun { color: #3498db; }
        .action-skipped { color: #95a5a6; }
        .footer { text-align: center; padding: 20px; color: #999; font-size: 12px; }
        .scrollable { max-height: 600px; overflow-y: auto; }
    </style>
</head>
<body>
    <div class="header">
        <h1>Relatório de Blobs com Imutabilidade Vencida</h1>
        <p>Gerado em: $($script:StartTime.ToString("dd/MM/yyyy HH:mm:ss")) | Duração: $($duration.ToString("hh\:mm\:ss"))</p>
        <span class="mode-badge $(if ($RemoveBlobs -or $RemoveImmutabilityPolicyOnly) { 'mode-remove' } else { 'mode-dryrun' })">$modeLabel</span>
    </div>

    <div class="stats-grid">
        <div class="stat-card">
            <div class="value">$($script:Stats.StorageAccountsScanned)</div>
            <div class="label">Storage Accounts Analisadas</div>
        </div>
        <div class="stat-card">
            <div class="value">$($script:Stats.ContainersScanned)</div>
            <div class="label">Containers Analisados</div>
        </div>
        <div class="stat-card">
            <div class="value">$($script:Stats.BlobsScanned)</div>
            <div class="label">Blobs Analisados</div>
        </div>
        <div class="stat-card warning">
            <div class="value">$($script:Stats.BlobsWithExpiredPolicy)</div>
            <div class="label">Blobs com Imutabilidade Vencida</div>
        </div>
        <div class="stat-card success">
            <div class="value">$($script:Stats.BlobsWithActivePolicy)</div>
            <div class="label">Blobs com Imutabilidade Ativa</div>
        </div>
        <div class="stat-card">
            <div class="value">$($script:Stats.BlobsWithLegalHold)</div>
            <div class="label">Blobs com Legal Hold</div>
        </div>
        <div class="stat-card warning">
            <div class="value">$(Format-FileSize $script:Stats.BytesEligible)</div>
            <div class="label">Espaço Elegível para Remoção</div>
        </div>
        <div class="stat-card">
            <div class="value">$($script:Stats.BlobsRemoved + $script:Stats.PoliciesRemoved)</div>
            <div class="label">Ações Executadas</div>
        </div>
    </div>

    <div class="section">
        <h2>Resumo de Containers ($($script:ContainerResults.Count))</h2>
        <div class="scrollable">
            <table>
                <thead>
                    <tr>
                        <th>Container</th>
                        <th>Política de Imutabilidade</th>
                        <th>Estado</th>
                        <th>Retenção (dias)</th>
                        <th>Legal Hold</th>
                    </tr>
                </thead>
                <tbody>
                    $(foreach ($c in $script:ContainerResults) {
                        "<tr>"
                        "<td>$($c.Name)</td>"
                        "<td>$(if ($c.HasImmutabilityPolicy) { 'Sim' } else { 'Não' })</td>"
                        "<td>$($c.ImmutabilityPolicyState ?? '-')</td>"
                        "<td>$($c.RetentionDays ?? '-')</td>"
                        "<td>$(if ($c.HasLegalHold) { "<span class='status-legalhold'>Sim ($($c.LegalHoldTags -join ', '))</span>" } else { 'Não' })</td>"
                        "</tr>"
                    })
                </tbody>
            </table>
        </div>
    </div>

    $(if ($expiredBlobs.Count -gt 0) {
    @"
    <div class="section">
        <h2>Blobs com Imutabilidade Vencida ($($expiredBlobs.Count))</h2>
        <div class="scrollable">
            <table>
                <thead>
                    <tr>
                        <th>Storage Account</th>
                        <th>Container</th>
                        <th>Blob</th>
                        <th>Tamanho</th>
                        <th>Expirou Em</th>
                        <th>Dias Expirado</th>
                        <th>Modo</th>
                        <th>Ação</th>
                    </tr>
                </thead>
                <tbody>
                    $(foreach ($b in $expiredBlobs) {
                        $actionClass = switch -Wildcard ($b.Action) {
                            "DryRun"    { "action-dryrun" }
                            "*Removed*" { "action-removed" }
                            "Skipped*"  { "action-skipped" }
                            default     { "" }
                        }
                        "<tr>"
                        "<td>$($b.StorageAccount)</td>"
                        "<td>$($b.Container)</td>"
                        "<td title='$($b.BlobName)'>$($b.BlobName.Length -gt 60 ? $b.BlobName.Substring(0,57) + '...' : $b.BlobName)</td>"
                        "<td>$($b.LengthFormatted)</td>"
                        "<td>$($b.ImmutabilityExpiresOn?.ToString('dd/MM/yyyy HH:mm'))</td>"
                        "<td class='status-expired'>$($b.DaysExpired)</td>"
                        "<td>$($b.ImmutabilityMode)</td>"
                        "<td class='$actionClass'>$($b.Action)</td>"
                        "</tr>"
                    })
                </tbody>
            </table>
        </div>
    </div>
"@
    })

    $(if ($legalHoldBlobs.Count -gt 0) {
    @"
    <div class="section">
        <h2>Blobs com Legal Hold ($($legalHoldBlobs.Count))</h2>
        <div class="scrollable">
            <table>
                <thead>
                    <tr>
                        <th>Storage Account</th>
                        <th>Container</th>
                        <th>Blob</th>
                        <th>Tamanho</th>
                        <th>Última Modificação</th>
                    </tr>
                </thead>
                <tbody>
                    $(foreach ($b in $legalHoldBlobs) {
                        "<tr>"
                        "<td>$($b.StorageAccount)</td>"
                        "<td>$($b.Container)</td>"
                        "<td>$($b.BlobName)</td>"
                        "<td>$($b.LengthFormatted)</td>"
                        "<td>$($b.LastModified?.ToString('dd/MM/yyyy HH:mm'))</td>"
                        "</tr>"
                    })
                </tbody>
            </table>
        </div>
    </div>
"@
    })

    <div class="footer">
        <p>M365 Security Toolkit - Remove-ExpiredImmutableBlobs v$($script:ScriptVersion)</p>
    </div>
</body>
</html>
"@

    $html | Out-File -FilePath $Path -Encoding utf8
    Write-Log "Relatório HTML salvo em: $Path" "SUCCESS"
}

function Export-CsvReport {
    param([string]$Path)

    $script:Results | Where-Object { $_.Status -ne "NoPolicy" } | Select-Object `
        StorageAccount,
        Container,
        BlobName,
        BlobType,
        LengthFormatted,
        @{N='ImmutabilityExpiresOn';E={$_.ImmutabilityExpiresOn?.ToString('yyyy-MM-dd HH:mm:ss')}},
        ImmutabilityMode,
        HasLegalHold,
        Status,
        DaysExpired,
        Eligible,
        Action |
        Export-Csv -Path $Path -NoTypeInformation -Encoding utf8

    Write-Log "Relatório CSV salvo em: $Path" "SUCCESS"
}

# ============================================================================
# EXECUÇÃO PRINCIPAL
# ============================================================================

function Start-ImmutabilityAudit {

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  Azure Blob Storage - Immutability Expiration Audit" -ForegroundColor Cyan
    Write-Host "  Versão: $($script:ScriptVersion)" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""

    # Determinar modo de operação
    $mode = if ($RemoveBlobs) { "REMOÇÃO DE BLOBS" }
            elseif ($RemoveImmutabilityPolicyOnly) { "REMOÇÃO DE POLÍTICAS" }
            else { "SIMULAÇÃO (DryRun)" }

    Write-Log "Modo de operação: $mode" "SECTION"

    if ($VerboseProgress) {
        Write-Log "Modo verbose ATIVADO - progresso detalhado em tempo real" "INFO"
    }

    if ($MaxDaysExpired -gt 0) {
        Write-Log "Filtro: apenas blobs expirados há mais de $MaxDaysExpired dias" "INFO"
    }

    if ($MinAccountSizeTB -gt 0) {
        Write-Log "Filtro destrutivo por tamanho: apenas contas com $MinAccountSizeTB TB ou mais" "INFO"
    }

    # Confirmação para modos destrutivos
    if ($RemoveBlobs -or $RemoveImmutabilityPolicyOnly) {
        Write-Host ""
        Write-Host "  ATENÇÃO: Este script irá executar ações destrutivas!" -ForegroundColor Red
        Write-Host "  Modo: $mode" -ForegroundColor Red
        Write-Host ""
        $confirmation = Read-Host "  Digite 'CONFIRMAR' para prosseguir"
        if ($confirmation -ne 'CONFIRMAR') {
            Write-Log "Operação cancelada pelo usuário." "WARN"
            return
        }
        Write-Host ""
    }

    # Verificar conexão Azure
    if (-not (Test-AzureConnection)) {
        Write-Log "Não foi possível conectar ao Azure. Abortando." "ERROR"
        return
    }

    # Criar diretório de saída
    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    # Obter Storage Accounts
    $storageAccounts = Get-TargetStorageAccounts

    if ($storageAccounts.Count -eq 0) {
        Write-Log "Nenhuma Storage Account encontrada com os filtros aplicados." "WARN"
        return
    }

    # Processar cada Storage Account
    $totalAccounts = @($storageAccounts).Count
    $accountIndex = 0

    foreach ($account in $storageAccounts) {
        $script:Stats.StorageAccountsScanned++
        $accountIndex++
        $accountName = $account.StorageAccountName
        $accountRG = $account.ResourceGroupName
        $accountStartTime = Get-Date
        $accountBlobsScanned = 0
        $accountBytesScanned = 0
        $accountEligibleBytes = 0
        $accountEligibleQueue = [System.Collections.Generic.List[PSCustomObject]]::new()

        Write-Log "Processando Storage Account: $accountName (RG: $accountRG)" "SECTION"
        Show-Progress -Activity "Analisando Storage Accounts" `
            -Status "[$accountIndex/$totalAccounts] $accountName" `
            -PercentComplete (($accountIndex - 1) / $totalAccounts * 100) `
            -CurrentOperation "Iniciando análise..."

        try {
            # Obter contexto de storage
            $storageContext = $account.Context

            if (-not $storageContext) {
                $keys = Get-AzStorageAccountKey -ResourceGroupName $accountRG -Name $accountName
                $storageContext = New-AzStorageContext -StorageAccountName $accountName -StorageAccountKey $keys[0].Value
            }

            # Analisar containers
            $containersToProcess = Get-ContainerImmutabilityInfo `
                -AccountName $accountName `
                -AccountResourceGroup $accountRG `
                -StorageContext $storageContext

            # Processar blobs em cada container
            $totalContainers = @($containersToProcess).Count
            $containerIndex = 0

            foreach ($containerNameItem in $containersToProcess) {
                $containerIndex++
                $containerStartTime = Get-Date
                $containerBlobCount = 0
                $containerExpiredCount = 0
                $containerBytesScanned = 0

                Write-Log "  Analisando blobs no container: $containerNameItem" "INFO"
                Write-VerboseLog "  Container [$containerIndex/$totalContainers]: $containerNameItem" "INFO"

                Show-Progress -Activity "Analisando Storage Accounts" `
                    -Status "[$accountIndex/$totalAccounts] $accountName" `
                    -PercentComplete (($accountIndex - 1) / $totalAccounts * 100) `
                    -CurrentOperation "Container [$containerIndex/$totalContainers]: $containerNameItem - Listando blobs..."

                try {
                    $blobParams = @{
                        Container = $containerNameItem
                        Context   = $storageContext
                    }

                    if ($IncludeSoftDeleted) {
                        $blobParams['IncludeDeleted'] = $true
                    }

                    # Incluir versões para version-level immutability
                    $blobParams['IncludeVersion'] = $true

                    # FASE 1: Coletar todos os blobs que precisam de ação
                    # Importante: Não removemos durante a iteração para evitar loop infinito
                    Write-VerboseLog "  Container '$containerNameItem': Coletando lista de blobs..." "INFO"
                    
                    $blobIndex = 0
                    $allBlobs = @()
                    
                    try {
                        # Obter todos os blobs do container (paginação automática pelo cmdlet)
                        $allBlobs = Get-AzStorageBlob @blobParams
                        $blobIndex = @($allBlobs).Count
                        
                        Write-VerboseLog "  Container '$containerNameItem': $blobIndex blob(s) encontrado(s)" "INFO"
                    }
                    catch {
                        Write-Log "  Erro ao listar blobs do container '$containerNameItem': $($_.Exception.Message)" "ERROR"
                        $script:Stats.Errors++
                        continue
                    }

                    # FASE 2: Processar e coletar blobs elegíveis
                    $blobsToProcess = [System.Collections.Generic.List[PSCustomObject]]::new()
                    $processIndex = 0

                    foreach ($blob in $allBlobs) {
                        $processIndex++
                        $script:Stats.BlobsScanned++
                        $script:Stats.BytesScanned += $blob.Length
                        $accountBlobsScanned++
                        $accountBytesScanned += $blob.Length
                        $containerBlobCount++
                        $containerBytesScanned += $blob.Length

                        # Atualizar barra de progresso a cada 100 blobs
                        if ($VerboseProgress -and ($processIndex % 100 -eq 0 -or $processIndex -eq 1)) {
                            $throughput = Get-Throughput -Count $processIndex -Since $containerStartTime
                            $elapsed = Get-ElapsedFormatted -Since $containerStartTime

                            Show-Progress -Activity "Analisando Storage Accounts" `
                                -Status "[$accountIndex/$totalAccounts] $accountName | Container [$containerIndex/$totalContainers]: $containerNameItem" `
                                -PercentComplete (($processIndex / $blobIndex) * 100) `
                                -CurrentOperation "Analisando blob $processIndex/$blobIndex | $throughput | Elapsed: $elapsed | Expirados: $containerExpiredCount | Tamanho: $(Format-FileSize $containerBytesScanned)"
                        }

                        $blobResult = Test-BlobImmutabilityExpired `
                            -Blob $blob `
                            -AccountName $accountName `
                            -ContainerNameLocal $containerNameItem

                        # Log verbose de cada blob com política
                        if ($VerboseProgress -and $blobResult.Status -ne "NoPolicy") {
                            $statusIcon = switch ($blobResult.Status) {
                                "Expired" { "EXPIRED" }
                                "Active"  { "ACTIVE" }
                                default   { $blobResult.Status }
                            }
                            $blobShortName = if ($blob.Name.Length -gt 80) { $blob.Name.Substring(0,77) + "..." } else { $blob.Name }
                            Write-VerboseLog "    [$statusIcon] $blobShortName ($(Format-FileSize $blob.Length))$(if ($blobResult.DaysExpired -gt 0) { " | Expirado há $($blobResult.DaysExpired) dias" })" $(if ($blobResult.Status -eq "Expired") { "WARN" } else { "INFO" })
                        }

                        if ($blobResult.Status -eq "Expired") {
                            $containerExpiredCount++
                        }

                        # Coletar blobs elegíveis para processamento posterior
                        if ($blobResult.Eligible) {
                            $accountEligibleBytes += $blob.Length

                            if (($RemoveBlobs -or $RemoveImmutabilityPolicyOnly) -and $MinAccountSizeTB -gt 0) {
                                $blobResult.Action = "PendingThreshold"
                                $accountEligibleQueue.Add($blobResult)
                            }
                            else {
                                # Em modo destrutivo, coletar para processar depois
                                if ($RemoveBlobs -or $RemoveImmutabilityPolicyOnly) {
                                    $blobsToProcess.Add($blobResult)
                                }
                                else {
                                    # DryRun - apenas marcar
                                    $blobResult.Action = "DryRun"
                                    Write-Log "    DRYRUN: '$($blobResult.BlobName)' - Expirado há $($blobResult.DaysExpired) dias ($($blobResult.LengthFormatted))" "INFO"
                                }
                            }
                        }

                        # Adicionar ao resultado (apenas blobs com política)
                        if ($blobResult.Status -ne "NoPolicy") {
                            $script:Results.Add($blobResult)
                        }
                    }

                    # FASE 3: Executar ações nos blobs coletados (apenas em modo destrutivo)
                    if ($blobsToProcess.Count -gt 0) {
                        Write-Log "  Executando ações em $($blobsToProcess.Count) blob(s) do container '$containerNameItem'..." "WARN"
                        
                        $actionIndex = 0
                        foreach ($blobToProcess in $blobsToProcess) {
                            $actionIndex++
                            
                            if ($VerboseProgress -and ($actionIndex % 10 -eq 0 -or $actionIndex -eq 1)) {
                                Show-Progress -Activity "Executando ações" `
                                    -Status "Container: $containerNameItem" `
                                    -PercentComplete (($actionIndex / $blobsToProcess.Count) * 100) `
                                    -CurrentOperation "Processando blob $actionIndex/$($blobsToProcess.Count)"
                            }
                            
                            Invoke-BlobAction -BlobInfo $blobToProcess -StorageContext $storageContext
                        }
                    }

                    Write-VerboseLog "  Container '$containerNameItem': Análise completa - $containerBlobCount blob(s) processado(s)" "SUCCESS"

                    # Resumo do container (verbose)
                    if ($VerboseProgress) {
                        $containerDuration = (Get-Date) - $containerStartTime
                        $throughputFinal = Get-Throughput -Count $containerBlobCount -Since $containerStartTime
                        Write-Log "  Resumo '$containerNameItem': $containerBlobCount blobs | $(Format-FileSize $containerBytesScanned) | $containerExpiredCount expirado(s) | $throughputFinal | Dur: $($containerDuration.ToString('hh\:mm\:ss'))" "INFO"
                    }
                }
                catch {
                    Write-Log "  Erro ao processar container '$containerNameItem': $($_.Exception.Message)" "ERROR"
                    $script:Stats.Errors++
                }
            }

            if (($RemoveBlobs -or $RemoveImmutabilityPolicyOnly) -and $MinAccountSizeTB -gt 0) {
                $thresholdBytes = [long]$MinAccountSizeTB * 1TB

                if ($accountBytesScanned -ge $thresholdBytes) {
                    Write-Log "Conta '$accountName' qualificada para ação destrutiva: $(Format-FileSize $accountBytesScanned) analisados (limiar: $MinAccountSizeTB TB)." "WARN"

                    foreach ($queuedBlob in $accountEligibleQueue) {
                        Invoke-BlobAction -BlobInfo $queuedBlob -StorageContext $storageContext
                    }
                }
                else {
                    Write-Log "Conta '$accountName' abaixo do limiar ($MinAccountSizeTB TB): $(Format-FileSize $accountBytesScanned). Nenhuma ação destrutiva será executada." "INFO"

                    foreach ($queuedBlob in $accountEligibleQueue) {
                        $queuedBlob.Action = "SkippedBelowThreshold"
                    }
                }
            }

            # Resumo da Storage Account (verbose)
            if ($VerboseProgress) {
                $accountDuration = (Get-Date) - $accountStartTime
                Write-Log "Resumo '$accountName': $accountBlobsScanned blobs total | $(Format-FileSize $accountBytesScanned) | Elegível: $(Format-FileSize $accountEligibleBytes) | Dur: $($accountDuration.ToString('hh\:mm\:ss'))" "SUCCESS"
            }
        }
        catch {
            Write-Log "Erro ao processar Storage Account '$accountName': $($_.Exception.Message)" "ERROR"
            $script:Stats.Errors++
        }
    }

    # Limpar barra de progresso
    if ($VerboseProgress) {
        Write-Progress -Activity "Analisando Storage Accounts" -Completed
    }

    # Gerar relatórios
    Write-Log "Gerando relatórios..." "SECTION"

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $htmlPath = Join-Path $OutputPath "ImmutabilityAudit_$timestamp.html"
    Export-HtmlReport -Path $htmlPath

    if ($ExportCsv) {
        $csvPath = Join-Path $OutputPath "ImmutabilityAudit_$timestamp.csv"
        Export-CsvReport -Path $csvPath
    }

    # Resumo final
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  RESUMO DA EXECUÇÃO" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Log "Storage Accounts analisadas: $($script:Stats.StorageAccountsScanned)" "INFO"
    Write-Log "Containers analisados:       $($script:Stats.ContainersScanned)" "INFO"
    Write-Log "Containers com política:     $($script:Stats.ContainersWithPolicy)" "INFO"
    Write-Log "Blobs analisados:            $($script:Stats.BlobsScanned)" "INFO"
    Write-Log "Blobs com imutab. vencida:   $($script:Stats.BlobsWithExpiredPolicy)" $(if ($script:Stats.BlobsWithExpiredPolicy -gt 0) { "WARN" } else { "SUCCESS" })
    Write-Log "Blobs com imutab. ativa:     $($script:Stats.BlobsWithActivePolicy)" "SUCCESS"
    Write-Log "Blobs com Legal Hold:        $($script:Stats.BlobsWithLegalHold)" $(if ($script:Stats.BlobsWithLegalHold -gt 0) { "WARN" } else { "INFO" })
    Write-Log "Total analisado (bytes):     $(Format-FileSize $script:Stats.BytesScanned)" "INFO"
    Write-Log "Espaço elegível p/ remoção:  $(Format-FileSize $script:Stats.BytesEligible)" "INFO"

    if ($RemoveBlobs) {
        Write-Log "Blobs removidos:             $($script:Stats.BlobsRemoved)" "SUCCESS"
    }
    if ($RemoveImmutabilityPolicyOnly -or $RemoveBlobs) {
        Write-Log "Políticas removidas:         $($script:Stats.PoliciesRemoved)" "SUCCESS"
    }

    Write-Log "Erros encontrados:           $($script:Stats.Errors)" $(if ($script:Stats.Errors -gt 0) { "ERROR" } else { "SUCCESS" })
    Write-Log "Duração total:               $((Get-Date) - $script:StartTime)" "INFO"
    Write-Host ""

    # Retornar objeto com resultados para pipeline
    return [PSCustomObject]@{
        Stats            = $script:Stats
        Results          = $script:Results
        ContainerResults = $script:ContainerResults
        ReportPath       = $htmlPath
    }
}

# Executar
Start-ImmutabilityAudit

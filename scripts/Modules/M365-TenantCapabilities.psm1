<#
.SYNOPSIS
    Módulo de Detecção de Capacidades do Tenant Microsoft 365
.DESCRIPTION
    Detecta automaticamente quais recursos de compliance/segurança estão 
    disponíveis no tenant baseado nas licenças.
    
    Usado pelos scripts:
    - Purview-Audit-PS7.ps1
    - M365-Remediation.ps1
.AUTHOR
    M365 Security Toolkit
.VERSION
    1.0 - Janeiro 2026
#>

# ============================================
# VARIÁVEIS GLOBAIS DO MÓDULO
# ============================================

$Script:TenantCapabilities = $null
$Script:TenantInfo = $null

# ============================================
# FUNÇÕES DE DETECÇÃO
# ============================================

function Test-DLPCapability {
    <#
    .SYNOPSIS
        Testa se DLP está disponível no tenant
    #>
    [CmdletBinding()]
    param()
    
    try {
        $null = Get-DlpCompliancePolicy -ErrorAction Stop -WarningAction SilentlyContinue
        return @{
            Available = $true
            Reason = "DLP disponivel"
            TestMethod = "Get-DlpCompliancePolicy"
        }
    }
    catch {
        $ErrorMsg = $_.Exception.Message
        
        if ($ErrorMsg -match "not licensed|InvalidLicenseException") {
            return @{
                Available = $false
                Reason = "Licenca nao inclui DLP (requer E3/E5 ou Compliance add-on)"
                TestMethod = "Get-DlpCompliancePolicy"
            }
        }
        elseif ($ErrorMsg -match "not recognized|CommandNotFoundException") {
            return @{
                Available = $false
                Reason = "Modulo IPPS nao conectado"
                TestMethod = "Get-DlpCompliancePolicy"
            }
        }
        else {
            return @{
                Available = $false
                Reason = "Erro: $ErrorMsg"
                TestMethod = "Get-DlpCompliancePolicy"
            }
        }
    }
}

function Test-SensitivityLabelsCapability {
    [CmdletBinding()]
    param()
    
    try {
        $Labels = Get-Label -ErrorAction Stop -WarningAction SilentlyContinue
        $LabelCount = if ($Labels) { @($Labels).Count } else { 0 }
        
        return @{
            Available = $true
            Reason = "Sensitivity Labels disponivel ($LabelCount labels configurados)"
            TestMethod = "Get-Label"
            Count = $LabelCount
        }
    }
    catch {
        $ErrorMsg = $_.Exception.Message
        
        if ($ErrorMsg -match "not licensed|InvalidLicenseException|UnauthorizedAccess") {
            return @{
                Available = $false
                Reason = "Licenca nao inclui Sensitivity Labels (requer E3/E5 ou AIP)"
                TestMethod = "Get-Label"
            }
        }
        else {
            return @{
                Available = $false
                Reason = "Erro: $ErrorMsg"
                TestMethod = "Get-Label"
            }
        }
    }
}

function Test-AdvancedAlertsCapability {
    [CmdletBinding()]
    param()
    
    $TestAlertName = "_TenantCapabilityTest_$(Get-Random)"
    
    try {
        $null = New-ProtectionAlert -Name $TestAlertName `
            -Category ThreatManagement `
            -ThreatType Activity `
            -Operation "New-InboxRule" `
            -Description "Teste de capacidade - sera deletado" `
            -AggregationType SimpleAggregation `
            -Threshold 10 `
            -TimeWindow 60 `
            -Severity Low `
            -NotificationEnabled $false `
            -ErrorAction Stop
        
        Remove-ProtectionAlert -Identity $TestAlertName -Confirm:$false -ErrorAction SilentlyContinue
        
        return @{
            Available = $true
            Reason = "Alertas avancados (agregados) disponiveis"
            TestMethod = "New-ProtectionAlert (AggregationType SimpleAggregation)"
        }
    }
    catch {
        $ErrorMsg = $_.Exception.Message
        Remove-ProtectionAlert -Identity $TestAlertName -Confirm:$false -ErrorAction SilentlyContinue
        
        if ($ErrorMsg -match "E5 subscription|NotNewProtectionAggregatedAlertCapableException") {
            return @{
                Available = $false
                Reason = "Alertas avancados requerem E5 (apenas single-event disponiveis)"
                TestMethod = "New-ProtectionAlert (AggregationType SimpleAggregation)"
                BasicAlertsAvailable = $true
            }
        }
        else {
            return @{
                Available = $false
                Reason = "Erro: $ErrorMsg"
                TestMethod = "New-ProtectionAlert"
            }
        }
    }
}

function Test-BasicAlertsCapability {
    [CmdletBinding()]
    param()
    
    $TestAlertName = "_TenantCapabilityTest_Basic_$(Get-Random)"
    
    try {
        $null = New-ProtectionAlert -Name $TestAlertName `
            -Category ThreatManagement `
            -ThreatType Activity `
            -Operation "New-InboxRule" `
            -Description "Teste de capacidade - sera deletado" `
            -AggregationType None `
            -Severity Low `
            -NotificationEnabled $false `
            -ErrorAction Stop
        
        Remove-ProtectionAlert -Identity $TestAlertName -Confirm:$false -ErrorAction SilentlyContinue
        
        return @{
            Available = $true
            Reason = "Alertas basicos (single-event) disponiveis"
            TestMethod = "New-ProtectionAlert (AggregationType None)"
        }
    }
    catch {
        Remove-ProtectionAlert -Identity $TestAlertName -Confirm:$false -ErrorAction SilentlyContinue
        
        return @{
            Available = $false
            Reason = "Alertas customizados nao disponiveis: $($_.Exception.Message)"
            TestMethod = "New-ProtectionAlert (AggregationType None)"
        }
    }
}

function Test-RetentionCapability {
    [CmdletBinding()]
    param()
    
    try {
        $Policies = Get-RetentionCompliancePolicy -ErrorAction Stop -WarningAction SilentlyContinue
        $PolicyCount = if ($Policies) { @($Policies).Count } else { 0 }
        
        return @{
            Available = $true
            Reason = "Retention Policies disponivel ($PolicyCount politicas)"
            TestMethod = "Get-RetentionCompliancePolicy"
            Count = $PolicyCount
        }
    }
    catch {
        $ErrorMsg = $_.Exception.Message
        
        if ($ErrorMsg -match "not licensed|InvalidLicenseException") {
            return @{
                Available = $false
                Reason = "Licenca nao inclui Retention Policies"
                TestMethod = "Get-RetentionCompliancePolicy"
            }
        }
        else {
            return @{
                Available = $false
                Reason = "Erro: $ErrorMsg"
                TestMethod = "Get-RetentionCompliancePolicy"
            }
        }
    }
}

function Test-InsiderRiskCapability {
    [CmdletBinding()]
    param()
    
    try {
        $Policies = Get-InsiderRiskPolicy -ErrorAction Stop -WarningAction SilentlyContinue
        $PolicyCount = if ($Policies) { @($Policies).Count } else { 0 }
        
        return @{
            Available = $true
            Reason = "Insider Risk Management disponivel ($PolicyCount politicas)"
            TestMethod = "Get-InsiderRiskPolicy"
            Count = $PolicyCount
        }
    }
    catch {
        $ErrorMsg = $_.Exception.Message
        
        if ($ErrorMsg -match "not licensed|InvalidLicenseException|not recognized") {
            return @{
                Available = $false
                Reason = "Licenca nao inclui Insider Risk (requer E5 ou IRM add-on)"
                TestMethod = "Get-InsiderRiskPolicy"
            }
        }
        else {
            return @{
                Available = $true
                Reason = "Insider Risk disponivel (sem politicas)"
                TestMethod = "Get-InsiderRiskPolicy"
                Count = 0
            }
        }
    }
}

function Test-eDiscoveryCapability {
    [CmdletBinding()]
    param()
    
    try {
        $Cases = Get-ComplianceCase -ErrorAction Stop -WarningAction SilentlyContinue
        $CaseCount = if ($Cases) { @($Cases).Count } else { 0 }
        
        $PremiumAvailable = $false
        try {
            $null = Get-ComplianceCase -CaseType AdvancedEdiscovery -ErrorAction Stop
            $PremiumAvailable = $true
        }
        catch {
            $PremiumAvailable = $false
        }
        
        return @{
            Available = $true
            Reason = "eDiscovery disponivel ($CaseCount cases)"
            TestMethod = "Get-ComplianceCase"
            Count = $CaseCount
            PremiumAvailable = $PremiumAvailable
        }
    }
    catch {
        return @{
            Available = $false
            Reason = "eDiscovery nao disponivel: $($_.Exception.Message)"
            TestMethod = "Get-ComplianceCase"
        }
    }
}

function Test-CommunicationComplianceCapability {
    [CmdletBinding()]
    param()
    
    try {
        $Policies = Get-SupervisoryReviewPolicyV2 -ErrorAction Stop -WarningAction SilentlyContinue
        $PolicyCount = if ($Policies) { @($Policies).Count } else { 0 }
        
        return @{
            Available = $true
            Reason = "Communication Compliance disponivel ($PolicyCount politicas)"
            TestMethod = "Get-SupervisoryReviewPolicyV2"
            Count = $PolicyCount
        }
    }
    catch {
        $ErrorMsg = $_.Exception.Message
        
        if ($ErrorMsg -match "not licensed|InvalidLicenseException|not recognized") {
            return @{
                Available = $false
                Reason = "Licenca nao inclui Communication Compliance (requer E5)"
                TestMethod = "Get-SupervisoryReviewPolicyV2"
            }
        }
        else {
            return @{
                Available = $true
                Reason = "Communication Compliance disponivel (sem politicas)"
                TestMethod = "Get-SupervisoryReviewPolicyV2"
                Count = 0
            }
        }
    }
}

function Test-AuditLogCapability {
    [CmdletBinding()]
    param()
    
    try {
        $TestSearch = Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-1) -EndDate (Get-Date) -ResultSize 1 -ErrorAction Stop
        
        return @{
            Available = $true
            Active = ($null -ne $TestSearch)
            Reason = if ($TestSearch) { "Audit Log ativo e funcionando" } else { "Audit Log disponivel (sem atividade recente)" }
            TestMethod = "Search-UnifiedAuditLog"
        }
    }
    catch {
        $ErrorMsg = $_.Exception.Message
        
        if ($ErrorMsg -match "not enabled") {
            return @{
                Available = $true
                Active = $false
                Reason = "Audit Log disponivel mas DESABILITADO"
                TestMethod = "Search-UnifiedAuditLog"
                NeedsActivation = $true
            }
        }
        else {
            return @{
                Available = $false
                Reason = "Erro ao verificar Audit Log: $ErrorMsg"
                TestMethod = "Search-UnifiedAuditLog"
            }
        }
    }
}

# ============================================
# FUNÇÃO PRINCIPAL DE DETECÇÃO
# ============================================

function Get-TenantCapabilities {
    [CmdletBinding()]
    param(
        [switch]$Silent,
        [switch]$SkipAlertTest
    )
    
    try {
        $OrgConfig = Get-OrganizationConfig -ErrorAction Stop
        $TenantName = $OrgConfig.Name
        $TenantDisplayName = $OrgConfig.DisplayName
    }
    catch {
        Write-Warning "Nao foi possivel obter info do tenant. Verifique a conexao."
        return $null
    }
    
    if (-not $Silent) {
        Write-Host ""
        Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "║  🔍 DETECTANDO CAPACIDADES DO TENANT                             ║" -ForegroundColor Cyan
        Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Tenant: $TenantDisplayName" -ForegroundColor White
        Write-Host "  ID:     $TenantName" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  Testando recursos..." -ForegroundColor Gray
    }
    
    $Capabilities = [ordered]@{
        TenantName = $TenantName
        TenantDisplayName = $TenantDisplayName
        DetectionDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        
        AuditLog = Test-AuditLogCapability
        DLP = Test-DLPCapability
        SensitivityLabels = Test-SensitivityLabelsCapability
        Retention = Test-RetentionCapability
        InsiderRisk = Test-InsiderRiskCapability
        eDiscovery = Test-eDiscoveryCapability
        CommunicationCompliance = Test-CommunicationComplianceCapability
    }
    
    if (-not $SkipAlertTest) {
        if (-not $Silent) { Write-Host "  Testando alertas (pode demorar alguns segundos)..." -ForegroundColor Gray }
        $Capabilities.AdvancedAlerts = Test-AdvancedAlertsCapability
        $Capabilities.BasicAlerts = Test-BasicAlertsCapability
    }
    else {
        $Capabilities.AdvancedAlerts = @{ Available = "Nao testado"; Reason = "Teste pulado (SkipAlertTest)" }
        $Capabilities.BasicAlerts = @{ Available = "Nao testado"; Reason = "Teste pulado (SkipAlertTest)" }
    }
    
    $Capabilities.LicenseTier = Get-EstimatedLicenseTier -Capabilities $Capabilities
    
    if (-not $Silent) {
        Show-TenantCapabilities -Capabilities $Capabilities
    }
    
    $Script:TenantCapabilities = $Capabilities
    
    return $Capabilities
}

function Get-EstimatedLicenseTier {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Capabilities
    )
    
    $HasDLP = $Capabilities.DLP.Available -eq $true
    $HasLabels = $Capabilities.SensitivityLabels.Available -eq $true
    $HasAdvancedAlerts = $Capabilities.AdvancedAlerts.Available -eq $true
    $HasInsiderRisk = $Capabilities.InsiderRisk.Available -eq $true
    $HasCommCompliance = $Capabilities.CommunicationCompliance.Available -eq $true
    
    if ($HasDLP -and $HasLabels -and $HasAdvancedAlerts -and $HasInsiderRisk -and $HasCommCompliance) {
        return @{
            Tier = "E5"
            Description = "Microsoft 365 E5 ou equivalente"
            FullCompliance = $true
        }
    }
    
    if ($HasDLP -and $HasLabels -and -not $HasAdvancedAlerts) {
        return @{
            Tier = "E3"
            Description = "Microsoft 365 E3 ou equivalente"
            FullCompliance = $false
        }
    }
    
    if ($HasDLP -and -not $HasAdvancedAlerts) {
        return @{
            Tier = "BusinessPremium"
            Description = "Microsoft 365 Business Premium ou equivalente"
            FullCompliance = $false
        }
    }
    
    return @{
        Tier = "Basic"
        Description = "Microsoft 365 Business Basic/Standard ou equivalente"
        FullCompliance = $false
        LimitedFeatures = $true
    }
}

function Show-TenantCapabilities {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Capabilities
    )
    
    Write-Host ""
    Write-Host "  ┌────────────────────────────────┬───────────┬────────────────────────────────────────┐" -ForegroundColor DarkCyan
    Write-Host "  │ Recurso                        │ Status    │ Detalhes                               │" -ForegroundColor DarkCyan
    Write-Host "  ├────────────────────────────────┼───────────┼────────────────────────────────────────┤" -ForegroundColor DarkCyan
    
    $Resources = @(
        @{ Name = "Unified Audit Log"; Key = "AuditLog" },
        @{ Name = "Data Loss Prevention (DLP)"; Key = "DLP" },
        @{ Name = "Sensitivity Labels"; Key = "SensitivityLabels" },
        @{ Name = "Retention Policies"; Key = "Retention" },
        @{ Name = "Insider Risk Management"; Key = "InsiderRisk" },
        @{ Name = "eDiscovery"; Key = "eDiscovery" },
        @{ Name = "Communication Compliance"; Key = "CommunicationCompliance" },
        @{ Name = "Alertas Avancados"; Key = "AdvancedAlerts" },
        @{ Name = "Alertas Basicos"; Key = "BasicAlerts" }
    )
    
    foreach ($Resource in $Resources) {
        $Cap = $Capabilities[$Resource.Key]
        $Available = $Cap.Available
        
        if ($Available -eq $true) {
            $Status = "   ✅    "
            $StatusColor = "Green"
        }
        elseif ($Available -eq $false) {
            $Status = "   ❌    "
            $StatusColor = "Red"
        }
        else {
            $Status = "   ⚠️     "
            $StatusColor = "Yellow"
        }
        
        $Name = $Resource.Name.PadRight(30)
        $Reason = if ($Cap.Reason.Length -gt 38) { $Cap.Reason.Substring(0, 35) + "..." } else { $Cap.Reason.PadRight(38) }
        
        Write-Host "  │ " -ForegroundColor DarkCyan -NoNewline
        Write-Host $Name -ForegroundColor White -NoNewline
        Write-Host " │" -ForegroundColor DarkCyan -NoNewline
        Write-Host $Status -ForegroundColor $StatusColor -NoNewline
        Write-Host "│ " -ForegroundColor DarkCyan -NoNewline
        Write-Host $Reason -ForegroundColor Gray -NoNewline
        Write-Host " │" -ForegroundColor DarkCyan
    }
    
    Write-Host "  └────────────────────────────────┴───────────┴────────────────────────────────────────┘" -ForegroundColor DarkCyan
    
    $Tier = $Capabilities.LicenseTier
    Write-Host ""
    Write-Host "  📋 Licença Estimada: " -ForegroundColor Cyan -NoNewline
    Write-Host $Tier.Description -ForegroundColor Yellow
    
    if ($Tier.LimitedFeatures) {
        Write-Host ""
        Write-Host "  ⚠️  Este tenant tem recursos limitados de compliance." -ForegroundColor Yellow
        Write-Host "     Alguns itens da auditoria/remediacao serao ignorados." -ForegroundColor Gray
    }
    
    Write-Host ""
}

function Get-AvailableRemediations {
    [CmdletBinding()]
    param(
        [hashtable]$Capabilities = $Script:TenantCapabilities
    )
    
    if (-not $Capabilities) {
        Write-Warning "Execute Get-TenantCapabilities primeiro"
        return $null
    }
    
    $Available = @()
    
    if ($Capabilities.AuditLog.Available) {
        $Available += @{
            Name = "UnifiedAuditLog"
            Description = "Ativar/verificar Unified Audit Log"
            Function = "Remediate-UnifiedAuditLog"
        }
    }
    
    if ($Capabilities.Retention.Available) {
        $Available += @{
            Name = "RetentionPolicies"
            Description = "Criar politicas de retencao"
            Function = "Remediate-RetentionPolicies"
        }
    }
    
    if ($Capabilities.DLP.Available) {
        $Available += @{
            Name = "DLPPolicies"
            Description = "Criar politicas DLP"
            Function = "Remediate-DLPPolicies"
        }
    }
    
    if ($Capabilities.BasicAlerts.Available -or $Capabilities.AdvancedAlerts.Available) {
        $AlertType = if ($Capabilities.AdvancedAlerts.Available) { "avancados" } else { "basicos" }
        $Available += @{
            Name = "AlertPolicies"
            Description = "Criar alertas de seguranca ($AlertType)"
            Function = "Remediate-AlertPolicies"
            AlertType = $AlertType
        }
    }
    
    return $Available
}

function Get-AvailableAudits {
    [CmdletBinding()]
    param(
        [hashtable]$Capabilities = $Script:TenantCapabilities
    )
    
    if (-not $Capabilities) {
        Write-Warning "Execute Get-TenantCapabilities primeiro"
        return $null
    }
    
    $Available = @()
    
    $Available += @{ Name = "AuditLog"; Weight = 15 }
    
    if ($Capabilities.Retention.Available) {
        $Available += @{ Name = "Retention"; Weight = 15 }
    }
    
    if ($Capabilities.DLP.Available) {
        $Available += @{ Name = "DLP"; Weight = 15 }
    }
    
    if ($Capabilities.SensitivityLabels.Available) {
        $Available += @{ Name = "SensitivityLabels"; Weight = 10 }
    }
    
    $Available += @{ Name = "AlertPolicies"; Weight = 10 }
    
    if ($Capabilities.InsiderRisk.Available) {
        $Available += @{ Name = "InsiderRisk"; Weight = 10 }
    }
    
    if ($Capabilities.eDiscovery.Available) {
        $Available += @{ Name = "eDiscovery"; Weight = 10 }
    }
    
    $Available += @{ Name = "ExternalSharing"; Weight = 10 }
    
    if ($Capabilities.CommunicationCompliance.Available) {
        $Available += @{ Name = "CommunicationCompliance"; Weight = 5 }
    }
    
    return $Available
}

function Export-TenantCapabilities {
    [CmdletBinding()]
    param(
        [string]$Path = "./TenantCapabilities_$(Get-Date -Format 'yyyyMMdd_HHmmss').json",
        [hashtable]$Capabilities = $Script:TenantCapabilities
    )
    
    if (-not $Capabilities) {
        Write-Warning "Execute Get-TenantCapabilities primeiro"
        return
    }
    
    $Capabilities | ConvertTo-Json -Depth 10 | Out-File $Path -Encoding UTF8
    Write-Host "  📄 Exportado para: $Path" -ForegroundColor Green
    
    return $Path
}

Export-ModuleMember -Function @(
    'Get-TenantCapabilities',
    'Get-AvailableRemediations',
    'Get-AvailableAudits',
    'Export-TenantCapabilities',
    'Show-TenantCapabilities',
    'Test-DLPCapability',
    'Test-SensitivityLabelsCapability',
    'Test-AdvancedAlertsCapability',
    'Test-BasicAlertsCapability',
    'Test-RetentionCapability',
    'Test-InsiderRiskCapability',
    'Test-eDiscoveryCapability',
    'Test-CommunicationComplianceCapability',
    'Test-AuditLogCapability'
)

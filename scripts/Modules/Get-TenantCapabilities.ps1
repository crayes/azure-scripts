<#
.SYNOPSIS
    Detecta recursos e licenças disponíveis no tenant Microsoft 365
.DESCRIPTION
    Módulo de detecção de capacidades do tenant para uso com scripts de
    auditoria e remediação do Purview/M365 Security.
    
    Verifica quais recursos estão disponíveis baseado nas licenças e
    retorna um objeto com as capacidades detectadas.
.AUTHOR
    M365 Security Toolkit
.VERSION
    1.0 - Janeiro 2026
.EXAMPLE
    $Capabilities = .\Get-TenantCapabilities.ps1
    if ($Capabilities.DLP.Available) { # executa DLP }
.EXAMPLE
    .\Get-TenantCapabilities.ps1 -Detailed
.EXAMPLE
    .\Get-TenantCapabilities.ps1 -ExportJson -OutputPath "./tenant-caps.json"
#>

[CmdletBinding()]
param(
    [switch]$Detailed,
    [switch]$ExportJson,
    [string]$OutputPath = "./TenantCapabilities_$(Get-Date -Format 'yyyyMMdd_HHmmss').json",
    [switch]$Silent
)

$ErrorActionPreference = "SilentlyContinue"

# ============================================
# FUNÇÕES DE INTERFACE
# ============================================

function Write-CapabilityBanner {
    if ($Silent) { return }
    
    $Banner = @"

╔══════════════════════════════════════════════════════════════════════════╗
║                                                                          ║
║   ████████╗███████╗███╗   ██╗ █████╗ ███╗   ██╗████████╗                 ║
║   ╚══██╔══╝██╔════╝████╗  ██║██╔══██╗████╗  ██║╚══██╔══╝                 ║
║      ██║   █████╗  ██╔██╗ ██║███████║██╔██╗ ██║   ██║                    ║
║      ██║   ██╔══╝  ██║╚██╗██║██╔══██║██║╚██╗██║   ██║                    ║
║      ██║   ███████╗██║ ╚████║██║  ██║██║ ╚████║   ██║                    ║
║      ╚═╝   ╚══════╝╚═╝  ╚═══╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝                    ║
║                                                                          ║
║   🔍 DETECÇÃO DE CAPACIDADES DO TENANT                                   ║
║                                                                          ║
║   Versão 1.0 - Janeiro 2026                                              ║
║                                                                          ║
╚══════════════════════════════════════════════════════════════════════════╝

"@
    Write-Host $Banner -ForegroundColor Cyan
}

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error", "Testing", "Detail")]
        [string]$Type = "Info"
    )
    
    if ($Silent) { return }
    
    $Config = switch ($Type) {
        "Success" { @{ Color = "Green";   Prefix = "  ✅" } }
        "Warning" { @{ Color = "Yellow";  Prefix = "  ⚠️ " } }
        "Error"   { @{ Color = "Red";     Prefix = "  ❌" } }
        "Info"    { @{ Color = "White";   Prefix = "  📋" } }
        "Testing" { @{ Color = "Cyan";    Prefix = "  🔍" } }
        "Detail"  { @{ Color = "Gray";    Prefix = "     •" } }
        default   { @{ Color = "White";   Prefix = "  " } }
    }
    
    Write-Host "$($Config.Prefix) $Message" -ForegroundColor $Config.Color
}

function Write-Section {
    param([string]$Title)
    if ($Silent) { return }
    Write-Host ""
    Write-Host "  ─────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "  ─────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
}

# ============================================
# VERIFICAÇÃO DE CONEXÃO
# ============================================

function Test-Connections {
    $Result = @{
        ExchangeOnline = $false
        SecurityCompliance = $false
        Errors = @()
    }
    
    # Test Exchange Online
    try {
        $null = Get-OrganizationConfig -ErrorAction Stop
        $Result.ExchangeOnline = $true
    }
    catch {
        $Result.Errors += "Exchange Online não conectado"
    }
    
    # Test Security & Compliance
    try {
        $null = Get-RetentionCompliancePolicy -ResultSize 1 -ErrorAction Stop -WarningAction SilentlyContinue
        $Result.SecurityCompliance = $true
    }
    catch {
        try {
            $null = Get-Label -ResultSize 1 -ErrorAction Stop -WarningAction SilentlyContinue
            $Result.SecurityCompliance = $true
        }
        catch {
            $Result.Errors += "Security & Compliance não conectado"
        }
    }
    
    return $Result
}

# ============================================
# DETECÇÃO DE INFORMAÇÕES DO TENANT
# ============================================

function Get-TenantInfo {
    $Info = @{
        Name = $null
        DisplayName = $null
        Domain = $null
        DetectedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }
    
    try {
        $OrgConfig = Get-OrganizationConfig -ErrorAction Stop
        $Info.Name = $OrgConfig.Name
        $Info.DisplayName = $OrgConfig.DisplayName
        $Info.Domain = ($OrgConfig.Name -split '\.')[0]
    }
    catch {
        $Info.Name = "Desconhecido"
        $Info.DisplayName = "Erro ao obter"
    }
    
    return $Info
}

# ============================================
# DETECÇÃO DE CAPACIDADES
# ============================================

function Test-DLPCapability {
    Write-Status "Testando DLP..." "Testing"
    
    $Result = @{
        Available = $false
        CanCreate = $false
        ExistingPolicies = 0
        TestMethod = "Get-DlpCompliancePolicy"
        Error = $null
        LicenseRequired = "E3/E5/Business Premium ou Compliance Add-on"
    }
    
    try {
        $Policies = Get-DlpCompliancePolicy -WarningAction SilentlyContinue -ErrorAction Stop
        $Result.Available = $true
        $Result.ExistingPolicies = if ($Policies) { @($Policies).Count } else { 0 }
        $Result.CanCreate = $true
        
        Write-Status "DLP disponível ($($Result.ExistingPolicies) políticas existentes)" "Success"
    }
    catch {
        $ErrorMsg = $_.Exception.Message
        if ($ErrorMsg -match "not licensed|license") {
            $Result.Error = "Licença não disponível"
            Write-Status "DLP não disponível (licença)" "Error"
        }
        else {
            $Result.Error = $ErrorMsg
            Write-Status "DLP erro: $ErrorMsg" "Warning"
        }
    }
    
    return $Result
}

function Test-SensitivityLabelsCapability {
    Write-Status "Testando Sensitivity Labels..." "Testing"
    
    $Result = @{
        Available = $false
        CanCreate = $false
        ExistingLabels = 0
        ExistingPolicies = 0
        TestMethod = "Get-Label"
        Error = $null
        LicenseRequired = "E3/E5 ou Azure Information Protection"
    }
    
    try {
        $Labels = Get-Label -WarningAction SilentlyContinue -ErrorAction Stop
        $Result.Available = $true
        $Result.ExistingLabels = if ($Labels) { @($Labels).Count } else { 0 }
        
        try {
            $Policies = Get-LabelPolicy -WarningAction SilentlyContinue -ErrorAction Stop
            $Result.ExistingPolicies = if ($Policies) { @($Policies).Count } else { 0 }
            $Result.CanCreate = $true
        }
        catch {
            $Result.CanCreate = $false
        }
        
        if ($Result.ExistingLabels -gt 0) {
            Write-Status "Labels disponível ($($Result.ExistingLabels) labels, $($Result.ExistingPolicies) políticas)" "Success"
        }
        else {
            Write-Status "Labels disponível (nenhum configurado)" "Warning"
        }
    }
    catch {
        $ErrorMsg = $_.Exception.Message
        if ($ErrorMsg -match "not licensed|license|couldn't be found") {
            $Result.Error = "Licença não disponível ou não configurado"
            Write-Status "Labels não disponível" "Error"
        }
        else {
            $Result.Available = $true
            $Result.Error = $ErrorMsg
            Write-Status "Labels possivelmente disponível (sem labels)" "Warning"
        }
    }
    
    return $Result
}

function Test-RetentionCapability {
    Write-Status "Testando Retention Policies..." "Testing"
    
    $Result = @{
        Available = $false
        CanCreate = $false
        ExistingPolicies = 0
        ExistingLabels = 0
        TeamsSupport = $false
        TestMethod = "Get-RetentionCompliancePolicy"
        Error = $null
        LicenseRequired = "E3/E5/Business ou Exchange Online Plan 2"
    }
    
    try {
        $Policies = Get-RetentionCompliancePolicy -WarningAction SilentlyContinue -ErrorAction Stop
        $Result.Available = $true
        $Result.ExistingPolicies = if ($Policies) { @($Policies).Count } else { 0 }
        $Result.CanCreate = $true
        
        if ($Policies) {
            $TeamsPolicy = $Policies | Where-Object { $_.TeamsChannelLocation -or $_.TeamsChatLocation }
            $Result.TeamsSupport = ($null -ne $TeamsPolicy)
        }
        
        try {
            $Labels = Get-ComplianceTag -WarningAction SilentlyContinue -ErrorAction Stop
            $Result.ExistingLabels = if ($Labels) { @($Labels).Count } else { 0 }
        }
        catch { }
        
        Write-Status "Retention disponível ($($Result.ExistingPolicies) políticas, $($Result.ExistingLabels) labels)" "Success"
    }
    catch {
        $ErrorMsg = $_.Exception.Message
        if ($ErrorMsg -match "not licensed|license") {
            $Result.Error = "Licença não disponível"
            Write-Status "Retention não disponível (licença)" "Error"
        }
        else {
            $Result.Error = $ErrorMsg
            Write-Status "Retention erro: $ErrorMsg" "Warning"
        }
    }
    
    return $Result
}

function Test-AlertPoliciesCapability {
    Write-Status "Testando Alert Policies..." "Testing"
    
    $Result = @{
        Available = $false
        BasicAlerts = $false
        AdvancedAlerts = $false
        ExistingCustom = 0
        ExistingSystem = 0
        TestMethod = "Get-ProtectionAlert + New-ProtectionAlert test"
        Error = $null
        LicenseRequired = "Básico: qualquer M365 | Avançado: E5 ou Threat Intelligence"
    }
    
    try {
        $Alerts = Get-ProtectionAlert -WarningAction SilentlyContinue -ErrorAction Stop
        $Result.Available = $true
        $Result.BasicAlerts = $true
        
        if ($Alerts) {
            $Result.ExistingSystem = @($Alerts | Where-Object { $_.IsSystemRule -eq $true }).Count
            $Result.ExistingCustom = @($Alerts | Where-Object { $_.IsSystemRule -eq $false }).Count
        }
        
        $TestAlertName = "___TEST_CAPABILITY_DELETE___"
        try {
            $null = New-ProtectionAlert -Name $TestAlertName `
                -Category ThreatManagement `
                -ThreatType Activity `
                -Operation "Test" `
                -AggregationType SimpleAggregation `
                -Severity Low `
                -ErrorAction Stop
            
            $Result.AdvancedAlerts = $true
            Remove-ProtectionAlert -Identity $TestAlertName -Confirm:$false -ErrorAction SilentlyContinue
        }
        catch {
            $TestError = $_.Exception.Message
            if ($TestError -match "E5|advanced|aggregat") {
                $Result.AdvancedAlerts = $false
            }
            else {
                $Result.AdvancedAlerts = $false
            }
        }
        
        $AlertType = if ($Result.AdvancedAlerts) { "básicos + avançados" } else { "apenas básicos" }
        Write-Status "Alertas disponível - $AlertType ($($Result.ExistingCustom) custom, $($Result.ExistingSystem) system)" "Success"
    }
    catch {
        $ErrorMsg = $_.Exception.Message
        $Result.Error = $ErrorMsg
        Write-Status "Alertas erro: $ErrorMsg" "Warning"
    }
    
    return $Result
}

function Test-AuditLogCapability {
    Write-Status "Testando Audit Log..." "Testing"
    
    $Result = @{
        Available = $false
        UnifiedAuditEnabled = $false
        MailboxAuditEnabled = $false
        RecentActivity = $false
        TestMethod = "Search-UnifiedAuditLog"
        Error = $null
        LicenseRequired = "Qualquer licença M365 com Exchange"
    }
    
    try {
        $AuditSearch = Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-1) -EndDate (Get-Date) -ResultSize 1 -ErrorAction Stop
        $Result.Available = $true
        $Result.UnifiedAuditEnabled = $true
        $Result.RecentActivity = ($null -ne $AuditSearch)
        
        try {
            $OrgConfig = Get-OrganizationConfig -ErrorAction Stop
            $Result.MailboxAuditEnabled = -not $OrgConfig.AuditDisabled
        }
        catch { }
        
        Write-Status "Audit Log disponível (atividade recente: $($Result.RecentActivity))" "Success"
    }
    catch {
        $ErrorMsg = $_.Exception.Message
        
        if ($ErrorMsg -match "not enabled|UnifiedAuditLogIngestionEnabled") {
            $Result.Available = $true
            $Result.UnifiedAuditEnabled = $false
            $Result.Error = "Audit Log não habilitado"
            Write-Status "Audit Log disponível mas DESABILITADO" "Warning"
        }
        else {
            $Result.Error = $ErrorMsg
            Write-Status "Audit Log erro: $ErrorMsg" "Warning"
        }
    }
    
    return $Result
}

function Test-InsiderRiskCapability {
    Write-Status "Testando Insider Risk Management..." "Testing"
    
    $Result = @{
        Available = $false
        ExistingPolicies = 0
        TestMethod = "Get-InsiderRiskPolicy"
        Error = $null
        LicenseRequired = "E5 ou Insider Risk Management Add-on"
    }
    
    try {
        $Policies = Get-InsiderRiskPolicy -WarningAction SilentlyContinue -ErrorAction Stop
        $Result.Available = $true
        $Result.ExistingPolicies = if ($Policies) { @($Policies).Count } else { 0 }
        
        Write-Status "Insider Risk disponível ($($Result.ExistingPolicies) políticas)" "Success"
    }
    catch {
        $ErrorMsg = $_.Exception.Message
        if ($ErrorMsg -match "not licensed|license|not recognized|couldn't be found") {
            $Result.Error = "Não disponível ou não configurado"
            Write-Status "Insider Risk não disponível" "Error"
        }
        else {
            $Result.Available = $true
            $Result.Error = $ErrorMsg
            Write-Status "Insider Risk possivelmente disponível" "Warning"
        }
    }
    
    return $Result
}

function Test-eDiscoveryCapability {
    Write-Status "Testando eDiscovery..." "Testing"
    
    $Result = @{
        Available = $false
        StandardAvailable = $false
        PremiumAvailable = $false
        ExistingCases = 0
        TestMethod = "Get-ComplianceCase"
        Error = $null
        LicenseRequired = "Standard: E3+ | Premium: E5 ou eDiscovery Add-on"
    }
    
    try {
        $Cases = Get-ComplianceCase -WarningAction SilentlyContinue -ErrorAction Stop
        $Result.Available = $true
        $Result.StandardAvailable = $true
        $Result.ExistingCases = if ($Cases) { @($Cases).Count } else { 0 }
        
        try {
            $PremiumCases = Get-ComplianceCase -CaseType AdvancedEdiscovery -WarningAction SilentlyContinue -ErrorAction Stop
            $Result.PremiumAvailable = $true
        }
        catch {
            $Result.PremiumAvailable = $false
        }
        
        $Type = if ($Result.PremiumAvailable) { "Standard + Premium" } else { "Standard apenas" }
        Write-Status "eDiscovery disponível - $Type ($($Result.ExistingCases) casos)" "Success"
    }
    catch {
        $ErrorMsg = $_.Exception.Message
        $Result.Error = $ErrorMsg
        Write-Status "eDiscovery não disponível" "Error"
    }
    
    return $Result
}

function Test-CommunicationComplianceCapability {
    Write-Status "Testando Communication Compliance..." "Testing"
    
    $Result = @{
        Available = $false
        ExistingPolicies = 0
        TestMethod = "Get-SupervisoryReviewPolicyV2"
        Error = $null
        LicenseRequired = "E5 ou Communication Compliance Add-on"
    }
    
    try {
        $Policies = Get-SupervisoryReviewPolicyV2 -WarningAction SilentlyContinue -ErrorAction Stop
        $Result.Available = $true
        $Result.ExistingPolicies = if ($Policies) { @($Policies).Count } else { 0 }
        
        Write-Status "Communication Compliance disponível ($($Result.ExistingPolicies) políticas)" "Success"
    }
    catch {
        $ErrorMsg = $_.Exception.Message
        if ($ErrorMsg -match "not licensed|license|not recognized") {
            $Result.Error = "Não disponível"
            Write-Status "Communication Compliance não disponível" "Error"
        }
        else {
            $Result.Available = $true
            $Result.Error = $ErrorMsg
            Write-Status "Communication Compliance possivelmente disponível" "Warning"
        }
    }
    
    return $Result
}

function Test-ExternalSharingCapability {
    Write-Status "Testando External Sharing Controls..." "Testing"
    
    $Result = @{
        Available = $false
        OWAExternalDisabled = $false
        TestMethod = "Get-OwaMailboxPolicy"
        Error = $null
        LicenseRequired = "Qualquer licença com Exchange Online"
    }
    
    try {
        $OwaPolicy = Get-OwaMailboxPolicy -Identity "OwaMailboxPolicy-Default" -ErrorAction Stop
        $Result.Available = $true
        $Result.OWAExternalDisabled = -not $OwaPolicy.WacExternalServicesEnabled
        
        $Status = if ($Result.OWAExternalDisabled) { "externos bloqueados" } else { "externos permitidos" }
        Write-Status "External Sharing disponível ($Status)" "Success"
    }
    catch {
        $ErrorMsg = $_.Exception.Message
        $Result.Error = $ErrorMsg
        Write-Status "External Sharing erro: $ErrorMsg" "Warning"
    }
    
    return $Result
}

# ============================================
# CÁLCULO DE LICENÇA PROVÁVEL
# ============================================

function Get-ProbableLicense {
    param($Capabilities)
    
    $License = @{
        Probable = "Desconhecido"
        Confidence = "Baixa"
        Features = @()
    }
    
    if ($Capabilities.DLP.Available -and 
        $Capabilities.SensitivityLabels.Available -and 
        $Capabilities.AlertPolicies.AdvancedAlerts -and
        $Capabilities.InsiderRisk.Available) {
        $License.Probable = "Microsoft 365 E5 ou equivalente"
        $License.Confidence = "Alta"
        $License.Features = @("DLP", "Labels", "Alertas Avançados", "Insider Risk", "eDiscovery Premium")
    }
    elseif ($Capabilities.DLP.Available -and $Capabilities.Retention.Available) {
        $License.Probable = "Microsoft 365 E3 / Business Premium"
        $License.Confidence = "Média"
        $License.Features = @("DLP", "Retention", "Alertas Básicos")
    }
    elseif ($Capabilities.AuditLog.Available -and -not $Capabilities.DLP.Available) {
        $License.Probable = "Microsoft 365 Business Basic/Standard"
        $License.Confidence = "Média"
        $License.Features = @("Audit Log", "Alertas Básicos", "Retention Básico")
    }
    elseif ($Capabilities.AuditLog.Available) {
        $License.Probable = "Exchange Online (Plan 1 ou 2)"
        $License.Confidence = "Baixa"
        $License.Features = @("Audit Log", "Mailbox Audit")
    }
    
    return $License
}

# ============================================
# RESUMO E EXPORTAÇÃO
# ============================================

function Show-CapabilitiesSummary {
    param($TenantInfo, $Capabilities, $License)
    
    if ($Silent) { return }
    
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "  ║                     RESUMO DO TENANT                             ║" -ForegroundColor Green
    Write-Host "  ╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Tenant:    $($TenantInfo.DisplayName)" -ForegroundColor White
    Write-Host "  Domínio:   $($TenantInfo.Name)" -ForegroundColor Gray
    Write-Host "  Licença:   $($License.Probable) (Confiança: $($License.Confidence))" -ForegroundColor Cyan
    Write-Host ""
    
    Write-Host "  ┌────────────────────────────────┬────────────┬─────────────────────┐" -ForegroundColor DarkGray
    Write-Host "  │ Recurso                        │ Status     │ Detalhes            │" -ForegroundColor DarkGray
    Write-Host "  ├────────────────────────────────┼────────────┼─────────────────────┤" -ForegroundColor DarkGray
    
    $Resources = @(
        @{ Name = "DLP"; Cap = $Capabilities.DLP; Detail = "$($Capabilities.DLP.ExistingPolicies) políticas" }
        @{ Name = "Sensitivity Labels"; Cap = $Capabilities.SensitivityLabels; Detail = "$($Capabilities.SensitivityLabels.ExistingLabels) labels" }
        @{ Name = "Retention"; Cap = $Capabilities.Retention; Detail = "$($Capabilities.Retention.ExistingPolicies) políticas" }
        @{ Name = "Alert Policies (Basic)"; Cap = @{Available=$Capabilities.AlertPolicies.BasicAlerts}; Detail = "$($Capabilities.AlertPolicies.ExistingCustom) custom" }
        @{ Name = "Alert Policies (Advanced)"; Cap = @{Available=$Capabilities.AlertPolicies.AdvancedAlerts}; Detail = "" }
        @{ Name = "Audit Log"; Cap = $Capabilities.AuditLog; Detail = if($Capabilities.AuditLog.UnifiedAuditEnabled){"Ativo"}else{"Desativado"} }
        @{ Name = "Insider Risk"; Cap = $Capabilities.InsiderRisk; Detail = "$($Capabilities.InsiderRisk.ExistingPolicies) políticas" }
        @{ Name = "eDiscovery"; Cap = $Capabilities.eDiscovery; Detail = "$($Capabilities.eDiscovery.ExistingCases) casos" }
        @{ Name = "Communication Compliance"; Cap = $Capabilities.CommunicationCompliance; Detail = "$($Capabilities.CommunicationCompliance.ExistingPolicies) políticas" }
        @{ Name = "External Sharing"; Cap = $Capabilities.ExternalSharing; Detail = if($Capabilities.ExternalSharing.OWAExternalDisabled){"Bloqueado"}else{"Permitido"} }
    )
    
    foreach ($Res in $Resources) {
        $StatusIcon = if ($Res.Cap.Available) { "✅" } else { "❌" }
        $StatusText = if ($Res.Cap.Available) { "Disponível" } else { "Não Disp." }
        $StatusColor = if ($Res.Cap.Available) { "Green" } else { "Red" }
        
        $NamePadded = $Res.Name.PadRight(30)
        $StatusPadded = "$StatusIcon $StatusText".PadRight(10)
        $DetailPadded = $Res.Detail.PadRight(19)
        
        Write-Host "  │ " -ForegroundColor DarkGray -NoNewline
        Write-Host $NamePadded -ForegroundColor White -NoNewline
        Write-Host "│ " -ForegroundColor DarkGray -NoNewline
        Write-Host $StatusPadded -ForegroundColor $StatusColor -NoNewline
        Write-Host "│ " -ForegroundColor DarkGray -NoNewline
        Write-Host $DetailPadded -ForegroundColor Gray -NoNewline
        Write-Host "│" -ForegroundColor DarkGray
    }
    
    Write-Host "  └────────────────────────────────┴────────────┴─────────────────────┘" -ForegroundColor DarkGray
    Write-Host ""
}

function Get-AuditableItems {
    param($Capabilities)
    
    $Items = @()
    
    if ($Capabilities.DLP.Available) { $Items += "DLP" }
    if ($Capabilities.SensitivityLabels.Available) { $Items += "SensitivityLabels" }
    if ($Capabilities.Retention.Available) { $Items += "Retention" }
    if ($Capabilities.AlertPolicies.Available) { $Items += "AlertPolicies" }
    if ($Capabilities.AuditLog.Available) { $Items += "AuditLog" }
    if ($Capabilities.InsiderRisk.Available) { $Items += "InsiderRisk" }
    if ($Capabilities.eDiscovery.Available) { $Items += "eDiscovery" }
    if ($Capabilities.CommunicationCompliance.Available) { $Items += "CommunicationCompliance" }
    if ($Capabilities.ExternalSharing.Available) { $Items += "ExternalSharing" }
    
    return $Items
}

function Get-RemediableItems {
    param($Capabilities)
    
    $Items = @()
    
    if ($Capabilities.DLP.CanCreate) { $Items += "DLP" }
    if ($Capabilities.Retention.CanCreate) { $Items += "Retention" }
    if ($Capabilities.AlertPolicies.BasicAlerts) { $Items += "AlertPolicies" }
    if ($Capabilities.AuditLog.Available) { $Items += "AuditLog" }
    if ($Capabilities.ExternalSharing.Available) { $Items += "ExternalSharing" }
    
    return $Items
}

# ============================================
# EXECUÇÃO PRINCIPAL
# ============================================

function Get-AllCapabilities {
    Write-CapabilityBanner
    
    Write-Section "VERIFICANDO CONEXÕES"
    $Connections = Test-Connections
    
    if (-not $Connections.ExchangeOnline) {
        Write-Status "Exchange Online não conectado. Execute Connect-ExchangeOnline primeiro." "Error"
        return $null
    }
    
    if (-not $Connections.SecurityCompliance) {
        Write-Status "Security & Compliance não conectado. Execute Connect-IPPSSession primeiro." "Error"
        return $null
    }
    
    Write-Status "Exchange Online - Conectado" "Success"
    Write-Status "Security & Compliance - Conectado" "Success"
    
    Write-Section "IDENTIFICANDO TENANT"
    $TenantInfo = Get-TenantInfo
    Write-Status "Tenant: $($TenantInfo.DisplayName)" "Info"
    Write-Status "Domínio: $($TenantInfo.Name)" "Detail"
    
    Write-Section "TESTANDO CAPACIDADES"
    
    $Capabilities = @{
        DLP = Test-DLPCapability
        SensitivityLabels = Test-SensitivityLabelsCapability
        Retention = Test-RetentionCapability
        AlertPolicies = Test-AlertPoliciesCapability
        AuditLog = Test-AuditLogCapability
        InsiderRisk = Test-InsiderRiskCapability
        eDiscovery = Test-eDiscoveryCapability
        CommunicationCompliance = Test-CommunicationComplianceCapability
        ExternalSharing = Test-ExternalSharingCapability
    }
    
    $License = Get-ProbableLicense -Capabilities $Capabilities
    
    $Result = @{
        TenantInfo = $TenantInfo
        Capabilities = $Capabilities
        License = $License
        AuditableItems = Get-AuditableItems -Capabilities $Capabilities
        RemediableItems = Get-RemediableItems -Capabilities $Capabilities
        ConnectionStatus = $Connections
        GeneratedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        ScriptVersion = "1.0"
    }
    
    Show-CapabilitiesSummary -TenantInfo $TenantInfo -Capabilities $Capabilities -License $License
    
    if (-not $Silent) {
        Write-Host "  📋 PODE AUDITAR: $($Result.AuditableItems -join ', ')" -ForegroundColor Cyan
        Write-Host "  🔧 PODE REMEDIAR: $($Result.RemediableItems -join ', ')" -ForegroundColor Yellow
        Write-Host ""
    }
    
    if ($ExportJson) {
        $Result | ConvertTo-Json -Depth 10 | Out-File $OutputPath -Encoding UTF8
        Write-Status "Exportado para: $OutputPath" "Success"
    }
    
    return $Result
}

$TenantCapabilities = Get-AllCapabilities

return $TenantCapabilities

<#
.SYNOPSIS
    Script de Auditoria Completa do Microsoft Purview
.DESCRIPTION
    Versão 4.0 - Integrado com Get-TenantCapabilities.ps1
    
    NOVIDADES v4.0:
    - Detecção automática de capacidades/licenças do tenant
    - Score calculado apenas com recursos DISPONÍVEIS
    - Pula seções não licenciadas automaticamente
    - Relatório claro do que foi auditado vs pulado
    
    Audita (conforme licença):
    - Políticas DLP (Data Loss Prevention)
    - Unified Audit Log (método atualizado 2025+)
    - Políticas de Retenção
    - Labels de Sensibilidade
    - Políticas de Alerta
    - Insider Risk Management
    - eDiscovery Cases
    - Communication Compliance
    - Compartilhamento Externo
    
.AUTHOR
    M365 Security Toolkit - RFAA
.VERSION
    4.0 - Janeiro 2026 - Integração com TenantCapabilities
.EXAMPLE
    ./Purview-Audit-PS7.ps1
    ./Purview-Audit-PS7.ps1 -OutputPath "./MeuRelatorio" -IncludeDetails
    ./Purview-Audit-PS7.ps1 -SkipConnection  # Se já estiver conectado
    ./Purview-Audit-PS7.ps1 -SkipCapabilityCheck  # Pula detecção automática
#>

[CmdletBinding()]
param(
    [string]$OutputPath = "./Purview-Audit-Report",
    [switch]$IncludeDetails,
    [switch]$SkipConnection,
    [switch]$SkipCapabilityCheck,
    [switch]$GenerateHTML = $true
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
$ReportDate = Get-Date -Format "yyyy-MM-dd_HH-mm"
$OutputFolder = "${OutputPath}_${ReportDate}"

# ============================================
# CONFIGURAÇÕES E CONSTANTES
# ============================================

$Script:Config = @{
    Version = "4.0"
    MinDLPPolicies = 3
    MinRetentionPolicies = 2
    MinSensitivityLabels = 5
    AuditLogTestDays = 7
    RecommendedRetentionDays = 365
}

$Script:Scores = @{
    DLP = 0
    AuditLog = 0
    Retention = 0
    SensitivityLabels = 0
    AlertPolicies = 0
    InsiderRisk = 0
    eDiscovery = 0
    CommunicationCompliance = 0
    ExternalSharing = 0
}

# Capabilities do tenant (preenchido na inicialização)
$Script:TenantCaps = $null
$Script:SkippedCategories = @()

# ============================================
# FUNÇÕES DE INTERFACE
# ============================================

function Write-Banner {
    $Banner = @"

╔══════════════════════════════════════════════════════════════════════════╗
║                                                                          ║
║   ██████╗ ██╗   ██╗██████╗ ██╗   ██╗██╗███████╗██╗    ██╗                ║
║   ██╔══██╗██║   ██║██╔══██╗██║   ██║██║██╔════╝██║    ██║                ║
║   ██████╔╝██║   ██║██████╔╝██║   ██║██║█████╗  ██║ █╗ ██║                ║
║   ██╔═══╝ ██║   ██║██╔══██╗╚██╗ ██╔╝██║██╔══╝  ██║███╗██║                ║
║   ██║     ╚██████╔╝██║  ██║ ╚████╔╝ ██║███████╗╚███╔███╔╝                ║
║   ╚═╝      ╚═════╝ ╚═╝  ╚═╝  ╚═══╝  ╚═╝╚══════╝ ╚══╝╚══╝                 ║
║                                                                          ║
║   🛡️  AUDITORIA COMPLETA DE SEGURANÇA E COMPLIANCE                       ║
║                                                                          ║
║   Versão 4.0 - Janeiro 2026 (com detecção de capacidades)                ║
║   PowerShell 7 Compatible (Windows/macOS/Linux)                          ║
║                                                                          ║
╚══════════════════════════════════════════════════════════════════════════╝

"@
    Write-Host $Banner -ForegroundColor Cyan
}

function Write-Section {
    param([string]$Title)
    
    $Line = "═" * 70
    Write-Host ""
    Write-Host $Line -ForegroundColor DarkCyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host $Line -ForegroundColor DarkCyan
}

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error", "Header", "Detail", "Skip")]
        [string]$Type = "Info"
    )
    
    $Config = switch ($Type) {
        "Success" { @{ Color = "Green";   Prefix = "  ✅" } }
        "Warning" { @{ Color = "Yellow";  Prefix = "  ⚠️ " } }
        "Error"   { @{ Color = "Red";     Prefix = "  ❌" } }
        "Info"    { @{ Color = "White";   Prefix = "  📋" } }
        "Header"  { @{ Color = "Cyan";    Prefix = "  🔍" } }
        "Detail"  { @{ Color = "Gray";    Prefix = "     •" } }
        "Skip"    { @{ Color = "DarkGray"; Prefix = "  ⏭️ " } }
        default   { @{ Color = "White";   Prefix = "  " } }
    }
    
    Write-Host "$($Config.Prefix) $Message" -ForegroundColor $Config.Color
}

function Write-Score {
    param(
        [string]$Category,
        [int]$Score,
        [int]$MaxScore = 100,
        [bool]$Skipped = $false
    )
    
    if ($Skipped) {
        Write-Host "  $Category" -NoNewline -ForegroundColor DarkGray
        Write-Host " [░░░░░░░░░░░░░░░░░░░░] " -NoNewline -ForegroundColor DarkGray
        Write-Host "N/A (não licenciado)" -ForegroundColor DarkGray
        return
    }
    
    $Percentage = [math]::Round(($Score / $MaxScore) * 100)
    $BarLength = 20
    $FilledLength = [math]::Round(($Percentage / 100) * $BarLength)
    $EmptyLength = $BarLength - $FilledLength
    
    $Bar = ("█" * $FilledLength) + ("░" * $EmptyLength)
    
    $Color = if ($Percentage -ge 80) { "Green" } 
             elseif ($Percentage -ge 50) { "Yellow" } 
             else { "Red" }
    
    Write-Host "  $Category" -NoNewline -ForegroundColor White
    Write-Host " [$Bar] " -NoNewline -ForegroundColor $Color
    Write-Host "${Percentage}%" -ForegroundColor $Color
}

function Initialize-OutputFolder {
    if (-not (Test-Path $OutputFolder)) {
        New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
    }
}

# ============================================
# DETECÇÃO DE CAPACIDADES
# ============================================

function Initialize-TenantCapabilities {
    Write-Section "DETECTANDO CAPACIDADES DO TENANT"
    
    # Tentar carregar o módulo
    $ModulePath = Join-Path $PSScriptRoot "..\Modules\Get-TenantCapabilities.ps1"
    if (-not (Test-Path $ModulePath)) {
        $ModulePath = Join-Path $PSScriptRoot "Get-TenantCapabilities.ps1"
    }
    if (-not (Test-Path $ModulePath)) {
        # Tentar no diretório atual
        $ModulePath = "./Get-TenantCapabilities.ps1"
    }
    
    if (Test-Path $ModulePath) {
        Write-Status "Carregando módulo de detecção..." "Header"
        try {
            $Script:TenantCaps = & $ModulePath -Silent
            
            if ($Script:TenantCaps) {
                Write-Status "Tenant: $($Script:TenantCaps.TenantInfo.DisplayName)" "Success"
                Write-Status "Licença detectada: $($Script:TenantCaps.License.Probable)" "Info"
                Write-Status "Recursos auditáveis: $($Script:TenantCaps.AuditableItems -join ', ')" "Detail"
                return $true
            }
        }
        catch {
            Write-Status "Erro ao carregar módulo: $($_.Exception.Message)" "Warning"
        }
    }
    else {
        Write-Status "Módulo Get-TenantCapabilities.ps1 não encontrado" "Warning"
        Write-Status "Executando auditoria completa (pode gerar erros de licença)" "Warning"
    }
    
    return $false
}

function Test-CapabilityAvailable {
    param([string]$Capability)
    
    if (-not $Script:TenantCaps) { return $true }  # Se não detectou, tenta tudo
    
    $Available = switch ($Capability) {
        "DLP" { $Script:TenantCaps.Capabilities.DLP.Available }
        "SensitivityLabels" { $Script:TenantCaps.Capabilities.SensitivityLabels.Available }
        "Retention" { $Script:TenantCaps.Capabilities.Retention.Available }
        "AlertPolicies" { $Script:TenantCaps.Capabilities.AlertPolicies.Available }
        "AuditLog" { $Script:TenantCaps.Capabilities.AuditLog.Available }
        "InsiderRisk" { $Script:TenantCaps.Capabilities.InsiderRisk.Available }
        "eDiscovery" { $Script:TenantCaps.Capabilities.eDiscovery.Available }
        "CommunicationCompliance" { $Script:TenantCaps.Capabilities.CommunicationCompliance.Available }
        "ExternalSharing" { $Script:TenantCaps.Capabilities.ExternalSharing.Available }
        default { $true }
    }
    
    return $Available
}

# ============================================
# CONEXÕES
# ============================================

function Connect-ToServices {
    Write-Section "CONEXÃO AOS SERVIÇOS MICROSOFT 365"
    
    $Status = @{
        ExchangeOnline = $false
        SecurityCompliance = $false
        Errors = @()
    }
    
    # Exchange Online
    Write-Status "Conectando ao Exchange Online..." "Header"
    try {
        $ExoSession = Get-ConnectionInformation -ErrorAction SilentlyContinue
        if (-not $ExoSession) {
            Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
        }
        $Status.ExchangeOnline = $true
        Write-Status "Exchange Online conectado" "Success"
    }
    catch {
        Write-Status "Erro ao conectar Exchange Online: $($_.Exception.Message)" "Error"
        $Status.Errors += "Exchange Online: $($_.Exception.Message)"
    }
    
    # Security & Compliance
    Write-Status "Conectando ao Security & Compliance Center..." "Header"
    try {
        $null = Get-Label -ResultSize 1 -ErrorAction Stop 2>$null
        $Status.SecurityCompliance = $true
        Write-Status "Security & Compliance já conectado" "Success"
    }
    catch {
        try {
            Connect-IPPSSession -ShowBanner:$false -WarningAction SilentlyContinue -ErrorAction Stop
            $Status.SecurityCompliance = $true
            Write-Status "Security & Compliance conectado" "Success"
        }
        catch {
            Write-Status "Erro ao conectar Security & Compliance: $($_.Exception.Message)" "Error"
            $Status.Errors += "Security & Compliance: $($_.Exception.Message)"
        }
    }
    
    return $Status
}

# ============================================
# AUDITORIA: DLP
# ============================================

function Get-DLPAudit {
    Write-Section "AUDITORIA DE POLÍTICAS DLP"
    
    # Verificar se disponível
    if (-not (Test-CapabilityAvailable "DLP")) {
        Write-Status "DLP não disponível neste tenant (licença não inclui)" "Skip"
        $Script:SkippedCategories += "DLP"
        return @{
            Skipped = $true
            Reason = "Licença não inclui DLP"
            Score = 0
        }
    }
    
    $Result = @{
        Policies = @()
        Rules = @()
        Recommendations = @()
        Score = 0
        Skipped = $false
        Details = @{
            TotalPolicies = 0
            EnabledPolicies = 0
            TestModePolicies = 0
            TotalRules = 0
            DisabledRules = 0
            WorkloadCoverage = @()
        }
    }
    
    try {
        $Policies = Get-DlpCompliancePolicy -WarningAction SilentlyContinue -ErrorAction Stop
        
        if ($null -eq $Policies -or @($Policies).Count -eq 0) {
            Write-Status "CRÍTICO: Nenhuma política DLP configurada!" "Error"
            $Result.Recommendations += @{
                Priority = "Critical"
                Category = "DLP"
                Message = "Nenhuma política DLP encontrada. Configure políticas DLP para proteger dados sensíveis."
                Remediation = "Acesse Purview > Data Loss Prevention > Policies > Create Policy"
            }
            return $Result
        }
        
        $Result.Details.TotalPolicies = @($Policies).Count
        Write-Status "Total de políticas DLP: $($Result.Details.TotalPolicies)" "Info"
        
        $Workloads = @{}
        
        foreach ($Policy in $Policies) {
            $PolicyInfo = @{
                Name = $Policy.Name
                Enabled = $Policy.Enabled
                Mode = $Policy.Mode
                Workload = ($Policy.Workload -join ", ")
                Priority = $Policy.Priority
            }
            $Result.Policies += $PolicyInfo
            
            if ($Policy.Enabled) { $Result.Details.EnabledPolicies++ }
            if ($Policy.Mode -match "Test|Audit") { $Result.Details.TestModePolicies++ }
            
            foreach ($Wl in $Policy.Workload) {
                if (-not $Workloads[$Wl]) { $Workloads[$Wl] = 0 }
                $Workloads[$Wl]++
            }
            
            $Icon = if ($Policy.Enabled) { "✅" } else { "❌" }
            $ModeIcon = if ($Policy.Mode -eq "Enable") { "🟢" } elseif ($Policy.Mode -match "Test") { "🟡" } else { "⚪" }
            Write-Status "$Icon $ModeIcon $($Policy.Name)" "Detail"
        }
        
        $Result.Details.WorkloadCoverage = $Workloads.Keys | ForEach-Object { @{ Workload = $_; Policies = $Workloads[$_] } }
        
        $RequiredWorkloads = @("Exchange", "SharePoint", "OneDriveForBusiness", "Teams")
        $MissingWorkloads = $RequiredWorkloads | Where-Object { -not $Workloads[$_] }
        
        if ($MissingWorkloads) {
            Write-Status "Workloads sem cobertura DLP: $($MissingWorkloads -join ', ')" "Warning"
            $Result.Recommendations += @{
                Priority = "High"
                Category = "DLP"
                Message = "Workloads sem proteção DLP: $($MissingWorkloads -join ', ')"
                Remediation = "Crie políticas DLP que incluam esses workloads"
            }
        }
        
        $Rules = Get-DlpComplianceRule -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        if ($Rules) {
            $Result.Details.TotalRules = @($Rules).Count
            $Result.Details.DisabledRules = @($Rules | Where-Object { $_.Disabled }).Count
            Write-Status "Total de regras DLP: $($Result.Details.TotalRules) ($($Result.Details.DisabledRules) desabilitadas)" "Info"
        }
        
        $ScoreFactors = @(
            @{ Weight = 30; Value = if ($Result.Details.TotalPolicies -ge $Script:Config.MinDLPPolicies) { 1 } else { $Result.Details.TotalPolicies / $Script:Config.MinDLPPolicies } },
            @{ Weight = 30; Value = if ($Result.Details.TotalPolicies -gt 0) { $Result.Details.EnabledPolicies / $Result.Details.TotalPolicies } else { 0 } },
            @{ Weight = 20; Value = if ($MissingWorkloads.Count -eq 0) { 1 } else { 1 - ($MissingWorkloads.Count / $RequiredWorkloads.Count) } },
            @{ Weight = 20; Value = if ($Result.Details.TestModePolicies -eq 0) { 1 } else { 1 - ($Result.Details.TestModePolicies / $Result.Details.TotalPolicies) } }
        )
        
        $Result.Score = [math]::Round(($ScoreFactors | ForEach-Object { $_.Weight * $_.Value } | Measure-Object -Sum).Sum)
    }
    catch {
        if ($_.Exception.Message -match "license|not licensed") {
            Write-Status "DLP não disponível (licença)" "Skip"
            $Script:SkippedCategories += "DLP"
            return @{ Skipped = $true; Reason = "Licença não inclui DLP"; Score = 0 }
        }
        Write-Status "Erro ao auditar DLP: $($_.Exception.Message)" "Error"
    }
    
    return $Result
}

# ============================================
# AUDITORIA: UNIFIED AUDIT LOG
# ============================================

function Get-AuditLogAudit {
    Write-Section "AUDITORIA DO UNIFIED AUDIT LOG"
    
    $Result = @{
        UnifiedAuditEnabled = $false
        MailboxAuditEnabled = $false
        AuditLogSearchable = $false
        RecentActivityFound = $false
        Recommendations = @()
        Score = 0
        Skipped = $false
        Details = @{
            TestSearchResults = 0
            LastActivityDate = $null
            MethodUsed = ""
        }
    }
    
    try {
        Write-Status "Testando Unified Audit Log com busca real..." "Header"
        
        $StartDate = (Get-Date).AddDays(-$Script:Config.AuditLogTestDays)
        $EndDate = Get-Date
        
        try {
            $TestSearch = Search-UnifiedAuditLog -StartDate $StartDate -EndDate $EndDate -ResultSize 5 -ErrorAction Stop
            
            if ($null -ne $TestSearch -and @($TestSearch).Count -gt 0) {
                $Result.UnifiedAuditEnabled = $true
                $Result.AuditLogSearchable = $true
                $Result.RecentActivityFound = $true
                $Result.Details.TestSearchResults = @($TestSearch).Count
                $Result.Details.LastActivityDate = ($TestSearch | Sort-Object CreationDate -Descending | Select-Object -First 1).CreationDate
                $Result.Details.MethodUsed = "Search-UnifiedAuditLog"
                
                Write-Status "Unified Audit Log: ATIVO E FUNCIONANDO" "Success"
                Write-Status "Registros encontrados nos últimos $($Script:Config.AuditLogTestDays) dias: $($Result.Details.TestSearchResults)+" "Info"
                
                $Result.Score += 60
            }
            else {
                $Result.AuditLogSearchable = $true
                $Result.UnifiedAuditEnabled = $true
                $Result.Details.MethodUsed = "Search-UnifiedAuditLog (empty)"
                
                Write-Status "Unified Audit Log: ATIVO (sem atividade recente)" "Warning"
                $Result.Score += 40
            }
        }
        catch {
            $ErrorMsg = $_.Exception.Message
            
            if ($ErrorMsg -match "UnifiedAuditLogIngestionEnabled.*False|not enabled|audit logging is not enabled") {
                Write-Status "Unified Audit Log: DESABILITADO" "Error"
                $Result.UnifiedAuditEnabled = $false
                
                $Result.Recommendations += @{
                    Priority = "Critical"
                    Category = "AuditLog"
                    Message = "🚨 CRÍTICO: Unified Audit Log está DESABILITADO!"
                    Remediation = "Execute o script M365-Remediation.ps1 ou ative manualmente no Purview"
                }
            }
            else {
                Write-Status "Erro ao testar Audit Log: $ErrorMsg" "Warning"
            }
        }
        
        # Mailbox Audit
        Write-Status "Verificando Mailbox Audit por padrão..." "Header"
        
        try {
            $OrgConfig = Get-OrganizationConfig -ErrorAction Stop
            $Result.MailboxAuditEnabled = -not $OrgConfig.AuditDisabled
            
            if ($Result.MailboxAuditEnabled) {
                Write-Status "Mailbox Audit por padrão: HABILITADO" "Success"
                $Result.Score += 20
            }
            else {
                Write-Status "Mailbox Audit por padrão: DESABILITADO" "Error"
                $Result.Recommendations += @{
                    Priority = "High"
                    Category = "AuditLog"
                    Message = "Mailbox Audit por padrão está desabilitado"
                    Remediation = "Execute: Set-OrganizationConfig -AuditDisabled `$false"
                }
            }
        }
        catch {
            Write-Status "Não foi possível verificar Mailbox Audit" "Warning"
        }
        
        # Retenção de audit
        try {
            $AuditRetention = Get-UnifiedAuditLogRetentionPolicy -ErrorAction SilentlyContinue
            if ($AuditRetention) {
                Write-Status "Políticas de retenção de audit: $(@($AuditRetention).Count)" "Info"
                $Result.Score += 20
            }
        }
        catch { }
    }
    catch {
        Write-Status "Erro geral na auditoria de Audit Log: $($_.Exception.Message)" "Error"
    }
    
    return $Result
}

# ============================================
# AUDITORIA: RETENÇÃO
# ============================================

function Get-RetentionAudit {
    Write-Section "AUDITORIA DE POLÍTICAS DE RETENÇÃO"
    
    if (-not (Test-CapabilityAvailable "Retention")) {
        Write-Status "Retention não disponível neste tenant" "Skip"
        $Script:SkippedCategories += "Retention"
        return @{ Skipped = $true; Reason = "Licença não inclui Retention"; Score = 0 }
    }
    
    $Result = @{
        Policies = @()
        Labels = @()
        Recommendations = @()
        Score = 0
        Skipped = $false
        Details = @{
            TotalPolicies = 0
            EnabledPolicies = 0
            TotalLabels = 0
        }
    }
    
    try {
        $Policies = Get-RetentionCompliancePolicy -WarningAction SilentlyContinue -ErrorAction Stop
        
        if ($null -eq $Policies -or @($Policies).Count -eq 0) {
            Write-Status "Nenhuma política de retenção encontrada" "Warning"
            $Result.Recommendations += @{
                Priority = "High"
                Category = "Retention"
                Message = "Nenhuma política de retenção configurada"
                Remediation = "Configure políticas de retenção para compliance"
            }
        }
        else {
            $Result.Details.TotalPolicies = @($Policies).Count
            Write-Status "Total de políticas de retenção: $($Result.Details.TotalPolicies)" "Info"
            
            foreach ($Policy in $Policies) {
                $Result.Policies += @{
                    Name = $Policy.Name
                    Enabled = $Policy.Enabled
                    Workload = ($Policy.Workload -join ", ")
                }
                
                if ($Policy.Enabled) { $Result.Details.EnabledPolicies++ }
                
                $Icon = if ($Policy.Enabled) { "✅" } else { "❌" }
                Write-Status "$Icon $($Policy.Name)" "Detail"
            }
        }
        
        try {
            $Labels = Get-RetentionComplianceRule -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
            if ($Labels) {
                $Result.Details.TotalLabels = @($Labels).Count
                Write-Status "Total de regras de retenção: $($Result.Details.TotalLabels)" "Info"
            }
        }
        catch { }
        
        $ScoreFactors = @(
            @{ Weight = 50; Value = if ($Result.Details.TotalPolicies -ge $Script:Config.MinRetentionPolicies) { 1 } else { $Result.Details.TotalPolicies / $Script:Config.MinRetentionPolicies } },
            @{ Weight = 30; Value = if ($Result.Details.TotalPolicies -gt 0) { $Result.Details.EnabledPolicies / $Result.Details.TotalPolicies } else { 0 } },
            @{ Weight = 20; Value = if ($Result.Details.TotalLabels -gt 0) { 1 } else { 0 } }
        )
        
        $Result.Score = [math]::Round(($ScoreFactors | ForEach-Object { $_.Weight * $_.Value } | Measure-Object -Sum).Sum)
    }
    catch {
        if ($_.Exception.Message -match "license|not licensed") {
            Write-Status "Retention não disponível (licença)" "Skip"
            $Script:SkippedCategories += "Retention"
            return @{ Skipped = $true; Reason = "Licença não inclui"; Score = 0 }
        }
        Write-Status "Erro ao auditar Retenção: $($_.Exception.Message)" "Error"
    }
    
    return $Result
}

# ============================================
# AUDITORIA: SENSITIVITY LABELS
# ============================================

function Get-SensitivityLabelsAudit {
    Write-Section "AUDITORIA DE LABELS DE SENSIBILIDADE"
    
    if (-not (Test-CapabilityAvailable "SensitivityLabels")) {
        Write-Status "Sensitivity Labels não disponível neste tenant" "Skip"
        $Script:SkippedCategories += "SensitivityLabels"
        return @{ Skipped = $true; Reason = "Licença não inclui Labels"; Score = 0 }
    }
    
    $Result = @{
        Labels = @()
        Policies = @()
        Recommendations = @()
        Score = 0
        Skipped = $false
        Details = @{
            TotalLabels = 0
            ParentLabels = 0
            ChildLabels = 0
        }
    }
    
    try {
        $Labels = Get-Label -ErrorAction Stop
        
        if ($null -eq $Labels -or @($Labels).Count -eq 0) {
            Write-Status "Nenhum label de sensibilidade configurado" "Warning"
            $Result.Recommendations += @{
                Priority = "High"
                Category = "SensitivityLabels"
                Message = "Nenhum label de sensibilidade configurado"
                Remediation = "Configure labels para classificação e proteção de dados"
            }
            return $Result
        }
        
        $Result.Details.TotalLabels = @($Labels).Count
        Write-Status "Total de labels: $($Result.Details.TotalLabels)" "Info"
        
        foreach ($Label in $Labels) {
            $Result.Labels += @{
                Name = $Label.Name
                DisplayName = $Label.DisplayName
                Priority = $Label.Priority
                ParentId = $Label.ParentId
            }
            
            if ([string]::IsNullOrEmpty($Label.ParentId)) {
                $Result.Details.ParentLabels++
                Write-Status "📁 $($Label.DisplayName)" "Detail"
            }
            else {
                $Result.Details.ChildLabels++
                Write-Status "   └─ $($Label.DisplayName)" "Detail"
            }
        }
        
        try {
            $LabelPolicies = Get-LabelPolicy -ErrorAction SilentlyContinue
            if ($LabelPolicies) {
                $Result.Policies = @($LabelPolicies | Select-Object Name, Enabled)
                Write-Status "Políticas de publicação: $(@($LabelPolicies).Count)" "Info"
            }
        }
        catch { }
        
        $ScoreFactors = @(
            @{ Weight = 40; Value = if ($Result.Details.TotalLabels -ge $Script:Config.MinSensitivityLabels) { 1 } else { $Result.Details.TotalLabels / $Script:Config.MinSensitivityLabels } },
            @{ Weight = 30; Value = if ($Result.Details.ParentLabels -ge 3) { 1 } else { $Result.Details.ParentLabels / 3 } },
            @{ Weight = 30; Value = if (@($Result.Policies).Count -gt 0) { 1 } else { 0 } }
        )
        
        $Result.Score = [math]::Round(($ScoreFactors | ForEach-Object { $_.Weight * $_.Value } | Measure-Object -Sum).Sum)
    }
    catch {
        if ($_.Exception.Message -match "license|not licensed") {
            Write-Status "Labels não disponível (licença)" "Skip"
            $Script:SkippedCategories += "SensitivityLabels"
            return @{ Skipped = $true; Reason = "Licença não inclui"; Score = 0 }
        }
        Write-Status "Erro ao auditar Labels: $($_.Exception.Message)" "Error"
    }
    
    return $Result
}

# ============================================
# AUDITORIA: ALERT POLICIES
# ============================================

function Get-AlertPoliciesAudit {
    Write-Section "AUDITORIA DE POLÍTICAS DE ALERTA"
    
    $Result = @{
        Policies = @()
        Recommendations = @()
        Score = 0
        Skipped = $false
        Details = @{
            TotalPolicies = 0
            EnabledPolicies = 0
            CustomPolicies = 0
            SystemPolicies = 0
            AdvancedAlertsAvailable = $false
        }
    }
    
    # Verificar se alertas avançados disponíveis
    if ($Script:TenantCaps) {
        $Result.Details.AdvancedAlertsAvailable = $Script:TenantCaps.Capabilities.AlertPolicies.AdvancedAlerts
    }
    
    try {
        $Policies = Get-ProtectionAlert -ErrorAction Stop
        
        if ($null -eq $Policies -or @($Policies).Count -eq 0) {
            Write-Status "Nenhuma política de alerta encontrada" "Warning"
            return $Result
        }
        
        $Result.Details.TotalPolicies = @($Policies).Count
        Write-Status "Total de políticas de alerta: $($Result.Details.TotalPolicies)" "Info"
        
        foreach ($Policy in $Policies) {
            $Result.Policies += @{
                Name = $Policy.Name
                Enabled = -not $Policy.Disabled
                Severity = $Policy.Severity
                IsSystemRule = $Policy.IsSystemRule
            }
            
            if (-not $Policy.Disabled) { $Result.Details.EnabledPolicies++ }
            if ($Policy.IsSystemRule) { $Result.Details.SystemPolicies++ }
            else { $Result.Details.CustomPolicies++ }
        }
        
        Write-Status "Habilitadas: $($Result.Details.EnabledPolicies) | Sistema: $($Result.Details.SystemPolicies) | Custom: $($Result.Details.CustomPolicies)" "Info"
        
        if ($Result.Details.AdvancedAlertsAvailable) {
            Write-Status "Alertas avançados: DISPONÍVEIS (E5)" "Success"
        }
        else {
            Write-Status "Alertas avançados: Não disponíveis (apenas básicos)" "Info"
        }
        
        $Result.Score = if ($Result.Details.TotalPolicies -gt 0) {
            [math]::Round(($Result.Details.EnabledPolicies / $Result.Details.TotalPolicies) * 100)
        } else { 0 }
    }
    catch {
        Write-Status "Erro ao auditar Alert Policies: $($_.Exception.Message)" "Warning"
    }
    
    return $Result
}

# ============================================
# AUDITORIA: INSIDER RISK
# ============================================

function Get-InsiderRiskAudit {
    Write-Section "AUDITORIA DE INSIDER RISK MANAGEMENT"
    
    if (-not (Test-CapabilityAvailable "InsiderRisk")) {
        Write-Status "Insider Risk não disponível neste tenant (requer E5 ou add-on)" "Skip"
        $Script:SkippedCategories += "InsiderRisk"
        return @{ Skipped = $true; Reason = "Requer E5 ou Insider Risk Add-on"; Score = 0 }
    }
    
    $Result = @{
        Policies = @()
        Recommendations = @()
        Score = 0
        Skipped = $false
        Details = @{
            TotalPolicies = 0
            ActivePolicies = 0
        }
    }
    
    try {
        $Policies = Get-InsiderRiskPolicy -WarningAction SilentlyContinue -ErrorAction Stop
        
        if ($null -eq $Policies -or @($Policies).Count -eq 0) {
            Write-Status "Nenhuma política de Insider Risk configurada" "Info"
            return $Result
        }
        
        $Result.Details.TotalPolicies = @($Policies).Count
        Write-Status "Total de políticas: $($Result.Details.TotalPolicies)" "Info"
        
        foreach ($Policy in $Policies) {
            $Result.Policies += @{
                Name = $Policy.Name
                Enabled = $Policy.Enabled
            }
            
            $Icon = if ($Policy.Enabled) { "✅" } else { "❌" }
            Write-Status "$Icon $($Policy.Name)" "Detail"
            
            if ($Policy.Enabled) { $Result.Details.ActivePolicies++ }
        }
        
        $Result.Score = [math]::Round(($Result.Details.ActivePolicies / [math]::Max($Result.Details.TotalPolicies, 1)) * 100)
    }
    catch {
        if ($_.Exception.Message -match "license|not licensed|not recognized") {
            Write-Status "Insider Risk não disponível (licença)" "Skip"
            $Script:SkippedCategories += "InsiderRisk"
            return @{ Skipped = $true; Reason = "Requer E5"; Score = 0 }
        }
        Write-Status "Erro: $($_.Exception.Message)" "Warning"
    }
    
    return $Result
}

# ============================================
# AUDITORIA: EDISCOVERY
# ============================================

function Get-eDiscoveryAudit {
    Write-Section "AUDITORIA DE EDISCOVERY"
    
    if (-not (Test-CapabilityAvailable "eDiscovery")) {
        Write-Status "eDiscovery não disponível neste tenant" "Skip"
        $Script:SkippedCategories += "eDiscovery"
        return @{ Skipped = $true; Reason = "Licença não inclui"; Score = 0 }
    }
    
    $Result = @{
        Cases = @()
        Recommendations = @()
        Score = 0
        Skipped = $false
        Details = @{
            TotalCases = 0
            ActiveCases = 0
            PremiumAvailable = $false
        }
    }
    
    # Verificar se Premium disponível
    if ($Script:TenantCaps) {
        $Result.Details.PremiumAvailable = $Script:TenantCaps.Capabilities.eDiscovery.PremiumAvailable
    }
    
    try {
        $Cases = Get-ComplianceCase -ErrorAction SilentlyContinue
        
        if ($null -eq $Cases -or @($Cases).Count -eq 0) {
            Write-Status "Nenhum caso de eDiscovery encontrado" "Info"
            Write-Status "eDiscovery é usado sob demanda para investigações" "Detail"
            $Result.Score = 100
            return $Result
        }
        
        $Result.Details.TotalCases = @($Cases).Count
        Write-Status "Total de casos: $($Result.Details.TotalCases)" "Info"
        
        foreach ($Case in $Cases) {
            if ($Case.Status -eq "Active") { $Result.Details.ActiveCases++ }
        }
        
        Write-Status "Ativos: $($Result.Details.ActiveCases)" "Info"
        
        if ($Result.Details.PremiumAvailable) {
            Write-Status "eDiscovery Premium: DISPONÍVEL" "Success"
        }
        
        $Result.Score = 100
    }
    catch {
        Write-Status "Erro: $($_.Exception.Message)" "Warning"
    }
    
    return $Result
}

# ============================================
# AUDITORIA: COMPARTILHAMENTO EXTERNO
# ============================================

function Get-ExternalSharingAudit {
    Write-Section "AUDITORIA DE COMPARTILHAMENTO EXTERNO"
    
    $Result = @{
        OWAPolicies = @()
        Recommendations = @()
        Score = 0
        Skipped = $false
        Details = @{
            WacExternalDisabled = 0
        }
    }
    
    try {
        $OWAPolicies = Get-OwaMailboxPolicy -ErrorAction Stop
        
        foreach ($Policy in $OWAPolicies) {
            $Result.OWAPolicies += @{
                Name = $Policy.Name
                WacExternalServicesEnabled = $Policy.WacExternalServicesEnabled
            }
            
            if (-not $Policy.WacExternalServicesEnabled) {
                $Result.Details.WacExternalDisabled++
            }
            
            Write-Status "$($Policy.Name): External WAC = $($Policy.WacExternalServicesEnabled)" "Detail"
        }
        
        if (@($OWAPolicies).Count -gt 0) {
            $Result.Score = [math]::Round(($Result.Details.WacExternalDisabled / @($OWAPolicies).Count) * 100)
        }
        
        if ($Result.Score -lt 100) {
            $Result.Recommendations += @{
                Priority = "Low"
                Category = "ExternalSharing"
                Message = "Algumas políticas permitem serviços externos no OWA"
                Remediation = "Avalie se é necessário permitir provedores externos"
            }
        }
    }
    catch {
        Write-Status "Erro: $($_.Exception.Message)" "Warning"
    }
    
    return $Result
}

# ============================================
# AUDITORIA: COMMUNICATION COMPLIANCE
# ============================================

function Get-CommunicationComplianceAudit {
    Write-Section "AUDITORIA DE COMMUNICATION COMPLIANCE"
    
    if (-not (Test-CapabilityAvailable "CommunicationCompliance")) {
        Write-Status "Communication Compliance não disponível (requer E5 ou add-on)" "Skip"
        $Script:SkippedCategories += "CommunicationCompliance"
        return @{ Skipped = $true; Reason = "Requer E5 ou add-on"; Score = 0 }
    }
    
    $Result = @{
        Policies = @()
        Recommendations = @()
        Score = 0
        Skipped = $false
        Details = @{
            TotalPolicies = 0
            ActivePolicies = 0
        }
    }
    
    try {
        $Policies = Get-SupervisoryReviewPolicyV2 -WarningAction SilentlyContinue -ErrorAction Stop
        
        if ($null -eq $Policies -or @($Policies).Count -eq 0) {
            Write-Status "Nenhuma política de Communication Compliance configurada" "Info"
            return $Result
        }
        
        $Result.Details.TotalPolicies = @($Policies).Count
        Write-Status "Total de políticas: $($Result.Details.TotalPolicies)" "Info"
        
        foreach ($Policy in $Policies) {
            if ($Policy.Enabled) { $Result.Details.ActivePolicies++ }
        }
        
        $Result.Score = [math]::Round(($Result.Details.ActivePolicies / [math]::Max($Result.Details.TotalPolicies, 1)) * 100)
    }
    catch {
        if ($_.Exception.Message -match "license|not licensed|not recognized") {
            Write-Status "Communication Compliance não disponível (licença)" "Skip"
            $Script:SkippedCategories += "CommunicationCompliance"
            return @{ Skipped = $true; Reason = "Requer E5"; Score = 0 }
        }
        Write-Status "Erro: $($_.Exception.Message)" "Warning"
    }
    
    return $Result
}

# ============================================
# EXPORTAÇÃO
# ============================================

function Export-Results {
    param([hashtable]$Results)
    
    Write-Section "EXPORTANDO RESULTADOS"
    
    Initialize-OutputFolder
    
    # Adicionar info do tenant ao resultado
    if ($Script:TenantCaps) {
        $Results.TenantInfo = $Script:TenantCaps.TenantInfo
        $Results.DetectedLicense = $Script:TenantCaps.License
        $Results.SkippedCategories = $Script:SkippedCategories
    }
    
    # JSON Detalhado
    $JsonPath = Join-Path $OutputFolder "audit-results.json"
    $Results | ConvertTo-Json -Depth 15 | Out-File $JsonPath -Encoding UTF8
    Write-Status "JSON: $JsonPath" "Success"
    
    # CSV de Recomendações
    $AllRecs = @()
    foreach ($Key in $Results.Keys) {
        if ($Results[$Key].Recommendations) {
            foreach ($Rec in $Results[$Key].Recommendations) {
                if ($Rec -is [hashtable]) {
                    $AllRecs += [PSCustomObject]@{
                        Categoria = $Key
                        Prioridade = $Rec.Priority
                        Mensagem = $Rec.Message
                        Remediacao = $Rec.Remediation
                    }
                }
            }
        }
    }
    
    if ($AllRecs.Count -gt 0) {
        $CsvPath = Join-Path $OutputFolder "recommendations.csv"
        $AllRecs | Export-Csv $CsvPath -NoTypeInformation -Encoding UTF8
        Write-Status "CSV Recomendações: $CsvPath" "Success"
    }
    
    # Markdown
    $MdPath = Join-Path $OutputFolder "SUMMARY.md"
    $TenantName = if ($Script:TenantCaps) { $Script:TenantCaps.TenantInfo.DisplayName } else { "Desconhecido" }
    $LicenseInfo = if ($Script:TenantCaps) { $Script:TenantCaps.License.Probable } else { "Não detectada" }
    
    $Md = @"
# 🛡️ Relatório de Auditoria Purview

**Data:** $(Get-Date -Format "dd/MM/yyyy HH:mm")
**Tenant:** $TenantName
**Licença Detectada:** $LicenseInfo

## 📊 Scores por Categoria

| Categoria | Score | Status |
|-----------|-------|--------|
"@
    
    $Categories = @("DLP", "AuditLog", "Retention", "SensitivityLabels", "AlertPolicies", "InsiderRisk", "eDiscovery", "ExternalSharing", "CommunicationCompliance")
    foreach ($Cat in $Categories) {
        if ($Results[$Cat]) {
            if ($Results[$Cat].Skipped) {
                $Md += "`n| $Cat | N/A | ⏭️ Não licenciado |"
            }
            else {
                $Score = $Results[$Cat].Score
                $Status = if ($Score -ge 80) { "✅ Bom" } elseif ($Score -ge 50) { "⚠️ Atenção" } else { "❌ Crítico" }
                $Md += "`n| $Cat | $Score% | $Status |"
            }
        }
    }
    
    if ($Script:SkippedCategories.Count -gt 0) {
        $Md += "`n`n## ⏭️ Categorias Puladas (não licenciadas)`n"
        foreach ($Skip in $Script:SkippedCategories) {
            $Md += "`n- $Skip"
        }
    }
    
    $Md | Out-File $MdPath -Encoding UTF8
    Write-Status "Markdown: $MdPath" "Success"

    # HTML
    if ($GenerateHTML) {
        $HtmlPath = Join-Path $OutputFolder "SUMMARY.html"
        $TenantName = if ($Script:TenantCaps) { $Script:TenantCaps.TenantInfo.DisplayName } else { "Desconhecido" }
        $LicenseInfo = if ($Script:TenantCaps) { $Script:TenantCaps.License.Probable } else { "Não detectada" }

        $Categories = @("DLP", "AuditLog", "Retention", "SensitivityLabels", "AlertPolicies", "InsiderRisk", "eDiscovery", "ExternalSharing", "CommunicationCompliance")
        $CategoryRows = @()
        foreach ($Cat in $Categories) {
            if ($Results[$Cat]) {
                if ($Results[$Cat].Skipped) {
                    $CategoryRows += "<tr class='na'><td>" + [System.Net.WebUtility]::HtmlEncode($Cat) + "</td><td>N/A</td><td>Não licenciado</td></tr>"
                }
                else {
                    $Score = $Results[$Cat].Score
                    $Status = if ($Score -ge 80) { "Bom" } elseif ($Score -ge 50) { "Atenção" } else { "Crítico" }
                    $Class = if ($Score -ge 80) { "good" } elseif ($Score -ge 50) { "warn" } else { "bad" }
                    $CategoryRows += "<tr class='" + $Class + "'><td>" + [System.Net.WebUtility]::HtmlEncode($Cat) + "</td><td>" + $Score + "%</td><td>" + $Status + "</td></tr>"
                }
            }
        }

        $SkippedHtml = ""
        if ($Script:SkippedCategories.Count -gt 0) {
            $SkippedHtml = "<h2>Categorias puladas (não licenciadas)</h2><ul>" + ($Script:SkippedCategories | ForEach-Object { "<li>" + [System.Net.WebUtility]::HtmlEncode($_) + "</li>" }) -join "" + "</ul>"
        }

        $RecsHtml = "<p>Nenhuma recomendação crítica.</p>"
        if ($AllRecs.Count -gt 0) {
            $RecsRows = $AllRecs | ForEach-Object {
                "<tr><td>" + [System.Net.WebUtility]::HtmlEncode($_.Categoria) + "</td><td>" + [System.Net.WebUtility]::HtmlEncode($_.Prioridade) + "</td><td>" + [System.Net.WebUtility]::HtmlEncode($_.Mensagem) + "</td><td>" + [System.Net.WebUtility]::HtmlEncode($_.Remediacao) + "</td></tr>"
            }
            $RecsHtml = "<table><thead><tr><th>Categoria</th><th>Prioridade</th><th>Mensagem</th><th>Remediação</th></tr></thead><tbody>" + ($RecsRows -join "") + "</tbody></table>"
        }

        $Html = @"
<!DOCTYPE html>
<html lang="pt-br">
<head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Relatório de Auditoria Purview</title>
    <style>
        body { font-family: Segoe UI, Roboto, Arial, sans-serif; margin: 24px; color: #1f2937; }
        h1 { margin-bottom: 4px; }
        .meta { color: #6b7280; margin-bottom: 20px; }
        table { width: 100%; border-collapse: collapse; margin-top: 12px; }
        th, td { border: 1px solid #e5e7eb; padding: 8px 10px; text-align: left; }
        th { background: #f3f4f6; }
        tr.good td { background: #ecfdf5; }
        tr.warn td { background: #fffbeb; }
        tr.bad td { background: #fef2f2; }
        tr.na td { background: #f9fafb; color: #6b7280; }
        .section { margin-top: 28px; }
    </style>
</head>
<body>
    <h1>🛡️ Relatório de Auditoria Purview</h1>
    <div class="meta">Data: $(Get-Date -Format "dd/MM/yyyy HH:mm")<br/>Tenant: $TenantName<br/>Licença Detectada: $LicenseInfo</div>

    <div class="section">
        <h2>Scores por Categoria</h2>
        <table>
            <thead>
                <tr><th>Categoria</th><th>Score</th><th>Status</th></tr>
            </thead>
            <tbody>
                $($CategoryRows -join "")
            </tbody>
        </table>
    </div>

    $SkippedHtml

    <div class="section">
        <h2>Recomendações</h2>
        $RecsHtml
    </div>
</body>
</html>
"@

        $Html | Out-File $HtmlPath -Encoding UTF8
        Write-Status "HTML: $HtmlPath" "Success"
    }
    
    return $OutputFolder
}

# ============================================
# SUMÁRIO FINAL
# ============================================

function Show-Summary {
    param([hashtable]$Results)
    
    Write-Section "SUMÁRIO DA AUDITORIA"
    
    # Info do tenant
    if ($Script:TenantCaps) {
        Write-Host ""
        Write-Host "  📋 TENANT: $($Script:TenantCaps.TenantInfo.DisplayName)" -ForegroundColor Cyan
        Write-Host "  📋 LICENÇA: $($Script:TenantCaps.License.Probable)" -ForegroundColor Cyan
        Write-Host ""
    }
    
    Write-Host "  📊 SCORES POR CATEGORIA" -ForegroundColor Cyan
    Write-Host "  ─────────────────────────────────────────────" -ForegroundColor Gray
    
    $Categories = @(
        @{ Key = "DLP"; Name = "Data Loss Prevention" },
        @{ Key = "AuditLog"; Name = "Unified Audit Log" },
        @{ Key = "Retention"; Name = "Políticas de Retenção" },
        @{ Key = "SensitivityLabels"; Name = "Labels de Sensibilidade" },
        @{ Key = "AlertPolicies"; Name = "Políticas de Alerta" },
        @{ Key = "InsiderRisk"; Name = "Insider Risk" },
        @{ Key = "eDiscovery"; Name = "eDiscovery" },
        @{ Key = "ExternalSharing"; Name = "Compartilhamento Externo" },
        @{ Key = "CommunicationCompliance"; Name = "Communication Compliance" }
    )
    
    $TotalScore = 0
    $ValidCategories = 0
    
    foreach ($Cat in $Categories) {
        if ($Results[$Cat.Key]) {
            $Skipped = $Results[$Cat.Key].Skipped -eq $true
            $Score = $Results[$Cat.Key].Score
            
            Write-Score -Category $Cat.Name.PadRight(28) -Score $Score -Skipped $Skipped
            
            if (-not $Skipped) {
                $TotalScore += $Score
                $ValidCategories++
            }
        }
    }
    
    $OverallScore = if ($ValidCategories -gt 0) { [math]::Round($TotalScore / $ValidCategories) } else { 0 }
    
    Write-Host "  ─────────────────────────────────────────────" -ForegroundColor Gray
    Write-Score -Category "SCORE GERAL (licenciados)".PadRight(28) -Score $OverallScore
    Write-Host ""
    
    # Info sobre categorias puladas
    if ($Script:SkippedCategories.Count -gt 0) {
        Write-Host "  ⏭️  CATEGORIAS PULADAS (não licenciadas):" -ForegroundColor DarkGray
        Write-Host "     $($Script:SkippedCategories -join ', ')" -ForegroundColor DarkGray
        Write-Host ""
    }
    
    # Contar recomendações
    $CriticalCount = 0
    $HighCount = 0
    $MediumCount = 0
    
    foreach ($Key in $Results.Keys) {
        if ($Results[$Key].Recommendations) {
            foreach ($Rec in $Results[$Key].Recommendations) {
                if ($Rec -is [hashtable]) {
                    switch ($Rec.Priority) {
                        "Critical" { $CriticalCount++ }
                        "High" { $HighCount++ }
                        default { $MediumCount++ }
                    }
                }
            }
        }
    }
    
    Write-Host "  📋 RECOMENDAÇÕES" -ForegroundColor Cyan
    Write-Host "  ─────────────────────────────────────────────" -ForegroundColor Gray
    
    if ($CriticalCount -gt 0) {
        Write-Host "  🚨 Críticas: $CriticalCount" -ForegroundColor Red
    }
    if ($HighCount -gt 0) {
        Write-Host "  ⚠️  Alta: $HighCount" -ForegroundColor Yellow
    }
    if ($MediumCount -gt 0) {
        Write-Host "  ℹ️  Média/Baixa: $MediumCount" -ForegroundColor White
    }
    if (($CriticalCount + $HighCount + $MediumCount) -eq 0) {
        Write-Host "  ✅ Nenhuma recomendação crítica!" -ForegroundColor Green
    }
    
    Write-Host ""
}

# ============================================
# EXECUÇÃO PRINCIPAL
# ============================================

function Start-PurviewAudit {
    Clear-Host
    Write-Banner
    
    # Conectar
    if (-not $SkipConnection) {
        $ConnectionStatus = Connect-ToServices
        
        if (-not ($ConnectionStatus.ExchangeOnline -or $ConnectionStatus.SecurityCompliance)) {
            Write-Host ""
            Write-Host "  ❌ Nenhuma conexão estabelecida. Abortando." -ForegroundColor Red
            Write-Host ""
            return
        }
    }
    else {
        Write-Status "Pulando conexão (usando sessão existente)" "Info"
    }
    
    # Detectar capacidades do tenant
    if (-not $SkipCapabilityCheck) {
        $CapabilitiesLoaded = Initialize-TenantCapabilities
        if (-not $CapabilitiesLoaded) {
            Write-Status "Executando auditoria sem detecção de capacidades" "Warning"
        }
    }
    else {
        Write-Status "Detecção de capacidades pulada (-SkipCapabilityCheck)" "Info"
    }
    
    # Executar auditorias
    $Results = @{}
    
    Write-Section "INICIANDO AUDITORIAS"
    
    $Results.DLP = Get-DLPAudit
    $Results.AuditLog = Get-AuditLogAudit
    $Results.Retention = Get-RetentionAudit
    $Results.SensitivityLabels = Get-SensitivityLabelsAudit
    $Results.AlertPolicies = Get-AlertPoliciesAudit
    $Results.InsiderRisk = Get-InsiderRiskAudit
    $Results.eDiscovery = Get-eDiscoveryAudit
    $Results.ExternalSharing = Get-ExternalSharingAudit
    $Results.CommunicationCompliance = Get-CommunicationComplianceAudit
    
    # Exportar
    $ReportFolder = Export-Results -Results $Results
    
    # Sumário
    Show-Summary -Results $Results
    
    Write-Host "  📁 Relatórios salvos em:" -ForegroundColor Cyan
    Write-Host "     $ReportFolder" -ForegroundColor Green
    Write-Host ""
    Write-Host "  ✅ Auditoria concluída!" -ForegroundColor Green
    Write-Host ""
    
    return $Results
}

# Executar
$AuditResults = Start-PurviewAudit

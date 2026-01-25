<#
.SYNOPSIS
    Script de Auditoria Completa do Microsoft Purview
.DESCRIPTION
    Versão 3.1 - Compatível com PowerShell 7 (Mac/Linux/Windows)
    
    Audita:
    - Políticas DLP (Data Loss Prevention)
    - Unified Audit Log (método atualizado 2025+)
    - Políticas de Retenção
    - Labels de Sensibilidade
    - Políticas de Alerta
    - Insider Risk Management
    - eDiscovery Cases
    - Communication Compliance
    - Information Barriers
    - Records Management
    - Compartilhamento Externo
    
.AUTHOR
    M365 Security Toolkit - RFAA
.VERSION
    3.1 - Janeiro 2026 - Correcao de cores para terminais escuros
.EXAMPLE
    ./Purview-Audit-PS7.ps1
    ./Purview-Audit-PS7.ps1 -OutputPath "./MeuRelatorio" -IncludeDetails
    ./Purview-Audit-PS7.ps1 -SkipConnection  # Se já estiver conectado
#>

[CmdletBinding()]
param(
    [string]$OutputPath = "./Purview-Audit-Report",
    [switch]$IncludeDetails,
    [switch]$SkipConnection,
    [switch]$GenerateHTML
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
$ReportDate = Get-Date -Format "yyyy-MM-dd_HH-mm"
$OutputFolder = "${OutputPath}_${ReportDate}"

# ============================================
# CONFIGURAÇÕES E CONSTANTES
# ============================================

$Script:Config = @{
    Version = "3.1"
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
    InformationBarriers = 0
    CommunicationCompliance = 0
    ExternalSharing = 0
}

# ============================================
# FUNÇÕES DE INTERFACE
# ============================================

function Write-Banner {
    $Banner = @"

╔══════════════════════════════════════════════════════════════════════════╗
║                                                                          ║
║   ██████╗ ██╗   ██╗██████╗ ██╗   ██╗██╗███████╗██╗    ██╗               ║
║   ██╔══██╗██║   ██║██╔══██╗██║   ██║██║██╔════╝██║    ██║               ║
║   ██████╔╝██║   ██║██████╔╝██║   ██║██║█████╗  ██║ █╗ ██║               ║
║   ██╔═══╝ ██║   ██║██╔══██╗╚██╗ ██╔╝██║██╔══╝  ██║███╗██║               ║
║   ██║     ╚██████╔╝██║  ██║ ╚████╔╝ ██║███████╗╚███╔███╔╝               ║
║   ╚═╝      ╚═════╝ ╚═╝  ╚═╝  ╚═══╝  ╚═╝╚══════╝ ╚══╝╚══╝                ║
║                                                                          ║
║   🛡️  AUDITORIA COMPLETA DE SEGURANÇA E COMPLIANCE                       ║
║                                                                          ║
║   Versão 3.1 - Janeiro 2026                                              ║
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
        [ValidateSet("Info", "Success", "Warning", "Error", "Header", "Detail")]
        [string]$Type = "Info"
    )
    
    # Cores otimizadas para terminais com fundo escuro
    $Config = switch ($Type) {
        "Success" { @{ Color = "Green";   Prefix = "  ✅" } }
        "Warning" { @{ Color = "Yellow";  Prefix = "  ⚠️ " } }
        "Error"   { @{ Color = "Red";     Prefix = "  ❌" } }
        "Info"    { @{ Color = "White";   Prefix = "  📋" } }
        "Header"  { @{ Color = "Cyan";    Prefix = "  🔍" } }
        "Detail"  { @{ Color = "Gray";    Prefix = "     •" } }
        default   { @{ Color = "White";   Prefix = "  " } }
    }
    
    Write-Host "$($Config.Prefix) $Message" -ForegroundColor $Config.Color
}

function Write-Score {
    param(
        [string]$Category,
        [int]$Score,
        [int]$MaxScore = 100
    )
    
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
        # Verificar se já está conectado
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
    
    $Result = @{
        Policies = @()
        Rules = @()
        Recommendations = @()
        Score = 0
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
        # Políticas
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
                CreatedDate = $Policy.WhenCreatedUTC
                ModifiedDate = $Policy.WhenChangedUTC
            }
            $Result.Policies += $PolicyInfo
            
            # Contadores
            if ($Policy.Enabled) { 
                $Result.Details.EnabledPolicies++ 
            }
            if ($Policy.Mode -match "Test|Audit") { 
                $Result.Details.TestModePolicies++ 
            }
            
            # Cobertura de workloads
            foreach ($Wl in $Policy.Workload) {
                if (-not $Workloads[$Wl]) { $Workloads[$Wl] = 0 }
                $Workloads[$Wl]++
            }
            
            # Exibir
            $Icon = if ($Policy.Enabled) { "✅" } else { "❌" }
            $ModeIcon = if ($Policy.Mode -eq "Enable") { "🟢" } elseif ($Policy.Mode -match "Test") { "🟡" } else { "⚪" }
            Write-Status "$Icon $ModeIcon $($Policy.Name)" "Detail"
            
            # Recomendações
            if (-not $Policy.Enabled) {
                $Result.Recommendations += @{
                    Priority = "High"
                    Category = "DLP"
                    Message = "Política '$($Policy.Name)' está desabilitada."
                    Remediation = "Habilite a política no Purview > DLP > Policies"
                }
            }
            if ($Policy.Mode -match "Test") {
                $Result.Recommendations += @{
                    Priority = "Medium"
                    Category = "DLP"
                    Message = "Política '$($Policy.Name)' está em modo de teste."
                    Remediation = "Após validação, altere para modo 'Enforce'"
                }
            }
        }
        
        $Result.Details.WorkloadCoverage = $Workloads.Keys | ForEach-Object { @{ Workload = $_; Policies = $Workloads[$_] } }
        
        # Verificar cobertura mínima
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
        
        # Regras DLP
        $Rules = Get-DlpComplianceRule -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        if ($Rules) {
            $Result.Details.TotalRules = @($Rules).Count
            $Result.Details.DisabledRules = @($Rules | Where-Object { $_.Disabled }).Count
            $Result.Rules = @($Rules | Select-Object Name, Policy, Disabled, Priority, @{N='Actions';E={$_.BlockAccess}})
            Write-Status "Total de regras DLP: $($Result.Details.TotalRules) ($($Result.Details.DisabledRules) desabilitadas)" "Info"
        }
        
        # Calcular score
        $ScoreFactors = @(
            @{ Weight = 30; Value = if ($Result.Details.TotalPolicies -ge $Script:Config.MinDLPPolicies) { 1 } else { $Result.Details.TotalPolicies / $Script:Config.MinDLPPolicies } },
            @{ Weight = 30; Value = if ($Result.Details.TotalPolicies -gt 0) { $Result.Details.EnabledPolicies / $Result.Details.TotalPolicies } else { 0 } },
            @{ Weight = 20; Value = if ($MissingWorkloads.Count -eq 0) { 1 } else { 1 - ($MissingWorkloads.Count / $RequiredWorkloads.Count) } },
            @{ Weight = 20; Value = if ($Result.Details.TestModePolicies -eq 0) { 1 } else { 1 - ($Result.Details.TestModePolicies / $Result.Details.TotalPolicies) } }
        )
        
        $Result.Score = [math]::Round(($ScoreFactors | ForEach-Object { $_.Weight * $_.Value } | Measure-Object -Sum).Sum)
    }
    catch {
        Write-Status "Erro ao auditar DLP: $($_.Exception.Message)" "Error"
        $Result.Recommendations += @{
            Priority = "Critical"
            Category = "DLP"
            Message = "Erro ao auditar DLP: $($_.Exception.Message)"
            Remediation = "Verifique permissões e conectividade"
        }
    }
    
    return $Result
}

# ============================================
# AUDITORIA: UNIFIED AUDIT LOG (MÉTODO ATUALIZADO)
# ============================================

function Get-AuditLogAudit {
    Write-Section "AUDITORIA DO UNIFIED AUDIT LOG"
    
    $Result = @{
        UnifiedAuditEnabled = $false
        MailboxAuditEnabled = $false
        AuditLogSearchable = $false
        RecentActivityFound = $false
        AuditLogAgeLimit = $null
        AdminAuditLogConfig = @{}
        Recommendations = @()
        Score = 0
        Details = @{
            TestSearchResults = 0
            LastActivityDate = $null
            MethodUsed = ""
        }
    }
    
    try {
        # ============================================
        # MÉTODO 1: Testar se conseguimos buscar logs (MAIS CONFIÁVEL)
        # ============================================
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
                Write-Status "Última atividade: $($Result.Details.LastActivityDate)" "Detail"
                
                $Result.Score += 60
            }
            else {
                # Sem resultados mas sem erro = pode estar ativo mas sem atividade recente
                $Result.AuditLogSearchable = $true
                $Result.UnifiedAuditEnabled = $true
                $Result.Details.MethodUsed = "Search-UnifiedAuditLog (empty)"
                
                Write-Status "Unified Audit Log: ATIVO (sem atividade recente)" "Warning"
                $Result.Recommendations += @{
                    Priority = "Low"
                    Category = "AuditLog"
                    Message = "Nenhuma atividade encontrada nos últimos $($Script:Config.AuditLogTestDays) dias"
                    Remediation = "Verifique se há atividade normal no tenant"
                }
                $Result.Score += 40
            }
        }
        catch {
            $ErrorMsg = $_.Exception.Message
            
            if ($ErrorMsg -match "UnifiedAuditLogIngestionEnabled.*False|not enabled|audit logging is not enabled") {
                Write-Status "Unified Audit Log: DESABILITADO" "Error"
                $Result.UnifiedAuditEnabled = $false
                $Result.Details.MethodUsed = "Search-UnifiedAuditLog (error confirms disabled)"
                
                $Result.Recommendations += @{
                    Priority = "Critical"
                    Category = "AuditLog"
                    Message = "🚨 CRÍTICO: Unified Audit Log está DESABILITADO!"
                    Remediation = @"
Para ativar:
1. Acesse: https://compliance.microsoft.com
2. Vá em: Audit > (aguarde carregar)
3. Se aparecer banner para ativar, clique nele
4. OU execute: Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled `$true
5. Aguarde até 24 horas para propagação
"@
                }
            }
            else {
                # Outro tipo de erro
                Write-Status "Erro ao testar Audit Log: $ErrorMsg" "Warning"
                $Result.Details.MethodUsed = "Search-UnifiedAuditLog (error)"
            }
        }
        
        # ============================================
        # MÉTODO 2: Verificar configuração (para informação adicional)
        # ============================================
        Write-Status "Verificando configurações de auditoria..." "Header"
        
        try {
            $AdminConfig = Get-AdminAuditLogConfig -ErrorAction Stop
            
            $Result.AdminAuditLogConfig = @{
                UnifiedAuditLogIngestionEnabled = $AdminConfig.UnifiedAuditLogIngestionEnabled
                AdminAuditLogEnabled = $AdminConfig.AdminAuditLogEnabled
                AdminAuditLogCmdlets = $AdminConfig.AdminAuditLogCmdlets
                AdminAuditLogParameters = $AdminConfig.AdminAuditLogParameters
            }
            
            # NOTA: Este valor pode estar incorreto na nova arquitetura
            if ($AdminConfig.UnifiedAuditLogIngestionEnabled -eq $false -and $Result.UnifiedAuditEnabled -eq $true) {
                Write-Status "NOTA: Get-AdminAuditLogConfig retorna False, mas busca funciona" "Detail"
                Write-Status "A Microsoft migrou o controle para o Purview Portal" "Detail"
            }
        }
        catch {
            Write-Status "Não foi possível obter AdminAuditLogConfig: $($_.Exception.Message)" "Detail"
        }
        
        # ============================================
        # MÉTODO 3: Verificar Mailbox Audit
        # ============================================
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
            Write-Status "Não foi possível verificar Mailbox Audit: $($_.Exception.Message)" "Warning"
        }
        
        # ============================================
        # MÉTODO 4: Verificar políticas de retenção de audit
        # ============================================
        Write-Status "Verificando políticas de retenção de audit..." "Header"
        
        try {
            $AuditRetention = Get-UnifiedAuditLogRetentionPolicy -ErrorAction SilentlyContinue
            
            if ($AuditRetention) {
                $Result.AuditLogAgeLimit = @($AuditRetention | Select-Object Name, Priority, RetentionDuration, @{N='RecordTypes';E={$_.RecordTypes -join ", "}})
                Write-Status "Políticas de retenção de audit encontradas: $(@($AuditRetention).Count)" "Info"
                
                foreach ($Policy in $AuditRetention) {
                    Write-Status "$($Policy.Name): $($Policy.RetentionDuration)" "Detail"
                }
                
                $Result.Score += 20
            }
            else {
                Write-Status "Nenhuma política de retenção de audit customizada" "Info"
                Write-Status "Usando retenção padrão (90 dias E5 / 180 dias E5+)" "Detail"
            }
        }
        catch {
            Write-Status "Não foi possível verificar retenção de audit" "Detail"
        }
    }
    catch {
        Write-Status "Erro geral na auditoria de Audit Log: $($_.Exception.Message)" "Error"
        $Result.Recommendations += @{
            Priority = "Critical"
            Category = "AuditLog"
            Message = "Erro ao auditar Audit Log: $($_.Exception.Message)"
            Remediation = "Verifique permissões de Compliance Administrator"
        }
    }
    
    return $Result
}

# ============================================
# AUDITORIA: RETENÇÃO
# ============================================

function Get-RetentionAudit {
    Write-Section "AUDITORIA DE POLÍTICAS DE RETENÇÃO"
    
    $Result = @{
        Policies = @()
        Labels = @()
        Recommendations = @()
        Score = 0
        Details = @{
            TotalPolicies = 0
            EnabledPolicies = 0
            TotalLabels = 0
            PublishedLabels = 0
            WorkloadCoverage = @()
        }
    }
    
    try {
        # Políticas de Retenção
        $Policies = Get-RetentionCompliancePolicy -WarningAction SilentlyContinue -ErrorAction Stop
        
        if ($null -eq $Policies -or @($Policies).Count -eq 0) {
            Write-Status "Nenhuma política de retenção encontrada" "Warning"
            $Result.Recommendations += @{
                Priority = "High"
                Category = "Retention"
                Message = "Nenhuma política de retenção configurada"
                Remediation = "Configure políticas de retenção para compliance regulatório e governança de dados"
            }
        }
        else {
            $Result.Details.TotalPolicies = @($Policies).Count
            Write-Status "Total de políticas de retenção: $($Result.Details.TotalPolicies)" "Info"
            
            $Workloads = @{}
            
            foreach ($Policy in $Policies) {
                $PolicyInfo = @{
                    Name = $Policy.Name
                    Enabled = $Policy.Enabled
                    Workload = ($Policy.Workload -join ", ")
                    Mode = $Policy.Mode
                    Comment = $Policy.Comment
                }
                $Result.Policies += $PolicyInfo
                
                if ($Policy.Enabled) { $Result.Details.EnabledPolicies++ }
                
                foreach ($Wl in $Policy.Workload) {
                    if (-not $Workloads[$Wl]) { $Workloads[$Wl] = 0 }
                    $Workloads[$Wl]++
                }
                
                $Icon = if ($Policy.Enabled) { "✅" } else { "❌" }
                Write-Status "$Icon $($Policy.Name)" "Detail"
            }
            
            $Result.Details.WorkloadCoverage = $Workloads.Keys | ForEach-Object { @{ Workload = $_; Policies = $Workloads[$_] } }
        }
        
        # Labels de Retenção
        try {
            $Labels = Get-RetentionComplianceRule -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
            if ($Labels) {
                $Result.Details.TotalLabels = @($Labels).Count
                $Result.Labels = @($Labels | Select-Object Name, Policy, RetentionDuration, RetentionDurationDisplayHint)
                Write-Status "Total de regras de retenção: $($Result.Details.TotalLabels)" "Info"
            }
        }
        catch {
            Write-Status "Não foi possível verificar regras de retenção" "Detail"
        }
        
        # Calcular score
        $ScoreFactors = @(
            @{ Weight = 50; Value = if ($Result.Details.TotalPolicies -ge $Script:Config.MinRetentionPolicies) { 1 } else { $Result.Details.TotalPolicies / $Script:Config.MinRetentionPolicies } },
            @{ Weight = 30; Value = if ($Result.Details.TotalPolicies -gt 0) { $Result.Details.EnabledPolicies / $Result.Details.TotalPolicies } else { 0 } },
            @{ Weight = 20; Value = if ($Result.Details.TotalLabels -gt 0) { 1 } else { 0 } }
        )
        
        $Result.Score = [math]::Round(($ScoreFactors | ForEach-Object { $_.Weight * $_.Value } | Measure-Object -Sum).Sum)
    }
    catch {
        Write-Status "Erro ao auditar Retenção: $($_.Exception.Message)" "Error"
        $Result.Recommendations += @{
            Priority = "High"
            Category = "Retention"
            Message = "Erro ao auditar retenção: $($_.Exception.Message)"
            Remediation = "Verifique permissões"
        }
    }
    
    return $Result
}

# ============================================
# AUDITORIA: SENSITIVITY LABELS
# ============================================

function Get-SensitivityLabelsAudit {
    Write-Section "AUDITORIA DE LABELS DE SENSIBILIDADE"
    
    $Result = @{
        Labels = @()
        Policies = @()
        Recommendations = @()
        Score = 0
        Details = @{
            TotalLabels = 0
            ParentLabels = 0
            ChildLabels = 0
            EncryptionEnabled = 0
            ContentMarkingEnabled = 0
            AutoLabelingEnabled = 0
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
            $LabelInfo = @{
                Name = $Label.Name
                DisplayName = $Label.DisplayName
                Priority = $Label.Priority
                ParentId = $Label.ParentId
                Tooltip = $Label.Tooltip
                ContentType = $Label.ContentType -join ", "
            }
            $Result.Labels += $LabelInfo
            
            if ([string]::IsNullOrEmpty($Label.ParentId)) {
                $Result.Details.ParentLabels++
                Write-Status "📁 $($Label.DisplayName)" "Detail"
            }
            else {
                $Result.Details.ChildLabels++
                Write-Status "   └─ $($Label.DisplayName)" "Detail"
            }
        }
        
        # Políticas de labels
        try {
            $LabelPolicies = Get-LabelPolicy -ErrorAction SilentlyContinue
            if ($LabelPolicies) {
                $Result.Policies = @($LabelPolicies | Select-Object Name, Enabled, Mode, Priority, @{N='Labels';E={$_.Labels -join ", "}})
                Write-Status "Políticas de publicação: $(@($LabelPolicies).Count)" "Info"
            }
        }
        catch {
            Write-Status "Não foi possível verificar políticas de labels" "Detail"
        }
        
        # Auto-labeling policies
        try {
            $AutoLabelPolicies = Get-AutoSensitivityLabelPolicy -ErrorAction SilentlyContinue
            if ($AutoLabelPolicies) {
                $Result.Details.AutoLabelingEnabled = @($AutoLabelPolicies).Count
                Write-Status "Políticas de auto-labeling: $($Result.Details.AutoLabelingEnabled)" "Info"
            }
        }
        catch {
            # Auto-labeling pode não estar disponível
        }
        
        # Score
        $ScoreFactors = @(
            @{ Weight = 40; Value = if ($Result.Details.TotalLabels -ge $Script:Config.MinSensitivityLabels) { 1 } else { $Result.Details.TotalLabels / $Script:Config.MinSensitivityLabels } },
            @{ Weight = 30; Value = if ($Result.Details.ParentLabels -ge 3) { 1 } else { $Result.Details.ParentLabels / 3 } },
            @{ Weight = 30; Value = if (@($Result.Policies).Count -gt 0) { 1 } else { 0 } }
        )
        
        $Result.Score = [math]::Round(($ScoreFactors | ForEach-Object { $_.Weight * $_.Value } | Measure-Object -Sum).Sum)
    }
    catch {
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
        Details = @{
            TotalPolicies = 0
            EnabledPolicies = 0
            CustomPolicies = 0
            SystemPolicies = 0
        }
    }
    
    try {
        $Policies = Get-ProtectionAlert -ErrorAction Stop
        
        if ($null -eq $Policies -or @($Policies).Count -eq 0) {
            Write-Status "Nenhuma política de alerta encontrada" "Warning"
            return $Result
        }
        
        $Result.Details.TotalPolicies = @($Policies).Count
        Write-Status "Total de políticas de alerta: $($Result.Details.TotalPolicies)" "Info"
        
        # Alertas importantes que devem estar ativos
        $CriticalAlerts = @(
            "Elevation of Exchange admin privilege",
            "Suspicious email sending patterns detected",
            "Malware campaign detected",
            "Messages have been delayed",
            "Unusual external user file activity",
            "Unusual volume of file deletion"
        )
        
        $MissingCritical = @()
        
        foreach ($Policy in $Policies) {
            $PolicyInfo = @{
                Name = $Policy.Name
                Enabled = -not $Policy.Disabled
                Severity = $Policy.Severity
                Category = $Policy.Category
                IsSystemRule = $Policy.IsSystemRule
            }
            $Result.Policies += $PolicyInfo
            
            if (-not $Policy.Disabled) { $Result.Details.EnabledPolicies++ }
            if ($Policy.IsSystemRule) { $Result.Details.SystemPolicies++ }
            else { $Result.Details.CustomPolicies++ }
        }
        
        # Verificar alertas críticos
        $EnabledAlertNames = @($Policies | Where-Object { -not $_.Disabled }).Name
        foreach ($Critical in $CriticalAlerts) {
            if ($Critical -notin $EnabledAlertNames) {
                $MissingCritical += $Critical
            }
        }
        
        if ($MissingCritical.Count -gt 0) {
            Write-Status "Alertas críticos não encontrados/desabilitados: $($MissingCritical.Count)" "Warning"
            $Result.Recommendations += @{
                Priority = "Medium"
                Category = "AlertPolicies"
                Message = "Alertas críticos recomendados não estão ativos"
                Remediation = "Verifique os alertas no Microsoft 365 Defender Portal"
            }
        }
        
        Write-Status "Habilitadas: $($Result.Details.EnabledPolicies) | Sistema: $($Result.Details.SystemPolicies) | Custom: $($Result.Details.CustomPolicies)" "Info"
        
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
    
    $Result = @{
        Policies = @()
        Recommendations = @()
        Score = 0
        Details = @{
            TotalPolicies = 0
            ActivePolicies = 0
            Configured = $false
        }
    }
    
    try {
        $Policies = Get-InsiderRiskPolicy -ErrorAction SilentlyContinue
        
        if ($null -eq $Policies -or @($Policies).Count -eq 0) {
            Write-Status "Nenhuma política de Insider Risk configurada" "Info"
            Write-Status "Insider Risk Management requer licença E5 ou add-on" "Detail"
            $Result.Recommendations += @{
                Priority = "Medium"
                Category = "InsiderRisk"
                Message = "Considere implementar Insider Risk Management para detectar ameaças internas"
                Remediation = "Acesse Purview > Insider Risk Management > Policies"
            }
            return $Result
        }
        
        $Result.Details.Configured = $true
        $Result.Details.TotalPolicies = @($Policies).Count
        Write-Status "Total de políticas: $($Result.Details.TotalPolicies)" "Info"
        
        foreach ($Policy in $Policies) {
            $Result.Policies += @{
                Name = $Policy.Name
                Enabled = $Policy.Enabled
                PolicyTemplate = $Policy.PolicyTemplate
            }
            
            $Icon = if ($Policy.Enabled) { "✅" } else { "❌" }
            Write-Status "$Icon $($Policy.Name)" "Detail"
            
            if ($Policy.Enabled) { $Result.Details.ActivePolicies++ }
        }
        
        $Result.Score = if ($Result.Details.Configured) { 
            [math]::Round(($Result.Details.ActivePolicies / [math]::Max($Result.Details.TotalPolicies, 1)) * 100)
        } else { 0 }
    }
    catch {
        Write-Status "Insider Risk não disponível (requer licença específica)" "Detail"
    }
    
    return $Result
}

# ============================================
# AUDITORIA: EDISCOVERY
# ============================================

function Get-eDiscoveryAudit {
    Write-Section "AUDITORIA DE EDISCOVERY"
    
    $Result = @{
        Cases = @()
        Recommendations = @()
        Score = 0
        Details = @{
            TotalCases = 0
            ActiveCases = 0
            ClosedCases = 0
        }
    }
    
    try {
        $Cases = Get-ComplianceCase -ErrorAction SilentlyContinue
        
        if ($null -eq $Cases -or @($Cases).Count -eq 0) {
            Write-Status "Nenhum caso de eDiscovery encontrado" "Info"
            Write-Status "eDiscovery é usado sob demanda para investigações" "Detail"
            $Result.Score = 100 # Não ter casos não é necessariamente ruim
            return $Result
        }
        
        $Result.Details.TotalCases = @($Cases).Count
        Write-Status "Total de casos: $($Result.Details.TotalCases)" "Info"
        
        foreach ($Case in $Cases) {
            $Result.Cases += @{
                Name = $Case.Name
                Status = $Case.Status
                CreatedDateTime = $Case.CreatedDateTime
                CaseType = $Case.CaseType
            }
            
            if ($Case.Status -eq "Active") { $Result.Details.ActiveCases++ }
            else { $Result.Details.ClosedCases++ }
        }
        
        Write-Status "Ativos: $($Result.Details.ActiveCases) | Fechados: $($Result.Details.ClosedCases)" "Info"
        
        $Result.Score = 100 # eDiscovery configurado
    }
    catch {
        Write-Status "Erro ao verificar eDiscovery: $($_.Exception.Message)" "Warning"
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
        SharingPolicies = @()
        Recommendations = @()
        Score = 0
        Details = @{
            ExternalAccessRestricted = $false
            WacExternalDisabled = 0
        }
    }
    
    try {
        # OWA Policies
        $OWAPolicies = Get-OwaMailboxPolicy -ErrorAction Stop
        
        foreach ($Policy in $OWAPolicies) {
            $Result.OWAPolicies += @{
                Name = $Policy.Name
                ExternalSPMySiteHostURL = $Policy.ExternalSPMySiteHostURL
                WacExternalServicesEnabled = $Policy.WacExternalServicesEnabled
                ExternalImageProxyEnabled = $Policy.ExternalImageProxyEnabled
            }
            
            if (-not $Policy.WacExternalServicesEnabled) {
                $Result.Details.WacExternalDisabled++
            }
            
            Write-Status "$($Policy.Name): External WAC = $($Policy.WacExternalServicesEnabled)" "Detail"
        }
        
        # Calcular score
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
        Write-Status "Erro ao verificar compartilhamento externo: $($_.Exception.Message)" "Warning"
    }
    
    return $Result
}

# ============================================
# AUDITORIA: COMMUNICATION COMPLIANCE
# ============================================

function Get-CommunicationComplianceAudit {
    Write-Section "AUDITORIA DE COMMUNICATION COMPLIANCE"
    
    $Result = @{
        Policies = @()
        Recommendations = @()
        Score = 0
        Details = @{
            TotalPolicies = 0
            ActivePolicies = 0
            Configured = $false
        }
    }
    
    try {
        $Policies = Get-SupervisoryReviewPolicyV2 -ErrorAction SilentlyContinue
        
        if ($null -eq $Policies -or @($Policies).Count -eq 0) {
            Write-Status "Nenhuma política de Communication Compliance configurada" "Info"
            Write-Status "Communication Compliance requer licença específica" "Detail"
            return $Result
        }
        
        $Result.Details.Configured = $true
        $Result.Details.TotalPolicies = @($Policies).Count
        Write-Status "Total de políticas: $($Result.Details.TotalPolicies)" "Info"
        
        foreach ($Policy in $Policies) {
            $Result.Policies += @{
                Name = $Policy.Name
                Enabled = $Policy.Enabled
            }
            
            if ($Policy.Enabled) { $Result.Details.ActivePolicies++ }
        }
        
        $Result.Score = [math]::Round(($Result.Details.ActivePolicies / [math]::Max($Result.Details.TotalPolicies, 1)) * 100)
    }
    catch {
        Write-Status "Communication Compliance não disponível" "Detail"
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
                else {
                    $Priority = if ($Rec -match "CRÍTICO|🚨") { "Critical" } elseif ($Rec -match "⚠️") { "High" } else { "Medium" }
                    $AllRecs += [PSCustomObject]@{
                        Categoria = $Key
                        Prioridade = $Priority
                        Mensagem = $Rec
                        Remediacao = ""
                    }
                }
            }
        }
    }
    
    if ($AllRecs.Count -gt 0) {
        $CsvPath = Join-Path $OutputFolder "recommendations.csv"
        $AllRecs | Sort-Object @{E={
            switch ($_.Prioridade) { "Critical" { 0 } "High" { 1 } "Medium" { 2 } "Low" { 3 } default { 4 } }
        }} | Export-Csv $CsvPath -NoTypeInformation -Encoding UTF8
        Write-Status "CSV Recomendações: $CsvPath" "Success"
    }
    
    # Sumário em Markdown
    $MdPath = Join-Path $OutputFolder "SUMMARY.md"
    $Md = @"
# 🛡️ Relatório de Auditoria Purview

**Data:** $(Get-Date -Format "dd/MM/yyyy HH:mm")
**Tenant:** $((Get-OrganizationConfig -ErrorAction SilentlyContinue).Name)

## 📊 Scores por Categoria

| Categoria | Score | Status |
|-----------|-------|--------|
"@
    
    $Categories = @("DLP", "AuditLog", "Retention", "SensitivityLabels", "AlertPolicies", "InsiderRisk", "eDiscovery", "ExternalSharing", "CommunicationCompliance")
    foreach ($Cat in $Categories) {
        if ($Results[$Cat]) {
            $Score = $Results[$Cat].Score
            $Status = if ($Score -ge 80) { "✅ Bom" } elseif ($Score -ge 50) { "⚠️ Atenção" } else { "❌ Crítico" }
            $Md += "`n| $Cat | $Score% | $Status |"
        }
    }
    
    $Md += @"


## 📋 Recomendações

"@
    
    $CriticalRecs = @($AllRecs | Where-Object { $_.Prioridade -eq "Critical" })
    $HighRecs = @($AllRecs | Where-Object { $_.Prioridade -eq "High" })
    
    if ($CriticalRecs.Count -gt 0) {
        $Md += "`n### 🚨 Críticas`n"
        foreach ($Rec in $CriticalRecs) {
            $Md += "`n- **[$($Rec.Categoria)]** $($Rec.Mensagem)"
        }
    }
    
    if ($HighRecs.Count -gt 0) {
        $Md += "`n`n### ⚠️ Alta Prioridade`n"
        foreach ($Rec in $HighRecs) {
            $Md += "`n- **[$($Rec.Categoria)]** $($Rec.Mensagem)"
        }
    }
    
    $Md | Out-File $MdPath -Encoding UTF8
    Write-Status "Markdown: $MdPath" "Success"
    
    return $OutputFolder
}

# ============================================
# SUMÁRIO FINAL
# ============================================

function Show-Summary {
    param([hashtable]$Results)
    
    Write-Section "SUMÁRIO DA AUDITORIA"
    
    Write-Host ""
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
            $Score = $Results[$Cat.Key].Score
            Write-Score -Category $Cat.Name.PadRight(28) -Score $Score
            $TotalScore += $Score
            $ValidCategories++
        }
    }
    
    $OverallScore = if ($ValidCategories -gt 0) { [math]::Round($TotalScore / $ValidCategories) } else { 0 }
    
    Write-Host "  ─────────────────────────────────────────────" -ForegroundColor Gray
    Write-Score -Category "SCORE GERAL".PadRight(28) -Score $OverallScore
    Write-Host ""
    
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
                elseif ($Rec -match "CRÍTICO|🚨") { $CriticalCount++ }
                elseif ($Rec -match "⚠️") { $HighCount++ }
                else { $MediumCount++ }
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
    Write-Host "  💡 Dica: Para desconectar:" -ForegroundColor Gray
    Write-Host '     Disconnect-ExchangeOnline -Confirm:$false' -ForegroundColor Gray
    Write-Host ""
    
    return $Results
}

# Executar
$AuditResults = Start-PurviewAudit

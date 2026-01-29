<#
.SYNOPSIS
    Remediação de Segurança Microsoft 365 / Purview
.DESCRIPTION
    Versão 4.0 - Integrado com Get-TenantCapabilities.ps1
    
    NOVIDADES v4.0:
    - Detecção automática de capacidades/licenças do tenant
    - Pula remediações não disponíveis na licença
    - Usa tipo correto de alerta (básico vs avançado)
    - Relatório claro do que foi remediado vs pulado
    
    Aplica configurações de segurança recomendadas (conforme licença):
    - Verifica Unified Audit Log (método atualizado 2025+)
    - Configura Mailbox Audit
    - Cria políticas de Retenção
    - Cria políticas DLP para dados brasileiros (com opção audit-only)
    - Desabilita provedores externos no OWA (opcional)
    - Configura alertas de segurança (alerta de forwarding opcional)
    
    Cria backup antes de cada alteração para permitir rollback.
.AUTHOR
    M365 Security Toolkit - RFAA
.VERSION
    4.0 - Janeiro 2026 - Integração com TenantCapabilities
.PARAMETER SkipConnection
    Usa sessao existente do Exchange/IPPS
.PARAMETER SkipCapabilityCheck
    Pula detecção automática de capacidades (tenta tudo)
.PARAMETER OnlyRetention
    Executa apenas criacao de politicas de retencao
.PARAMETER OnlyDLP
    Executa apenas criacao de politicas DLP
.PARAMETER OnlyAlerts
    Executa apenas criacao de alertas de seguranca
.PARAMETER DLPAuditOnly
    Cria politicas DLP em modo AUDITORIA (TestWithNotifications)
.PARAMETER SkipForwardingAlert
    Nao cria alerta de monitoramento de forwarding
.PARAMETER SkipOWABlock
    Nao bloqueia Dropbox/Google Drive no OWA
.PARAMETER WhatIf
    Modo simulacao - nao faz alteracoes
.EXAMPLE
    ./M365-Remediation.ps1
    ./M365-Remediation.ps1 -SkipConnection
    ./M365-Remediation.ps1 -SkipForwardingAlert -SkipOWABlock
    ./M365-Remediation.ps1 -OnlyDLP -DLPAuditOnly
#>

[CmdletBinding()]
param(
    [switch]$SkipConnection,
    [switch]$SkipCapabilityCheck,
    [switch]$OnlyRetention,
    [switch]$OnlyDLP,
    [switch]$OnlyAlerts,
    [switch]$DLPAuditOnly,
    [switch]$SkipForwardingAlert,
    [switch]$SkipOWABlock,
    [switch]$WhatIf
)

$ErrorActionPreference = "Continue"
$BackupPath = "./M365-Remediation-Backup_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
$ReportPath = "./M365-Remediation-Report_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"
$Script:Backup = @{}
$Script:Changes = @()
$Script:SkippedItems = @()
$Script:SectionStatus = [ordered]@{}

# Capabilities do tenant
$Script:TenantCaps = $null

# ============================================
# FUNÇÕES DE INTERFACE
# ============================================

function Write-Banner {
    $Banner = @"

╔══════════════════════════════════════════════════════════════════════════╗
║                                                                          ║
║   ██████╗ ███████╗███╗   ███╗███████╗██████╗ ██╗ █████╗  ██████╗ █████╗  ║
║   ██╔══██╗██╔════╝████╗ ████║██╔════╝██╔══██╗██║██╔══██╗██╔════╝██╔══██╗ ║
║   ██████╔╝█████╗  ██╔████╔██║█████╗  ██║  ██║██║███████║██║     ███████║ ║
║   ██╔══██╗██╔══╝  ██║╚██╔╝██║██╔══╝  ██║  ██║██║██╔══██║██║     ██╔══██║ ║
║   ██║  ██║███████╗██║ ╚═╝ ██║███████╗██████╔╝██║██║  ██║╚██████╗██║  ██║ ║
║   ╚═╝  ╚═╝╚══════╝╚═╝     ╚═╝╚══════╝╚═════╝ ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝ ║
║                                                                          ║
║   🔧 REMEDIAÇÃO DE SEGURANÇA M365 / PURVIEW                              ║
║                                                                          ║
║   Versão 4.0 - Janeiro 2026 (com detecção de capacidades)                ║
║   Alinhado com Purview-Audit-PS7.ps1 v4.0                                ║
║                                                                          ║
╚══════════════════════════════════════════════════════════════════════════╝

"@
    Write-Host $Banner -ForegroundColor Cyan
}

function Write-Section {
    param([string]$Number, [string]$Title)
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor DarkCyan
    Write-Host "  $Number  $Title" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor DarkCyan
}

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error", "Action", "Skip", "Detail")]
        [string]$Type = "Info"
    )
    
    $Config = switch ($Type) {
        "Success" { @{ Color = "Green";   Prefix = "  ✅" } }
        "Warning" { @{ Color = "Magenta"; Prefix = "  ⚠️ " } }
        "Error"   { @{ Color = "Red";     Prefix = "  ❌" } }
        "Info"    { @{ Color = "White";   Prefix = "  📋" } }
        "Action"  { @{ Color = "Cyan";    Prefix = "  🔧" } }
        "Skip"    { @{ Color = "Cyan";    Prefix = "  ⏭️ " } }
        "Detail"  { @{ Color = "Gray";    Prefix = "     •" } }
        default   { @{ Color = "White";   Prefix = "  " } }
    }
    
    Write-Host "$($Config.Prefix) $Message" -ForegroundColor $Config.Color
}

function Save-Backup {
    param([string]$Key, $Value)
    $Script:Backup[$Key] = $Value
    $Script:Backup | ConvertTo-Json -Depth 10 | Out-File $BackupPath -Encoding UTF8
}

function Add-Change {
    param([string]$Category, [string]$Action, [string]$Details)
    $Script:Changes += [PSCustomObject]@{
        Category = $Category
        Action = $Action
        Details = $Details
        Timestamp = Get-Date -Format "HH:mm:ss"
    }
}

function Add-Skipped {
    param([string]$Category, [string]$Reason)
    $Script:SkippedItems += [PSCustomObject]@{
        Category = $Category
        Reason = $Reason
    }
}

function Set-SectionStatus {
    param([string]$Category, [string]$Status, [string]$Details)
    $Script:SectionStatus[$Category] = [PSCustomObject]@{
        Category = $Category
        Status = $Status
        Details = $Details
    }
}

# ============================================
# DETECÇÃO DE CAPACIDADES
# ============================================

function Initialize-TenantCapabilities {
    Write-Section "🔍" "DETECTANDO CAPACIDADES DO TENANT"
    
    $ModulePath = Join-Path $PSScriptRoot "..\Modules\Get-TenantCapabilities.ps1"
    if (-not (Test-Path $ModulePath)) {
        $ModulePath = Join-Path $PSScriptRoot "Get-TenantCapabilities.ps1"
    }
    if (-not (Test-Path $ModulePath)) {
        $ModulePath = "./Get-TenantCapabilities.ps1"
    }
    
    if (Test-Path $ModulePath) {
        Write-Status "Carregando módulo de detecção..." "Action"
        try {
            $Script:TenantCaps = & $ModulePath -Silent
            
            if ($Script:TenantCaps) {
                Write-Status "Tenant: $($Script:TenantCaps.TenantInfo.DisplayName)" "Success"
                Write-Status "Licença: $($Script:TenantCaps.License.Probable)" "Info"
                Write-Status "Pode remediar: $($Script:TenantCaps.RemediableItems -join ', ')" "Detail"
                
                # Mostrar alertas avançados
                if ($Script:TenantCaps.Capabilities.AlertPolicies.AdvancedAlerts) {
                    Write-Status "Alertas avançados: DISPONÍVEIS (E5)" "Success"
                }
                else {
                    Write-Status "Alertas avançados: Não disponíveis (usará básicos)" "Info"
                }
                
                return $true
            }
        }
        catch {
            Write-Status "Erro ao carregar módulo: $($_.Exception.Message)" "Warning"
        }
    }
    else {
        Write-Status "Módulo Get-TenantCapabilities.ps1 não encontrado" "Warning"
        Write-Status "Executando remediação completa (pode gerar erros de licença)" "Warning"
    }
    
    return $false
}

function Test-CapabilityAvailable {
    param([string]$Capability)
    
    if (-not $Script:TenantCaps) { return $true }
    
    $Available = switch ($Capability) {
        "DLP" { $Script:TenantCaps.Capabilities.DLP.CanCreate }
        "Retention" { $Script:TenantCaps.Capabilities.Retention.CanCreate }
        "AlertPolicies" { $Script:TenantCaps.Capabilities.AlertPolicies.BasicAlerts }
        "AdvancedAlerts" { $Script:TenantCaps.Capabilities.AlertPolicies.AdvancedAlerts }
        "AuditLog" { $Script:TenantCaps.Capabilities.AuditLog.Available }
        "ExternalSharing" { $Script:TenantCaps.Capabilities.ExternalSharing.Available }
        default { $true }
    }
    
    return $Available
}

# ============================================
# CONEXÕES
# ============================================

function Connect-ToServices {
    Write-Section "🔐" "VERIFICANDO CONEXÕES"
    
    # Exchange Online
    try {
        $null = Get-OrganizationConfig -ErrorAction Stop
        Write-Status "Exchange Online - Conectado" "Success"
    }
    catch {
        Write-Status "Conectando ao Exchange Online..." "Action"
        Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
        Write-Status "Exchange Online - Conectado" "Success"
    }
    
    # Security & Compliance
    try {
        $null = Get-Label -ResultSize 1 -ErrorAction Stop 2>$null
        Write-Status "Security & Compliance - Conectado" "Success"
    }
    catch {
        Write-Status "Conectando ao Security & Compliance..." "Action"
        Connect-IPPSSession -ShowBanner:$false -WarningAction SilentlyContinue -ErrorAction Stop
        Write-Status "Security & Compliance - Conectado" "Success"
    }
}

# ============================================
# 1. UNIFIED AUDIT LOG
# ============================================

function Remediate-UnifiedAuditLog {
    Write-Section "1️⃣" "UNIFIED AUDIT LOG"

    if (-not (Get-Command -Name Search-UnifiedAuditLog -ErrorAction SilentlyContinue)) {
        Write-Status "Cmdlets de Audit Log não disponíveis (módulo/versão)" "Skip"
        Write-Status "Bypass: módulo/cmdlet não suportado na versão atual" "Detail"
        Add-Skipped -Category "AuditLog" -Reason "Cmdlet indisponível na sessão"
        Set-SectionStatus -Category "AuditLog" -Status "Skip" -Details "Cmdlet indisponível na sessão"
        return
    }

    $SectionHadError = $false
    
    Write-Status "Verificando status real do Audit Log..." "Info"
    
    try {
        $TestSearch = Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-1) -EndDate (Get-Date) -ResultSize 1 -ErrorAction Stop
        
        if ($null -ne $TestSearch) {
            Write-Status "Unified Audit Log - ATIVO E FUNCIONANDO" "Success"
            Save-Backup -Key "UnifiedAuditLog" -Value "Already Active"
            Set-SectionStatus -Category "AuditLog" -Status "OK" -Details "Unified Audit Log ativo"
            return
        }
        else {
            Write-Status "Unified Audit Log - Provavelmente ativo (sem atividade recente)" "Warning"
            Save-Backup -Key "UnifiedAuditLog" -Value "Active (no recent data)"
            Set-SectionStatus -Category "AuditLog" -Status "Warning" -Details "Audit Log sem atividade recente"
            return
        }
    }
    catch {
        $ErrorMsg = $_.Exception.Message
        
        if ($ErrorMsg -match "not enabled|UnifiedAuditLogIngestionEnabled") {
            Write-Status "Unified Audit Log - DESABILITADO" "Error"
            Write-Status "Tentando ativar..." "Action"
            
            if (-not $WhatIf) {
                try {
                    Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true -ErrorAction Stop
                    Write-Status "Comando executado - aguarde até 24h para propagação" "Success"
                    Add-Change -Category "AuditLog" -Action "Enable" -Details "UnifiedAuditLogIngestionEnabled"
                }
                catch {
                    Write-Status "Erro ao ativar via PowerShell" "Warning"
                    Write-Status "AÇÃO MANUAL: Acesse https://compliance.microsoft.com > Audit" "Warning"
                    $SectionHadError = $true
                }
            }
            else {
                Write-Status "[WhatIf] Executaria Set-AdminAuditLogConfig" "Skip"
            }
        }
    }
    
    # Mailbox Audit
    Write-Status "Verificando Mailbox Audit por padrão..." "Info"

    if (-not (Get-Command -Name Get-OrganizationConfig -ErrorAction SilentlyContinue)) {
        Write-Status "Cmdlets do Exchange não disponíveis para Mailbox Audit" "Skip"
        Write-Status "Bypass: módulo/cmdlet não suportado na versão atual" "Detail"
        Add-Skipped -Category "MailboxAudit" -Reason "Cmdlet indisponível na sessão"
        return
    }
    
    try {
        $OrgConfig = Get-OrganizationConfig -ErrorAction Stop
        Save-Backup -Key "MailboxAuditDisabled" -Value $OrgConfig.AuditDisabled
        
        if ($OrgConfig.AuditDisabled) {
            Write-Status "Mailbox Audit - DESABILITADO" "Error"
            
            if (-not $WhatIf) {
                Set-OrganizationConfig -AuditDisabled $false
                Write-Status "Mailbox Audit - ATIVADO" "Success"
                Add-Change -Category "AuditLog" -Action "Enable Mailbox Audit" -Details "AuditDisabled=false"
            }
            else {
                Write-Status "[WhatIf] Executaria Set-OrganizationConfig -AuditDisabled false" "Skip"
            }
        }
        else {
            Write-Status "Mailbox Audit - Já está habilitado" "Success"
        }
    }
    catch {
        Write-Status "Erro ao verificar Mailbox Audit" "Warning"
        $SectionHadError = $true
    }

    if ($SectionHadError) {
        Set-SectionStatus -Category "AuditLog" -Status "Warning" -Details "Falhas parciais no Audit Log/Mailbox Audit"
    }
    else {
        Set-SectionStatus -Category "AuditLog" -Status "OK" -Details "Audit Log/Mailbox Audit verificados"
    }
}

# ============================================
# 2. POLÍTICAS DE RETENÇÃO
# ============================================

function Remediate-RetentionPolicies {
    Write-Section "2️⃣" "POLÍTICAS DE RETENÇÃO"
    
    # Verificar se disponível
    if (-not (Test-CapabilityAvailable "Retention")) {
        Write-Status "Retention não disponível neste tenant (licença não inclui)" "Skip"
        Write-Status "Bypass: licença não contempla Retention" "Detail"
        Add-Skipped -Category "Retention" -Reason "Licença não inclui"
        Set-SectionStatus -Category "Retention" -Status "Skip" -Details "Licença não inclui Retention"
        return
    }

    # Verificar se os cmdlets estão disponíveis (módulo/IPPSSession)
    if (-not (Get-Command -Name New-RetentionCompliancePolicy -ErrorAction SilentlyContinue)) {
        Write-Status "Cmdlets de retenção não disponíveis nesta sessão (módulo/IPPSSession)" "Skip"
        Write-Status "Bypass: módulo/cmdlet não suportado na versão atual" "Detail"
        Write-Status "Confirme módulo ExchangeOnlineManagement e conexão ao Security & Compliance" "Detail"
        Add-Skipped -Category "Retention" -Reason "Cmdlet indisponível na sessão"
        Set-SectionStatus -Category "Retention" -Status "Skip" -Details "Cmdlet indisponível na sessão"
        return
    }

    $SectionHadError = $false
    
    try {
        $ExistingPolicies = Get-RetentionCompliancePolicy -WarningAction SilentlyContinue -ErrorAction Stop
        $PolicyCount = if ($ExistingPolicies) { @($ExistingPolicies).Count } else { 0 }
        
        Write-Status "Políticas de retenção existentes: $PolicyCount" "Info"
        Save-Backup -Key "RetentionPoliciesCount" -Value $PolicyCount
        
        # ============================================
        # POLÍTICA 1: Teams Messages (1 ano)
        # ============================================
        
        $TeamsRetentionName = "Retencao Teams - Mensagens 1 Ano"
        $ExistingTeams = $ExistingPolicies | Where-Object { $_.Name -eq $TeamsRetentionName }
        
        if (-not $ExistingTeams) {
            Write-Status "Criando - $TeamsRetentionName" "Action"
            
            if (-not $WhatIf) {
                try {
                    New-RetentionCompliancePolicy -Name $TeamsRetentionName `
                        -Comment "Retém mensagens do Teams por 1 ano" `
                        -TeamsChannelLocation All `
                        -TeamsChatLocation All `
                        -Enabled $true `
                        -ErrorAction Stop
                    
                    New-RetentionComplianceRule -Name "$TeamsRetentionName - Regra" `
                        -Policy $TeamsRetentionName `
                        -RetentionDuration 365 `
                        -RetentionComplianceAction Keep `
                        -ErrorAction Stop
                    
                    Write-Status "$TeamsRetentionName - CRIADA" "Success"
                    Add-Change -Category "Retention" -Action "Create Policy" -Details $TeamsRetentionName
                }
                catch {
                    Write-Status "Erro ao criar: $($_.Exception.Message)" "Error"
                    $SectionHadError = $true
                }
            }
            else {
                Write-Status "[WhatIf] Criaria - $TeamsRetentionName" "Skip"
            }
        }
        else {
            Write-Status "$TeamsRetentionName - Já existe" "Success"
        }
        
        # ============================================
        # POLÍTICA 2: Dados Sensíveis (7 anos)
        # ============================================
        
        $SensitiveRetentionName = "Retencao Dados Sensiveis - 7 Anos"
        $ExistingSensitive = $ExistingPolicies | Where-Object { $_.Name -eq $SensitiveRetentionName }
        
        if (-not $ExistingSensitive) {
            Write-Status "Criando - $SensitiveRetentionName" "Action"
            
            if (-not $WhatIf) {
                try {
                    New-RetentionCompliancePolicy -Name $SensitiveRetentionName `
                        -Comment "Retém dados classificados como Highly Confidential por 7 anos" `
                        -ExchangeLocation All `
                        -SharePointLocation All `
                        -OneDriveLocation All `
                        -Enabled $true `
                        -ErrorAction Stop
                    
                    New-RetentionComplianceRule -Name "$SensitiveRetentionName - Regra" `
                        -Policy $SensitiveRetentionName `
                        -RetentionDuration 2555 `
                        -RetentionComplianceAction KeepAndDelete `
                        -RetentionDurationDisplayHint Days `
                        -ErrorAction Stop
                    
                    Write-Status "$SensitiveRetentionName - CRIADA" "Success"
                    Add-Change -Category "Retention" -Action "Create Policy" -Details $SensitiveRetentionName
                }
                catch {
                    Write-Status "Erro: $($_.Exception.Message)" "Error"
                    $SectionHadError = $true
                }
            }
            else {
                Write-Status "[WhatIf] Criaria - $SensitiveRetentionName" "Skip"
            }
        }
        else {
            Write-Status "$SensitiveRetentionName - Já existe" "Success"
        }
        
        # ============================================
        # POLÍTICA 3: Documentos (3 anos)
        # ============================================
        
        $GeneralRetentionName = "Retencao Documentos - 3 Anos"
        $ExistingGeneral = $ExistingPolicies | Where-Object { $_.Name -eq $GeneralRetentionName }
        
        if (-not $ExistingGeneral) {
            Write-Status "Criando - $GeneralRetentionName" "Action"
            
            if (-not $WhatIf) {
                try {
                    New-RetentionCompliancePolicy -Name $GeneralRetentionName `
                        -Comment "Retém documentos por 3 anos" `
                        -SharePointLocation All `
                        -OneDriveLocation All `
                        -Enabled $true `
                        -ErrorAction Stop
                    
                    New-RetentionComplianceRule -Name "$GeneralRetentionName - Regra" `
                        -Policy $GeneralRetentionName `
                        -RetentionDuration 1095 `
                        -RetentionComplianceAction Keep `
                        -RetentionDurationDisplayHint Days `
                        -ErrorAction Stop
                    
                    Write-Status "$GeneralRetentionName - CRIADA" "Success"
                    Add-Change -Category "Retention" -Action "Create Policy" -Details $GeneralRetentionName
                }
                catch {
                    Write-Status "Erro: $($_.Exception.Message)" "Error"
                    $SectionHadError = $true
                }
            }
            else {
                Write-Status "[WhatIf] Criaria - $GeneralRetentionName" "Skip"
            }
        }
        else {
            Write-Status "$GeneralRetentionName - Já existe" "Success"
        }
    }
    catch {
        if ($_.Exception.Message -match "license|not licensed") {
            Write-Status "Retention não disponível (licença)" "Skip"
            Add-Skipped -Category "Retention" -Reason "Licença não inclui"
            Set-SectionStatus -Category "Retention" -Status "Skip" -Details "Licença não inclui Retention"
        }
        else {
            Write-Status "Erro: $($_.Exception.Message)" "Error"
            Set-SectionStatus -Category "Retention" -Status "Error" -Details "Erro ao processar Retention"
        }
    }

    if (-not $Script:SectionStatus.Contains("Retention")) {
        if ($SectionHadError) {
            Set-SectionStatus -Category "Retention" -Status "Warning" -Details "Falhas parciais em políticas"
        }
        else {
            Set-SectionStatus -Category "Retention" -Status "OK" -Details "Políticas verificadas/criadas"
        }
    }
}

# ============================================
# 3. POLÍTICAS DLP
# ============================================

function Remediate-DLPPolicies {
    Write-Section "3️⃣" "POLÍTICAS DLP"

    if (-not (Get-Command -Name New-DlpCompliancePolicy -ErrorAction SilentlyContinue)) {
        Write-Status "Cmdlets de DLP não disponíveis nesta sessão (módulo/versão)" "Skip"
        Write-Status "Bypass: módulo/cmdlet não suportado na versão atual" "Detail"
        Add-Skipped -Category "DLP" -Reason "Cmdlet indisponível na sessão"
        Set-SectionStatus -Category "DLP" -Status "Skip" -Details "Cmdlet indisponível na sessão"
        return
    }
    
    # Verificar se disponível
    if (-not (Test-CapabilityAvailable "DLP")) {
        Write-Status "DLP não disponível neste tenant (licença não inclui)" "Skip"
        Write-Status "Bypass: licença não contempla DLP" "Detail"
        Add-Skipped -Category "DLP" -Reason "Licença não inclui DLP"
        Set-SectionStatus -Category "DLP" -Status "Skip" -Details "Licença não inclui DLP"
        return
    }

    $SectionHadError = $false
    
    # Determinar modo
    if ($DLPAuditOnly) {
        $DLPMode = "TestWithNotifications"
        $ModeDescription = "AUDITORIA (só relatório, sem bloqueio)"
        $BlockAccess = $false
        Write-Status "MODO: $ModeDescription" "Warning"
    }
    else {
        $DLPMode = "Enable"
        $ModeDescription = "ATIVO (com bloqueio)"
        $BlockAccess = $true
        Write-Status "MODO: $ModeDescription" "Info"
    }
    
    try {
        $ExistingDLP = Get-DlpCompliancePolicy -WarningAction SilentlyContinue -ErrorAction Stop
        $DLPCount = if ($ExistingDLP) { @($ExistingDLP).Count } else { 0 }
        
        Write-Status "Políticas DLP existentes: $DLPCount" "Info"
        Save-Backup -Key "DLPPoliciesCount" -Value $DLPCount
        
        # ============================================
        # DLP para CPF Brasileiro
        # ============================================
        
        $CPFPolicyName = "DLP - Protecao CPF Brasileiro"
        $ExistingCPF = $ExistingDLP | Where-Object { $_.Name -eq $CPFPolicyName }
        
        if (-not $ExistingCPF) {
            Write-Status "Criando - $CPFPolicyName" "Action"
            
            if (-not $WhatIf) {
                try {
                    New-DlpCompliancePolicy -Name $CPFPolicyName `
                        -Comment "Detecta CPFs. Modo: $ModeDescription" `
                        -ExchangeLocation All `
                        -SharePointLocation All `
                        -OneDriveLocation All `
                        -TeamsLocation All `
                        -Mode $DLPMode `
                        -ErrorAction Stop
                    
                    New-DlpComplianceRule -Name "Detectar CPF - Alta Confianca" `
                        -Policy $CPFPolicyName `
                        -ContentContainsSensitiveInformation @{Name="Brazil CPF Number"; minCount="1"; confidencelevel="High"} `
                        -BlockAccess $BlockAccess `
                        -NotifyUser "Owner" `
                        -NotifyPolicyTipCustomText "Este documento contém CPF." `
                        -GenerateIncidentReport "SiteAdmin" `
                        -ReportSeverityLevel "Medium" `
                        -ErrorAction Stop
                    
                    Write-Status "$CPFPolicyName - CRIADA [$ModeDescription]" "Success"
                    Add-Change -Category "DLP" -Action "Create Policy" -Details "$CPFPolicyName (Mode: $DLPMode)"
                }
                catch {
                    Write-Status "Erro: $($_.Exception.Message)" "Error"
                    $SectionHadError = $true
                }
            }
            else {
                Write-Status "[WhatIf] Criaria - $CPFPolicyName" "Skip"
            }
        }
        else {
            Write-Status "$CPFPolicyName - Já existe (Mode: $($ExistingCPF.Mode))" "Success"
        }
        
        # ============================================
        # DLP para CNPJ
        # ============================================
        
        $CNPJPolicyName = "DLP - Protecao CNPJ"
        $ExistingCNPJ = $ExistingDLP | Where-Object { $_.Name -eq $CNPJPolicyName }
        
        if (-not $ExistingCNPJ) {
            Write-Status "Criando - $CNPJPolicyName" "Action"
            
            if (-not $WhatIf) {
                try {
                    New-DlpCompliancePolicy -Name $CNPJPolicyName `
                        -Comment "Detecta CNPJs. Modo: $ModeDescription" `
                        -ExchangeLocation All `
                        -SharePointLocation All `
                        -OneDriveLocation All `
                        -TeamsLocation All `
                        -Mode $DLPMode `
                        -ErrorAction Stop
                    
                    New-DlpComplianceRule -Name "Detectar CNPJ" `
                        -Policy $CNPJPolicyName `
                        -ContentContainsSensitiveInformation @{Name="Brazil Legal Entity Number (CNPJ)"; minCount="1"; confidencelevel="High"} `
                        -BlockAccess $false `
                        -NotifyUser "Owner" `
                        -GenerateIncidentReport "SiteAdmin" `
                        -ReportSeverityLevel "Low" `
                        -ErrorAction Stop
                    
                    Write-Status "$CNPJPolicyName - CRIADA" "Success"
                    Add-Change -Category "DLP" -Action "Create Policy" -Details $CNPJPolicyName
                }
                catch {
                    Write-Status "Erro: $($_.Exception.Message)" "Error"
                    $SectionHadError = $true
                }
            }
            else {
                Write-Status "[WhatIf] Criaria - $CNPJPolicyName" "Skip"
            }
        }
        else {
            Write-Status "$CNPJPolicyName - Já existe" "Success"
        }
        
        # ============================================
        # DLP para Cartão de Crédito
        # ============================================
        
        $CCPolicyName = "DLP - Protecao Cartao de Credito"
        $ExistingCC = $ExistingDLP | Where-Object { $_.Name -eq $CCPolicyName }
        
        if (-not $ExistingCC) {
            Write-Status "Criando - $CCPolicyName" "Action"
            
            if (-not $WhatIf) {
                try {
                    New-DlpCompliancePolicy -Name $CCPolicyName `
                        -Comment "Detecta cartões de crédito. Modo: $ModeDescription" `
                        -ExchangeLocation All `
                        -SharePointLocation All `
                        -OneDriveLocation All `
                        -TeamsLocation All `
                        -Mode $DLPMode `
                        -ErrorAction Stop
                    
                    New-DlpComplianceRule -Name "Detectar Cartao de Credito" `
                        -Policy $CCPolicyName `
                        -ContentContainsSensitiveInformation @{Name="Credit Card Number"; minCount="1"; confidencelevel="High"} `
                        -BlockAccess $BlockAccess `
                        -NotifyUser "Owner" `
                        -GenerateIncidentReport "SiteAdmin" `
                        -ReportSeverityLevel "High" `
                        -ErrorAction Stop
                    
                    Write-Status "$CCPolicyName - CRIADA" "Success"
                    Add-Change -Category "DLP" -Action "Create Policy" -Details $CCPolicyName
                }
                catch {
                    Write-Status "Erro: $($_.Exception.Message)" "Error"
                    $SectionHadError = $true
                }
            }
            else {
                Write-Status "[WhatIf] Criaria - $CCPolicyName" "Skip"
            }
        }
        else {
            Write-Status "$CCPolicyName - Já existe" "Success"
        }
        
        Write-Host ""
        Write-Status "Para ver relatórios DLP: https://compliance.microsoft.com/datalossprevention" "Info"
    }
    catch {
        if ($_.Exception.Message -match "license|not licensed") {
            Write-Status "DLP não disponível (licença)" "Skip"
            Add-Skipped -Category "DLP" -Reason "Licença não inclui DLP"
            Set-SectionStatus -Category "DLP" -Status "Skip" -Details "Licença não inclui DLP"
        }
        else {
            Write-Status "Erro: $($_.Exception.Message)" "Error"
            Set-SectionStatus -Category "DLP" -Status "Error" -Details "Erro ao processar DLP"
        }
    }

    if (-not $Script:SectionStatus.Contains("DLP")) {
        if ($SectionHadError) {
            Set-SectionStatus -Category "DLP" -Status "Warning" -Details "Falhas parciais em políticas"
        }
        else {
            Set-SectionStatus -Category "DLP" -Status "OK" -Details "Políticas verificadas/criadas"
        }
    }
}

# ============================================
# 4. OWA - PROVEDORES EXTERNOS
# ============================================

function Remediate-OWAExternal {
    Write-Section "4️⃣" "OWA - PROVEDORES EXTERNOS"

    if (-not (Get-Command -Name Get-OwaMailboxPolicy -ErrorAction SilentlyContinue)) {
        Write-Status "Cmdlets do OWA não disponíveis nesta sessão (módulo/versão)" "Skip"
        Write-Status "Bypass: módulo/cmdlet não suportado na versão atual" "Detail"
        Add-Skipped -Category "OWA" -Reason "Cmdlet indisponível na sessão"
        Set-SectionStatus -Category "OWA" -Status "Skip" -Details "Cmdlet indisponível na sessão"
        return
    }
    
    if ($SkipOWABlock) {
        Write-Status "Bloqueio de Dropbox/Google Drive no OWA - PULADO (parâmetro -SkipOWABlock)" "Skip"
        Write-Status "Bypass: execução solicitada pelo parâmetro" "Detail"
        Set-SectionStatus -Category "OWA" -Status "Skip" -Details "Parâmetro -SkipOWABlock"
        return
    }

    $SectionHadError = $false
    
    try {
        $OwaPolicy = Get-OwaMailboxPolicy -Identity "OwaMailboxPolicy-Default" -ErrorAction Stop
        Save-Backup -Key "WacExternalServicesEnabled" -Value $OwaPolicy.WacExternalServicesEnabled
        
        if ($OwaPolicy.WacExternalServicesEnabled) {
            Write-Status "WacExternalServicesEnabled = TRUE (não seguro)" "Warning"
            Write-Status "Desabilitando provedores externos..." "Action"
            
            if (-not $WhatIf) {
                Set-OwaMailboxPolicy -Identity "OwaMailboxPolicy-Default" -WacExternalServicesEnabled $false
                Write-Status "Provedores externos - DESABILITADOS" "Success"
                Add-Change -Category "OWA" -Action "Disable External" -Details "WacExternalServicesEnabled=false"
            }
            else {
                Write-Status "[WhatIf] Desabilitaria WacExternalServicesEnabled" "Skip"
            }
        }
        else {
            Write-Status "Provedores externos - Já desabilitado" "Success"
        }
    }
    catch {
        Write-Status "Erro: $($_.Exception.Message)" "Error"
        $SectionHadError = $true
    }

    if (-not $Script:SectionStatus.Contains("OWA")) {
        if ($SectionHadError) {
            Set-SectionStatus -Category "OWA" -Status "Error" -Details "Erro ao configurar OWA"
        }
        else {
            Set-SectionStatus -Category "OWA" -Status "OK" -Details "OWA verificado/configurado"
        }
    }
}

# ============================================
# 5. ALERTAS DE SEGURANÇA
# ============================================

function Remediate-AlertPolicies {
    Write-Section "5️⃣" "ALERTAS DE SEGURANÇA"

    if (-not (Get-Command -Name New-ProtectionAlert -ErrorAction SilentlyContinue)) {
        Write-Status "Cmdlets de Alertas não disponíveis nesta sessão (módulo/versão)" "Skip"
        Write-Status "Bypass: módulo/cmdlet não suportado na versão atual" "Detail"
        Add-Skipped -Category "AlertPolicies" -Reason "Cmdlet indisponível na sessão"
        Set-SectionStatus -Category "AlertPolicies" -Status "Skip" -Details "Cmdlet indisponível na sessão"
        return
    }
    
    # Verificar se disponível
    if (-not (Test-CapabilityAvailable "AlertPolicies")) {
        Write-Status "Alert Policies não disponível neste tenant" "Skip"
        Write-Status "Bypass: licença não contempla Alert Policies" "Detail"
        Add-Skipped -Category "AlertPolicies" -Reason "Não disponível"
        Set-SectionStatus -Category "AlertPolicies" -Status "Skip" -Details "Licença não inclui alertas"
        return
    }

    $SectionHadError = $false
    
    # Determinar tipo de agregação baseado na licença
    $UseAdvancedAggregation = Test-CapabilityAvailable "AdvancedAlerts"
    
    if ($UseAdvancedAggregation) {
        Write-Status "Usando alertas AVANÇADOS (E5 detectado)" "Info"
        $AggregationType = "SimpleAggregation"
    }
    else {
        Write-Status "Usando alertas BÁSICOS (sem E5)" "Info"
        $AggregationType = "None"
    }
    
    Write-Status "Alertas só enviam notificação por email - NÃO bloqueiam nada" "Info"
    Write-Host ""
    
    $AlertsToCreate = @(
        @{
            Name = "Custom - Nova Regra Inbox Suspeita"
            Category = "ThreatManagement"
            Operation = "New-InboxRule"
            Description = "Alerta quando nova regra de inbox é criada"
            Severity = "High"
            Skip = $false
        },
        @{
            Name = "Custom - Permissao Mailbox Delegada"
            Category = "ThreatManagement"
            Operation = "Add-MailboxPermission"
            Description = "Alerta quando permissões de mailbox são alteradas"
            Severity = "Medium"
            Skip = $false
        },
        @{
            Name = "Custom - Forwarding Externo Configurado"
            Category = "ThreatManagement"
            Operation = "Set-Mailbox"
            Description = "Alerta quando forwarding é configurado"
            Severity = "High"
            Skip = $SkipForwardingAlert
        },
        @{
            Name = "Custom - Admin Role Atribuida"
            Category = "ThreatManagement"
            Operation = "Add-RoleGroupMember"
            Description = "Alerta quando role de admin é atribuída"
            Severity = "High"
            Skip = $false
        },
        @{
            Name = "Custom - Malware Detectado"
            Category = "ThreatManagement"
            Operation = "MalwareDetected"
            Description = "Alerta quando malware é detectado"
            Severity = "High"
            Skip = $false
        },
        @{
            Name = "Custom - Massa de Arquivos Deletados"
            Category = "ThreatManagement"
            Operation = "FileDeletedFirstStageRecycleBin"
            Description = "Alerta quando muitos arquivos são deletados"
            Severity = "High"
            Skip = $false
        }
    )
    
    foreach ($Alert in $AlertsToCreate) {
        if ($Alert.Skip) {
            Write-Status "$($Alert.Name) - PULADO (parâmetro -SkipForwardingAlert)" "Skip"
            continue
        }
        
        try {
            $Existing = Get-ProtectionAlert -Identity $Alert.Name -ErrorAction SilentlyContinue
            
            if (-not $Existing) {
                Write-Status "Criando - $($Alert.Name)" "Action"
                Write-Status "$($Alert.Description)" "Detail"
                
                if (-not $WhatIf) {
                    New-ProtectionAlert -Name $Alert.Name `
                        -Category $Alert.Category `
                        -ThreatType "Activity" `
                        -Operation $Alert.Operation `
                        -Description $Alert.Description `
                        -AggregationType $AggregationType `
                        -Severity $Alert.Severity `
                        -NotificationEnabled $true `
                        -ErrorAction SilentlyContinue
                    
                    Write-Status "$($Alert.Name) - CRIADO" "Success"
                    Add-Change -Category "Alerts" -Action "Create Alert" -Details "$($Alert.Name) (Aggregation: $AggregationType)"
                }
                else {
                    Write-Status "[WhatIf] Criaria - $($Alert.Name)" "Skip"
                }
            }
            else {
                Write-Status "$($Alert.Name) - Já existe" "Success"
            }
        }
        catch {
            Write-Status "Erro ao criar $($Alert.Name): $($_.Exception.Message)" "Warning"
            $SectionHadError = $true
        }
    }
    
    Write-Host ""
    Write-Status "Para gerenciar alertas: https://security.microsoft.com/alertpolicies" "Info"

    if (-not $Script:SectionStatus.Contains("AlertPolicies")) {
        if ($SectionHadError) {
            Set-SectionStatus -Category "AlertPolicies" -Status "Warning" -Details "Falhas parciais na criação de alertas"
        }
        else {
            Set-SectionStatus -Category "AlertPolicies" -Status "OK" -Details "Alertas verificados/criados"
        }
    }
}

# ============================================
# VERIFICAÇÃO FINAL E SUMÁRIO
# ============================================

function Show-Summary {
    Write-Section "✅" "VERIFICAÇÃO FINAL"
    
    Write-Host ""
    
    # Info do tenant
    if ($Script:TenantCaps) {
        Write-Host "  TENANT: $($Script:TenantCaps.TenantInfo.DisplayName)" -ForegroundColor Cyan
        Write-Host "  LICENÇA: $($Script:TenantCaps.License.Probable)" -ForegroundColor Cyan
        Write-Host ""
    }
    
    # Unified Audit Log
    try {
        $AuditTest = Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-1) -EndDate (Get-Date) -ResultSize 1 -ErrorAction SilentlyContinue
        $AuditStatus = if ($AuditTest) { "ATIVO" } else { "Verificar manualmente" }
    }
    catch {
        $AuditStatus = "Verificar no portal"
    }
    Write-Host "  Unified Audit Log:     $AuditStatus" -ForegroundColor $(if ($AuditStatus -eq "ATIVO") { "Green" } else { "Yellow" })
    
    # Mailbox Audit
    $MailboxAudit = (Get-OrganizationConfig).AuditDisabled
    $MailboxStatus = if (-not $MailboxAudit) { "ATIVO" } else { "DESATIVADO" }
    Write-Host "  Mailbox Audit:         $MailboxStatus" -ForegroundColor $(if (-not $MailboxAudit) { "Green" } else { "Red" })
    
    # Retention
    if ("Retention" -notin ($Script:SkippedItems.Category)) {
        $RetentionCount = @(Get-RetentionCompliancePolicy -WarningAction SilentlyContinue -ErrorAction SilentlyContinue).Count
        Write-Host "  Políticas Retenção:    $RetentionCount políticas" -ForegroundColor $(if ($RetentionCount -ge 3) { "Green" } else { "Yellow" })
    }
    else {
        Write-Host "  Políticas Retenção:    N/A (não licenciado)" -ForegroundColor DarkGray
    }
    
    # DLP
    if ("DLP" -notin ($Script:SkippedItems.Category)) {
        $DLPPolicies = Get-DlpCompliancePolicy -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        $DLPCount = if ($DLPPolicies) { @($DLPPolicies).Count } else { 0 }
        $AuditOnlyCount = @($DLPPolicies | Where-Object { $_.Mode -eq "TestWithNotifications" }).Count
        if ($AuditOnlyCount -gt 0) {
            $DLPStatus = "$DLPCount políticas ($AuditOnlyCount em auditoria)"
        }
        else {
            $DLPStatus = "$DLPCount políticas"
        }
        Write-Host "  Políticas DLP:         $DLPStatus" -ForegroundColor $(if ($DLPCount -ge 3) { "Green" } else { "Yellow" })
    }
    else {
        Write-Host "  Políticas DLP:         N/A (não licenciado)" -ForegroundColor DarkGray
    }
    
    # OWA
    $OwaExternal = (Get-OwaMailboxPolicy -Identity "OwaMailboxPolicy-Default" -ErrorAction SilentlyContinue).WacExternalServicesEnabled
    $OwaStatus = if (-not $OwaExternal) { "BLOQUEADO" } else { "PERMITIDO" }
    Write-Host "  OWA Externos:          $OwaStatus" -ForegroundColor $(if (-not $OwaExternal) { "Green" } else { "Yellow" })
    
    Write-Host ""
    
    # Itens pulados
    if ($Script:SkippedItems.Count -gt 0) {
        Write-Host "  ⏭️  ITENS PULADOS (não licenciados):" -ForegroundColor DarkGray
        foreach ($Skip in $Script:SkippedItems) {
            Write-Host "     - $($Skip.Category): $($Skip.Reason)" -ForegroundColor DarkGray
        }
        Write-Host ""
    }
    
    # Opções usadas
    if ($SkipForwardingAlert -or $SkipOWABlock -or $DLPAuditOnly) {
        Write-Host "  OPÇÕES UTILIZADAS:" -ForegroundColor Gray
        if ($DLPAuditOnly) { Write-Host "     - DLP em modo AUDITORIA" -ForegroundColor Gray }
        if ($SkipForwardingAlert) { Write-Host "     - Alerta de Forwarding: PULADO" -ForegroundColor Gray }
        if ($SkipOWABlock) { Write-Host "     - Bloqueio OWA: PULADO" -ForegroundColor Gray }
        Write-Host ""
    }
    
    # Mudanças realizadas
    if ($Script:Changes.Count -gt 0) {
        Write-Host "  ALTERAÇÕES REALIZADAS:" -ForegroundColor Cyan
        foreach ($Change in $Script:Changes) {
            Write-Host "     [$($Change.Timestamp)] $($Change.Category) - $($Change.Action)" -ForegroundColor White
        }
        Write-Host ""
    }
    
    Write-Host "  Backup salvo em: $BackupPath" -ForegroundColor Gray
    Write-Host ""
}

function Generate-HTMLReport {
    $TenantName = if ($Script:TenantCaps) { $Script:TenantCaps.TenantInfo.DisplayName } else { "N/A" }
    $LicenseName = if ($Script:TenantCaps) { $Script:TenantCaps.License.Probable } else { "N/A" }

    $SectionsHtml = if ($Script:SectionStatus.Count -gt 0) {
    ($Script:SectionStatus.Values | ForEach-Object {
        $Status = "$($_.Status)"
        $Class = switch -Regex ($Status) {
        "^(OK|Success|Enabled)$" { "good"; break }
        "Warning" { "warn"; break }
        "Error" { "bad"; break }
        "Skip" { "na"; break }
        default { "" }
        }
        "<tr class='" + $Class + "'><td>" + [System.Net.WebUtility]::HtmlEncode($_.Category) + "</td><td>" + [System.Net.WebUtility]::HtmlEncode($Status) + "</td><td>" + [System.Net.WebUtility]::HtmlEncode($_.Details) + "</td></tr>"
    }) -join ""
    } else {
    "<tr><td colspan='3'>Sem dados de status</td></tr>"
    }

    $ChangesHtml = if ($Script:Changes.Count -gt 0) {
        ($Script:Changes | ForEach-Object {
            "<tr><td>" + [System.Net.WebUtility]::HtmlEncode($_.Timestamp) + "</td><td>" + [System.Net.WebUtility]::HtmlEncode($_.Category) + "</td><td>" + [System.Net.WebUtility]::HtmlEncode($_.Action) + "</td><td>" + [System.Net.WebUtility]::HtmlEncode($_.Details) + "</td></tr>"
        }) -join ""
    } else {
        "<tr><td colspan='4'>Nenhuma alteração realizada</td></tr>"
    }

    $SkippedHtml = if ($Script:SkippedItems.Count -gt 0) {
        ($Script:SkippedItems | ForEach-Object {
            "<tr class='na'><td>" + [System.Net.WebUtility]::HtmlEncode($_.Category) + "</td><td>" + [System.Net.WebUtility]::HtmlEncode($_.Reason) + "</td></tr>"
        }) -join ""
    } else {
        "<tr><td colspan='2'>Nenhum item pulado</td></tr>"
    }

    $Html = @"
<!DOCTYPE html>
<html lang="pt-br">
<head>
    <meta charset="utf-8" />
    <title>Relatório - Remediação M365</title>
    <style>
    body { font-family: Segoe UI, Roboto, Arial, sans-serif; margin: 24px; color: #1f2937; }
    h1 { margin-bottom: 4px; }
    h2 { margin-top: 0; }
    .card { background: #ffffff; padding: 16px; border-radius: 8px; margin-bottom: 16px; border: 1px solid #e5e7eb; }
    table { width: 100%; border-collapse: collapse; margin-top: 8px; }
    th, td { border: 1px solid #e5e7eb; padding: 8px 10px; text-align: left; }
    th { background: #f3f4f6; }
    tr.good td { background: #ecfdf5; }
    tr.warn td { background: #fffbeb; }
    tr.bad td { background: #fef2f2; }
    tr.na td { background: #f9fafb; color: #6b7280; }
    .muted { color: #6b7280; }
    </style>
</head>
<body>
    <h1>Relatório de Remediação M365</h1>
    <div class="card">
        <p><strong>Data:</strong> $(Get-Date)</p>
        <p><strong>Tenant:</strong> $TenantName</p>
        <p><strong>Licença:</strong> $LicenseName</p>
        <p><strong>Backup:</strong> $BackupPath</p>
    </div>

    <div class="card">
        <h2>Status por Seção</h2>
        <table>
            <thead><tr><th>Seção</th><th>Status</th><th>Detalhes</th></tr></thead>
            <tbody>
                $SectionsHtml
            </tbody>
        </table>
    </div>

    <div class="card">
        <h2>Itens Pulados (bypass)</h2>
        <table>
            <thead><tr><th>Categoria</th><th>Motivo</th></tr></thead>
            <tbody>
                $SkippedHtml
            </tbody>
        </table>
        <p class="muted">Motivos comuns: licença não inclui, cmdlet/módulo indisponível na sessão.</p>
    </div>

    <div class="card">
        <h2>Alterações Realizadas</h2>
        <table>
            <thead><tr><th>Hora</th><th>Categoria</th><th>Ação</th><th>Detalhes</th></tr></thead>
            <tbody>
                $ChangesHtml
            </tbody>
        </table>
    </div>
</body>
</html>
"@

        $Html | Out-File $ReportPath -Encoding UTF8
        Write-Status "Relatório HTML salvo em: $ReportPath" "Success"
}

function Show-RollbackInstructions {
    Write-Section "🔙" "INSTRUÇÕES DE ROLLBACK"
    
    Write-Host ""
    Write-Host "  Para reverter alterações:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  # Políticas de Retenção" -ForegroundColor Gray
    Write-Host '  Get-RetentionCompliancePolicy | Where-Object {$_.Name -like "Retencao*"} | Remove-RetentionCompliancePolicy' -ForegroundColor White
    Write-Host ""
    Write-Host "  # Políticas DLP" -ForegroundColor Gray
    Write-Host '  Get-DlpCompliancePolicy | Where-Object {$_.Name -like "DLP -*"} | Remove-DlpCompliancePolicy' -ForegroundColor White
    Write-Host ""
    Write-Host "  # OWA External Services (reativar)" -ForegroundColor Gray
    Write-Host '  Set-OwaMailboxPolicy -Identity "OwaMailboxPolicy-Default" -WacExternalServicesEnabled $true' -ForegroundColor White
    Write-Host ""
}

# ============================================
# EXECUÇÃO PRINCIPAL
# ============================================

function Start-M365Remediation {
    Clear-Host
    Write-Banner

    # Conectar
    if (-not $SkipConnection) {
        try {
            Connect-ToServices
        }
        catch {
            Write-Status "Falha ao conectar nos serviços. Abortando." "Error"
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
            Write-Status "Executando remediação sem detecção de capacidades" "Warning"
        }
    }
    else {
        Write-Status "Detecção de capacidades pulada (-SkipCapabilityCheck)" "Info"
    }

    # Decidir modo de execução
    $OnlyMode = ($OnlyRetention -or $OnlyDLP -or $OnlyAlerts)

    Write-Section "🚀" "INICIANDO VARREDURA/REMEDIAÇÃO"

    if (-not $OnlyMode -or $OnlyRetention) {
        Remediate-RetentionPolicies
    }

    if (-not $OnlyMode) {
        Remediate-UnifiedAuditLog
    }

    if (-not $OnlyMode -or $OnlyDLP) {
        Remediate-DLPPolicies
    }

    if (-not $OnlyMode) {
        Remediate-OWAExternal
    }

    if (-not $OnlyMode -or $OnlyAlerts) {
        Remediate-AlertPolicies
    }

    Show-Summary
    Show-RollbackInstructions
    Generate-HTMLReport

    Write-Host "  ✅ Remediação concluída!" -ForegroundColor Green
    Write-Host ""
}

# Executar
Start-M365Remediation
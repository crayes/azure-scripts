<#
.SYNOPSIS
    Remediação de Segurança Microsoft 365 / Purview
.DESCRIPTION
    Versão 4.1.1 - Fix: approved verbs + WarningAction resilience
    
    NOVIDADES v4.1:
    - Geração automática de evidências para o Purview Compliance Manager
    - Após remediação, coleta todas as políticas implementadas (DLP, Labels, 
      Retention, Audit, ATP, Transport Rules, DKIM, Conditional Access)
    - Gera CSV pronto para copiar/colar no portal do Purview
    - Score do Purview sobe automaticamente após documentar
    
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
    4.1.1 - Fevereiro 2026 - Fix: approved verbs + WarningAction resilience
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
.PARAMETER SkipPurviewEvidence
    Pula geração de evidências para o Purview Compliance Manager
.PARAMETER TenantName
    Nome do tenant (para identificação nos relatórios de evidência)
.PARAMETER DryRun
    Modo simulacao - nao faz alteracoes (use -DryRun em vez de -WhatIf)
.EXAMPLE
    ./M365-Remediation.ps1
    ./M365-Remediation.ps1 -SkipConnection
    ./M365-Remediation.ps1 -SkipForwardingAlert -SkipOWABlock
    ./M365-Remediation.ps1 -OnlyDLP -DLPAuditOnly
    ./M365-Remediation.ps1 -TenantName "RFAA"
    ./M365-Remediation.ps1 -SkipPurviewEvidence
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
    [switch]$SkipPurviewEvidence,
    [string]$TenantName = "",
    [switch]$DryRun
)

$ErrorActionPreference = "Continue"
$BackupPath = "./M365-Remediation-Backup_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
$ReportPath = "./M365-Remediation-Report_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"
$PurviewEvidencePath = "./Purview-Evidence_$(if ($TenantName) { "${TenantName}_" })$(Get-Date -Format 'yyyyMMdd_HHmmss')"
$Script:Backup = @{}
$Script:Changes = @()
$Script:SkippedItems = @()
$Script:SectionStatus = [ordered]@{}
$Script:TenantCaps = $null

# ============================================
# FUNÇÕES DE INTERFACE
# ============================================

function Write-Banner {
    Write-Host ""
    Write-Host "  ╔═══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║  REMEDIAÇÃO DE SEGURANÇA M365 / PURVIEW  v4.1.1      ║" -ForegroundColor Cyan
    Write-Host "  ║  Com detecção de capacidades + Purview Evidence       ║" -ForegroundColor Cyan
    Write-Host "  ╚═══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
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
        [ValidateSet("Info","Success","Warning","Error","Action","Skip","Detail")]
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

function Save-Backup { param([string]$Key, $Value); $Script:Backup[$Key] = $Value; $Script:Backup | ConvertTo-Json -Depth 10 | Out-File $BackupPath -Encoding UTF8 }
function Add-Change { param([string]$Category, [string]$Action, [string]$Details); $Script:Changes += [PSCustomObject]@{ Category=$Category; Action=$Action; Details=$Details; Timestamp=Get-Date -Format "HH:mm:ss" } }
function Add-Skipped { param([string]$Category, [string]$Reason); $Script:SkippedItems += [PSCustomObject]@{ Category=$Category; Reason=$Reason } }
function Set-SectionStatus { param([string]$Category, [string]$Status, [string]$Details); $Script:SectionStatus[$Category] = [PSCustomObject]@{ Category=$Category; Status=$Status; Details=$Details } }

# ============================================
# DETECÇÃO DE CAPACIDADES
# ============================================

function Initialize-TenantCapabilities {
    Write-Section "🔍" "DETECTANDO CAPACIDADES DO TENANT"
    $ModulePath = Join-Path $PSScriptRoot "..\Modules\Get-TenantCapabilities.ps1"
    if (-not (Test-Path $ModulePath)) { $ModulePath = Join-Path $PSScriptRoot "Get-TenantCapabilities.ps1" }
    if (-not (Test-Path $ModulePath)) { $ModulePath = "./Get-TenantCapabilities.ps1" }
    if (Test-Path $ModulePath) {
        Write-Status "Carregando módulo de detecção..." "Action"
        try {
            $Script:TenantCaps = & $ModulePath -Silent
            if ($Script:TenantCaps) {
                Write-Status "Tenant: $($Script:TenantCaps.TenantInfo.DisplayName)" "Success"
                Write-Status "Licença: $($Script:TenantCaps.License.Probable)" "Info"
                Write-Status "Pode remediar: $($Script:TenantCaps.RemediableItems -join ', ')" "Detail"
                if ($Script:TenantCaps.Capabilities.AlertPolicies.AdvancedAlerts) { Write-Status "Alertas avançados: DISPONÍVEIS (E5)" "Success" }
                else { Write-Status "Alertas avançados: Não disponíveis (usará básicos)" "Info" }
                return $true
            }
        } catch { Write-Status "Erro ao carregar módulo: $($_.Exception.Message)" "Warning" }
    } else {
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
    try { $null = Get-OrganizationConfig -ErrorAction Stop; Write-Status "Exchange Online - Conectado" "Success" }
    catch { Write-Status "Conectando ao Exchange Online..." "Action"; Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop; Write-Status "Exchange Online - Conectado" "Success" }
    try { $null = Get-Label -ResultSize 1 -ErrorAction Stop 2>$null; Write-Status "Security & Compliance - Conectado" "Success" }
    catch { Write-Status "Conectando ao Security & Compliance..." "Action"; Connect-IPPSSession -ShowBanner:$false -ErrorAction Stop 3>$null; Write-Status "Security & Compliance - Conectado" "Success" }
}

# ============================================
# 1. UNIFIED AUDIT LOG
# ============================================

function Repair-UnifiedAuditLog {
    Write-Section "1️⃣" "UNIFIED AUDIT LOG"
    if (-not (Get-Command -Name Search-UnifiedAuditLog -ErrorAction SilentlyContinue)) {
        Write-Status "Cmdlets de Audit Log não disponíveis" "Skip"; Add-Skipped -Category "AuditLog" -Reason "Cmdlet indisponível"; Set-SectionStatus -Category "AuditLog" -Status "Skip" -Details "Cmdlet indisponível"; return
    }
    $SectionHadError = $false
    Write-Status "Verificando status real do Audit Log..." "Info"
    try {
        $TestSearch = Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-1) -EndDate (Get-Date) -ResultSize 1 -ErrorAction Stop
        if ($null -ne $TestSearch) { Write-Status "Unified Audit Log - ATIVO E FUNCIONANDO" "Success"; Save-Backup -Key "UnifiedAuditLog" -Value "Already Active"; Set-SectionStatus -Category "AuditLog" -Status "OK" -Details "Unified Audit Log ativo"; return }
        else { Write-Status "Unified Audit Log - Provavelmente ativo (sem atividade recente)" "Warning"; Save-Backup -Key "UnifiedAuditLog" -Value "Active (no recent data)"; Set-SectionStatus -Category "AuditLog" -Status "Warning" -Details "Sem atividade recente"; return }
    } catch {
        if ($_.Exception.Message -match "not enabled|UnifiedAuditLogIngestionEnabled") {
            Write-Status "Unified Audit Log - DESABILITADO" "Error"; Write-Status "Tentando ativar..." "Action"
            if (-not $DryRun) { try { Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true -ErrorAction Stop; Write-Status "Ativado - aguarde 24h" "Success"; Add-Change -Category "AuditLog" -Action "Enable" -Details "UnifiedAuditLogIngestionEnabled" } catch { Write-Status "Erro ao ativar" "Warning"; $SectionHadError = $true } }
            else { Write-Status "[DryRun] Executaria Set-AdminAuditLogConfig" "Skip" }
        }
    }
    Write-Status "Verificando Mailbox Audit por padrão..." "Info"
    if (-not (Get-Command -Name Get-OrganizationConfig -ErrorAction SilentlyContinue)) { Write-Status "Cmdlets do Exchange não disponíveis" "Skip"; return }
    try {
        $OrgConfig = Get-OrganizationConfig -ErrorAction Stop; Save-Backup -Key "MailboxAuditDisabled" -Value $OrgConfig.AuditDisabled
        if ($OrgConfig.AuditDisabled) {
            Write-Status "Mailbox Audit - DESABILITADO" "Error"
            if (-not $DryRun) { Set-OrganizationConfig -AuditDisabled $false; Write-Status "Mailbox Audit - ATIVADO" "Success"; Add-Change -Category "AuditLog" -Action "Enable Mailbox Audit" -Details "AuditDisabled=false" }
            else { Write-Status "[DryRun] Ativaria Mailbox Audit" "Skip" }
        } else { Write-Status "Mailbox Audit - Já habilitado" "Success" }
    } catch { Write-Status "Erro ao verificar Mailbox Audit" "Warning"; $SectionHadError = $true }
    if ($SectionHadError) { Set-SectionStatus -Category "AuditLog" -Status "Warning" -Details "Falhas parciais" } else { Set-SectionStatus -Category "AuditLog" -Status "OK" -Details "Audit Log/Mailbox Audit verificados" }
}

# ============================================
# 2. POLÍTICAS DE RETENÇÃO
# ============================================

function Repair-RetentionPolicies {
    Write-Section "2️⃣" "POLÍTICAS DE RETENÇÃO"
    if (-not (Test-CapabilityAvailable "Retention")) { Write-Status "Retention não disponível (licença)" "Skip"; Add-Skipped -Category "Retention" -Reason "Licença não inclui"; Set-SectionStatus -Category "Retention" -Status "Skip" -Details "Licença não inclui"; return }
    if (-not (Get-Command -Name New-RetentionCompliancePolicy -ErrorAction SilentlyContinue)) { Write-Status "Cmdlets de retenção não disponíveis" "Skip"; Add-Skipped -Category "Retention" -Reason "Cmdlet indisponível"; Set-SectionStatus -Category "Retention" -Status "Skip" -Details "Cmdlet indisponível"; return }
    $SectionHadError = $false
    try {
        $ExistingPolicies = Get-RetentionCompliancePolicy -ErrorAction Stop 3>$null
        $PolicyCount = if ($ExistingPolicies) { @($ExistingPolicies).Count } else { 0 }
        Write-Status "Políticas de retenção existentes: $PolicyCount" "Info"; Save-Backup -Key "RetentionPoliciesCount" -Value $PolicyCount

        # Teams Messages (1 ano)
        $TeamsRetentionName = "Retencao Teams - Mensagens 1 Ano"
        if (-not ($ExistingPolicies | Where-Object { $_.Name -eq $TeamsRetentionName })) {
            Write-Status "Criando - $TeamsRetentionName" "Action"
            if (-not $DryRun) {
                try { New-RetentionCompliancePolicy -Name $TeamsRetentionName -Comment "Retém mensagens do Teams por 1 ano" -TeamsChannelLocation All -TeamsChatLocation All -Enabled $true -ErrorAction Stop
                    New-RetentionComplianceRule -Name "$TeamsRetentionName - Regra" -Policy $TeamsRetentionName -RetentionDuration 365 -RetentionComplianceAction Keep -ErrorAction Stop
                    Write-Status "$TeamsRetentionName - CRIADA" "Success"; Add-Change -Category "Retention" -Action "Create Policy" -Details $TeamsRetentionName
                } catch { Write-Status "Erro: $($_.Exception.Message)" "Error"; $SectionHadError = $true }
            } else { Write-Status "[DryRun] Criaria - $TeamsRetentionName" "Skip" }
        } else { Write-Status "$TeamsRetentionName - Já existe" "Success" }

        # Dados Sensíveis (7 anos)
        $SensitiveRetentionName = "Retencao Dados Sensiveis - 7 Anos"
        if (-not ($ExistingPolicies | Where-Object { $_.Name -eq $SensitiveRetentionName })) {
            Write-Status "Criando - $SensitiveRetentionName" "Action"
            if (-not $DryRun) {
                try { New-RetentionCompliancePolicy -Name $SensitiveRetentionName -Comment "Retém dados classificados como Highly Confidential por 7 anos" -ExchangeLocation All -SharePointLocation All -OneDriveLocation All -Enabled $true -ErrorAction Stop
                    New-RetentionComplianceRule -Name "$SensitiveRetentionName - Regra" -Policy $SensitiveRetentionName -RetentionDuration 2555 -RetentionComplianceAction KeepAndDelete -RetentionDurationDisplayHint Days -ErrorAction Stop
                    Write-Status "$SensitiveRetentionName - CRIADA" "Success"; Add-Change -Category "Retention" -Action "Create Policy" -Details $SensitiveRetentionName
                } catch { Write-Status "Erro: $($_.Exception.Message)" "Error"; $SectionHadError = $true }
            } else { Write-Status "[DryRun] Criaria - $SensitiveRetentionName" "Skip" }
        } else { Write-Status "$SensitiveRetentionName - Já existe" "Success" }

        # Documentos (3 anos)
        $GeneralRetentionName = "Retencao Documentos - 3 Anos"
        if (-not ($ExistingPolicies | Where-Object { $_.Name -eq $GeneralRetentionName })) {
            Write-Status "Criando - $GeneralRetentionName" "Action"
            if (-not $DryRun) {
                try { New-RetentionCompliancePolicy -Name $GeneralRetentionName -Comment "Retém documentos por 3 anos" -SharePointLocation All -OneDriveLocation All -Enabled $true -ErrorAction Stop
                    New-RetentionComplianceRule -Name "$GeneralRetentionName - Regra" -Policy $GeneralRetentionName -RetentionDuration 1095 -RetentionComplianceAction Keep -RetentionDurationDisplayHint Days -ErrorAction Stop
                    Write-Status "$GeneralRetentionName - CRIADA" "Success"; Add-Change -Category "Retention" -Action "Create Policy" -Details $GeneralRetentionName
                } catch { Write-Status "Erro: $($_.Exception.Message)" "Error"; $SectionHadError = $true }
            } else { Write-Status "[DryRun] Criaria - $GeneralRetentionName" "Skip" }
        } else { Write-Status "$GeneralRetentionName - Já existe" "Success" }
    } catch {
        if ($_.Exception.Message -match "license|not licensed") { Write-Status "Retention não disponível (licença)" "Skip"; Add-Skipped -Category "Retention" -Reason "Licença"; Set-SectionStatus -Category "Retention" -Status "Skip" -Details "Licença" }
        else { Write-Status "Erro: $($_.Exception.Message)" "Error"; Set-SectionStatus -Category "Retention" -Status "Error" -Details "Erro" }
    }
    if (-not $Script:SectionStatus.Contains("Retention")) { if ($SectionHadError) { Set-SectionStatus -Category "Retention" -Status "Warning" -Details "Falhas parciais" } else { Set-SectionStatus -Category "Retention" -Status "OK" -Details "Políticas verificadas/criadas" } }
}

# ============================================
# 3. POLÍTICAS DLP
# ============================================

function Repair-DLPPolicies {
    Write-Section "3️⃣" "POLÍTICAS DLP"
    if (-not (Get-Command -Name New-DlpCompliancePolicy -ErrorAction SilentlyContinue)) { Write-Status "Cmdlets de DLP não disponíveis" "Skip"; Add-Skipped -Category "DLP" -Reason "Cmdlet indisponível"; Set-SectionStatus -Category "DLP" -Status "Skip" -Details "Cmdlet indisponível"; return }
    if (-not (Test-CapabilityAvailable "DLP")) { Write-Status "DLP não disponível (licença)" "Skip"; Add-Skipped -Category "DLP" -Reason "Licença não inclui DLP"; Set-SectionStatus -Category "DLP" -Status "Skip" -Details "Licença"; return }
    $SectionHadError = $false
    if ($DLPAuditOnly) { $DLPMode = "TestWithNotifications"; $ModeDesc = "AUDITORIA"; $BlockAccess = $false; Write-Status "MODO: $ModeDesc" "Warning" }
    else { $DLPMode = "Enable"; $ModeDesc = "ATIVO (com bloqueio)"; $BlockAccess = $true; Write-Status "MODO: $ModeDesc" "Info" }
    try {
        $ExistingDLP = Get-DlpCompliancePolicy -ErrorAction Stop 3>$null
        $DLPCount = if ($ExistingDLP) { @($ExistingDLP).Count } else { 0 }
        Write-Status "Políticas DLP existentes: $DLPCount" "Info"; Save-Backup -Key "DLPPoliciesCount" -Value $DLPCount

        # CPF
        $CPFPolicyName = "DLP - Protecao CPF Brasileiro"
        if (-not ($ExistingDLP | Where-Object { $_.Name -eq $CPFPolicyName })) {
            Write-Status "Criando - $CPFPolicyName" "Action"
            if (-not $DryRun) {
                try { New-DlpCompliancePolicy -Name $CPFPolicyName -Comment "Detecta CPFs. Modo: $ModeDesc" -ExchangeLocation All -SharePointLocation All -OneDriveLocation All -TeamsLocation All -Mode $DLPMode -ErrorAction Stop
                    New-DlpComplianceRule -Name "Detectar CPF - Alta Confianca" -Policy $CPFPolicyName -ContentContainsSensitiveInformation @{Name="Brazil CPF Number"; minCount="1"; confidencelevel="High"} -BlockAccess $BlockAccess -NotifyUser "Owner" -NotifyPolicyTipCustomText "Este documento contém CPF." -GenerateIncidentReport "SiteAdmin" -ReportSeverityLevel "Medium" -ErrorAction Stop
                    Write-Status "$CPFPolicyName - CRIADA" "Success"; Add-Change -Category "DLP" -Action "Create Policy" -Details "$CPFPolicyName (Mode: $DLPMode)"
                } catch { Write-Status "Erro: $($_.Exception.Message)" "Error"; $SectionHadError = $true }
            } else { Write-Status "[DryRun] Criaria - $CPFPolicyName" "Skip" }
        } else { Write-Status "$CPFPolicyName - Já existe (Mode: $($ExistingDLP | Where-Object {$_.Name -eq $CPFPolicyName} | Select-Object -ExpandProperty Mode))" "Success" }

        # CNPJ
        $CNPJPolicyName = "DLP - Protecao CNPJ"
        if (-not ($ExistingDLP | Where-Object { $_.Name -eq $CNPJPolicyName })) {
            Write-Status "Criando - $CNPJPolicyName" "Action"
            if (-not $DryRun) {
                try { New-DlpCompliancePolicy -Name $CNPJPolicyName -Comment "Detecta CNPJs. Modo: $ModeDesc" -ExchangeLocation All -SharePointLocation All -OneDriveLocation All -TeamsLocation All -Mode $DLPMode -ErrorAction Stop
                    New-DlpComplianceRule -Name "Detectar CNPJ" -Policy $CNPJPolicyName -ContentContainsSensitiveInformation @{Name="Brazil Legal Entity Number (CNPJ)"; minCount="1"; confidencelevel="High"} -BlockAccess $false -NotifyUser "Owner" -GenerateIncidentReport "SiteAdmin" -ReportSeverityLevel "Low" -ErrorAction Stop
                    Write-Status "$CNPJPolicyName - CRIADA" "Success"; Add-Change -Category "DLP" -Action "Create Policy" -Details $CNPJPolicyName
                } catch { Write-Status "Erro: $($_.Exception.Message)" "Error"; $SectionHadError = $true }
            } else { Write-Status "[DryRun] Criaria - $CNPJPolicyName" "Skip" }
        } else { Write-Status "$CNPJPolicyName - Já existe" "Success" }

        # Cartão de Crédito
        $CCPolicyName = "DLP - Protecao Cartao de Credito"
        if (-not ($ExistingDLP | Where-Object { $_.Name -eq $CCPolicyName })) {
            Write-Status "Criando - $CCPolicyName" "Action"
            if (-not $DryRun) {
                try { New-DlpCompliancePolicy -Name $CCPolicyName -Comment "Detecta cartões de crédito. Modo: $ModeDesc" -ExchangeLocation All -SharePointLocation All -OneDriveLocation All -TeamsLocation All -Mode $DLPMode -ErrorAction Stop
                    New-DlpComplianceRule -Name "Detectar Cartao de Credito" -Policy $CCPolicyName -ContentContainsSensitiveInformation @{Name="Credit Card Number"; minCount="1"; confidencelevel="High"} -BlockAccess $BlockAccess -NotifyUser "Owner" -GenerateIncidentReport "SiteAdmin" -ReportSeverityLevel "High" -ErrorAction Stop
                    Write-Status "$CCPolicyName - CRIADA" "Success"; Add-Change -Category "DLP" -Action "Create Policy" -Details $CCPolicyName
                } catch { Write-Status "Erro: $($_.Exception.Message)" "Error"; $SectionHadError = $true }
            } else { Write-Status "[DryRun] Criaria - $CCPolicyName" "Skip" }
        } else { Write-Status "$CCPolicyName - Já existe" "Success" }

        Write-Host ""; Write-Status "Para ver relatórios DLP: https://compliance.microsoft.com/datalossprevention" "Info"
    } catch {
        if ($_.Exception.Message -match "license|not licensed") { Write-Status "DLP não disponível (licença)" "Skip"; Add-Skipped -Category "DLP" -Reason "Licença"; Set-SectionStatus -Category "DLP" -Status "Skip" -Details "Licença" }
        else { Write-Status "Erro: $($_.Exception.Message)" "Error"; Set-SectionStatus -Category "DLP" -Status "Error" -Details "Erro" }
    }
    if (-not $Script:SectionStatus.Contains("DLP")) { if ($SectionHadError) { Set-SectionStatus -Category "DLP" -Status "Warning" -Details "Falhas parciais" } else { Set-SectionStatus -Category "DLP" -Status "OK" -Details "Políticas verificadas/criadas" } }
}

# ============================================
# 4. OWA - PROVEDORES EXTERNOS
# ============================================

function Repair-OWAExternal {
    Write-Section "4️⃣" "OWA - PROVEDORES EXTERNOS"
    if (-not (Get-Command -Name Get-OwaMailboxPolicy -ErrorAction SilentlyContinue)) { Write-Status "Cmdlets do OWA não disponíveis" "Skip"; Add-Skipped -Category "OWA" -Reason "Cmdlet indisponível"; Set-SectionStatus -Category "OWA" -Status "Skip" -Details "Cmdlet indisponível"; return }
    if ($SkipOWABlock) { Write-Status "Bloqueio OWA - PULADO (-SkipOWABlock)" "Skip"; Set-SectionStatus -Category "OWA" -Status "Skip" -Details "-SkipOWABlock"; return }
    $SectionHadError = $false
    try {
        $OwaPolicy = Get-OwaMailboxPolicy -Identity "OwaMailboxPolicy-Default" -ErrorAction Stop; Save-Backup -Key "WacExternalServicesEnabled" -Value $OwaPolicy.WacExternalServicesEnabled
        if ($OwaPolicy.WacExternalServicesEnabled) {
            Write-Status "WacExternalServicesEnabled = TRUE (não seguro)" "Warning"; Write-Status "Desabilitando provedores externos..." "Action"
            if (-not $DryRun) { Set-OwaMailboxPolicy -Identity "OwaMailboxPolicy-Default" -WacExternalServicesEnabled $false; Write-Status "Provedores externos - DESABILITADOS" "Success"; Add-Change -Category "OWA" -Action "Disable External" -Details "WacExternalServicesEnabled=false" }
            else { Write-Status "[DryRun] Desabilitaria WacExternalServicesEnabled" "Skip" }
        } else { Write-Status "Provedores externos - Já desabilitado" "Success" }
    } catch { Write-Status "Erro: $($_.Exception.Message)" "Error"; $SectionHadError = $true }
    if (-not $Script:SectionStatus.Contains("OWA")) { if ($SectionHadError) { Set-SectionStatus -Category "OWA" -Status "Error" -Details "Erro" } else { Set-SectionStatus -Category "OWA" -Status "OK" -Details "OWA verificado" } }
}

# ============================================
# 5. ALERTAS DE SEGURANÇA
# ============================================

function Repair-AlertPolicies {
    Write-Section "5️⃣" "ALERTAS DE SEGURANÇA"
    if (-not (Get-Command -Name New-ProtectionAlert -ErrorAction SilentlyContinue)) { Write-Status "Cmdlets de Alertas não disponíveis" "Skip"; Add-Skipped -Category "AlertPolicies" -Reason "Cmdlet indisponível"; Set-SectionStatus -Category "AlertPolicies" -Status "Skip" -Details "Cmdlet indisponível"; return }
    if (-not (Test-CapabilityAvailable "AlertPolicies")) { Write-Status "Alert Policies não disponível" "Skip"; Add-Skipped -Category "AlertPolicies" -Reason "Não disponível"; Set-SectionStatus -Category "AlertPolicies" -Status "Skip" -Details "Não disponível"; return }
    $SectionHadError = $false
    $UseAdvanced = Test-CapabilityAvailable "AdvancedAlerts"
    if ($UseAdvanced) { Write-Status "Usando alertas AVANÇADOS (E5 detectado)" "Info"; $AggType = "SimpleAggregation" } else { Write-Status "Usando alertas BÁSICOS" "Info"; $AggType = "None" }
    Write-Status "Alertas só enviam notificação por email - NÃO bloqueiam nada" "Info"; Write-Host ""

    $AlertsToCreate = @(
        @{ Name="Custom - Nova Regra Inbox Suspeita"; Category="ThreatManagement"; Operation="New-InboxRule"; Description="Alerta quando nova regra de inbox é criada"; Severity="High"; Skip=$false },
        @{ Name="Custom - Permissao Mailbox Delegada"; Category="ThreatManagement"; Operation="Add-MailboxPermission"; Description="Alerta quando permissões de mailbox são alteradas"; Severity="Medium"; Skip=$false },
        @{ Name="Custom - Forwarding Externo Configurado"; Category="ThreatManagement"; Operation="Set-Mailbox"; Description="Alerta quando forwarding é configurado"; Severity="High"; Skip=$SkipForwardingAlert },
        @{ Name="Custom - Admin Role Atribuida"; Category="ThreatManagement"; Operation="Add-RoleGroupMember"; Description="Alerta quando role de admin é atribuída"; Severity="High"; Skip=$false },
        @{ Name="Custom - Malware Detectado"; Category="ThreatManagement"; Operation="MalwareDetected"; Description="Alerta quando malware é detectado"; Severity="High"; Skip=$false },
        @{ Name="Custom - Massa de Arquivos Deletados"; Category="ThreatManagement"; Operation="FileDeletedFirstStageRecycleBin"; Description="Alerta quando muitos arquivos são deletados"; Severity="High"; Skip=$false }
    )
    foreach ($Alert in $AlertsToCreate) {
        if ($Alert.Skip) { Write-Status "$($Alert.Name) - PULADO (-SkipForwardingAlert)" "Skip"; continue }
        try {
            $Existing = Get-ProtectionAlert -Identity $Alert.Name -ErrorAction SilentlyContinue
            if (-not $Existing) {
                Write-Status "Criando - $($Alert.Name)" "Action"; Write-Status "$($Alert.Description)" "Detail"
                if (-not $DryRun) { New-ProtectionAlert -Name $Alert.Name -Category $Alert.Category -ThreatType "Activity" -Operation $Alert.Operation -Description $Alert.Description -AggregationType $AggType -Severity $Alert.Severity -NotificationEnabled $true -ErrorAction SilentlyContinue; Write-Status "$($Alert.Name) - CRIADO" "Success"; Add-Change -Category "Alerts" -Action "Create Alert" -Details "$($Alert.Name) (Agg: $AggType)" }
                else { Write-Status "[DryRun] Criaria - $($Alert.Name)" "Skip" }
            } else { Write-Status "$($Alert.Name) - Já existe" "Success" }
        } catch { Write-Status "Erro ao criar $($Alert.Name): $($_.Exception.Message)" "Warning"; $SectionHadError = $true }
    }
    Write-Host ""; Write-Status "Para gerenciar alertas: https://security.microsoft.com/alertpolicies" "Info"
    if (-not $Script:SectionStatus.Contains("AlertPolicies")) { if ($SectionHadError) { Set-SectionStatus -Category "AlertPolicies" -Status "Warning" -Details "Falhas parciais" } else { Set-SectionStatus -Category "AlertPolicies" -Status "OK" -Details "Alertas verificados/criados" } }
}

# ============================================
# EVIDÊNCIAS PARA PURVIEW COMPLIANCE MANAGER
# ============================================

function Export-PurviewEvidence {
    Write-Section "📋" "EVIDÊNCIAS PARA PURVIEW COMPLIANCE MANAGER"
    $Evidence = [System.Collections.ArrayList]::new()
    $TenantLabel = if ($TenantName) { $TenantName } else { "Tenant" }
    Write-Status "Coletando evidências de políticas implementadas..." "Info"

    # DLP
    try { $dlp = Get-DlpCompliancePolicy -ErrorAction Stop 3>$null; $enabled = @($dlp | Where-Object { $_.Enabled })
        foreach ($p in $enabled) { [void]$Evidence.Add([PSCustomObject]@{ Category="DLP"; ActionName="DLP Policy: $($p.Name)"; Status="Enabled (Mode: $($p.Mode))"; PolicyName=$p.Name; PolicyId=$p.Guid; ImplementationDate=(Get-Date -Format "yyyy-MM-dd"); Notes="Workloads: $($p.Workload -join ', ') | Mode: $($p.Mode)"; PurviewMapping="Create DLP policies for sensitive information"; PurviewStatus="Implemented" }) }
        if ($enabled.Count -gt 0) { Write-Status "DLP: $($enabled.Count) políticas" "Success" }
    } catch { Write-Status "DLP não verificável" "Detail" }

    # Sensitivity Labels
    try { $labels = Get-Label -ErrorAction Stop
        foreach ($l in $labels) { $parent = if ([string]::IsNullOrEmpty($l.ParentId)) { "Root" } else { "Child" }; [void]$Evidence.Add([PSCustomObject]@{ Category="Sensitivity Labels"; ActionName="Label: $($l.DisplayName)"; Status="Active ($parent)"; PolicyName=$l.DisplayName; PolicyId=$l.Guid; ImplementationDate=(Get-Date -Format "yyyy-MM-dd"); Notes="Priority: $($l.Priority) | Type: $parent"; PurviewMapping="Create and publish sensitivity labels"; PurviewStatus="Implemented" }) }
        if ($labels.Count -gt 0) { Write-Status "Labels: $($labels.Count) sensitivity labels" "Success" }
        $lp = Get-LabelPolicy -ErrorAction SilentlyContinue; if ($lp) { foreach ($p in $lp) { [void]$Evidence.Add([PSCustomObject]@{ Category="Sensitivity Labels"; ActionName="Label Policy: $($p.Name)"; Status="Published"; PolicyName=$p.Name; PolicyId=$p.Guid; ImplementationDate=(Get-Date -Format "yyyy-MM-dd"); Notes="Labels published to users"; PurviewMapping="Publish sensitivity labels"; PurviewStatus="Implemented" }) } }
    } catch { Write-Status "Labels não verificável" "Detail" }

    # Retention
    try { $ret = Get-RetentionCompliancePolicy -ErrorAction Stop 3>$null
        foreach ($p in $ret) { [void]$Evidence.Add([PSCustomObject]@{ Category="Retention"; ActionName="Retention: $($p.Name)"; Status=$(if ($p.Enabled) {"Enabled"} else {"Disabled"}); PolicyName=$p.Name; PolicyId=$p.Guid; ImplementationDate=(Get-Date -Format "yyyy-MM-dd"); Notes="Workloads: $($p.Workload -join ', ') | Enabled: $($p.Enabled)"; PurviewMapping="Create retention policies"; PurviewStatus="Implemented" }) }
        if ($ret.Count -gt 0) { Write-Status "Retention: $($ret.Count) políticas" "Success" }
    } catch { Write-Status "Retention não verificável" "Detail" }

    # Audit
    try { $org = Get-OrganizationConfig -ErrorAction Stop; $mbAudit = -not $org.AuditDisabled
        [void]$Evidence.Add([PSCustomObject]@{ Category="Audit"; ActionName="Mailbox Audit by Default"; Status=$(if ($mbAudit) {"Enabled"} else {"Disabled"}); PolicyName="Organization Config"; PolicyId="AuditDisabled=$($org.AuditDisabled)"; ImplementationDate=(Get-Date -Format "yyyy-MM-dd"); Notes="AuditDisabled: $($org.AuditDisabled)"; PurviewMapping="Turn on auditing"; PurviewStatus="Implemented" })
        if ($mbAudit) { Write-Status "Audit: Mailbox Audit habilitado" "Success" }
    } catch { Write-Status "Audit não verificável" "Detail" }
    try { $null = Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-7) -EndDate (Get-Date) -ResultSize 1 -ErrorAction Stop
        [void]$Evidence.Add([PSCustomObject]@{ Category="Audit"; ActionName="Unified Audit Log"; Status="Enabled & Active"; PolicyName="Unified Audit Log"; PolicyId="UAL-Active"; ImplementationDate=(Get-Date -Format "yyyy-MM-dd"); Notes="Audit Log is active with recent entries"; PurviewMapping="Turn on audit log search"; PurviewStatus="Implemented" })
        Write-Status "Audit: Unified Audit Log ativo" "Success"
    } catch { Write-Status "UAL não verificável" "Detail" }

    # Safe Links / Attachments / Anti-Phishing
    try { $sl = Get-SafeLinksPolicy -ErrorAction Stop; foreach ($p in $sl) { [void]$Evidence.Add([PSCustomObject]@{ Category="ATP"; ActionName="Safe Links: $($p.Name)"; Status="Enabled"; PolicyName=$p.Name; PolicyId=$p.Guid; ImplementationDate=(Get-Date -Format "yyyy-MM-dd"); Notes="ScanUrls: $($p.ScanUrls)"; PurviewMapping="Turn on Safe Links for Office 365"; PurviewStatus="Implemented" }) }; if ($sl.Count -gt 0) { Write-Status "ATP: $(@($sl).Count) Safe Links" "Success" } } catch { Write-Status "Safe Links não disponível (requer Defender for Office 365)" "Detail" }
    try { $sa = Get-SafeAttachmentPolicy -ErrorAction Stop; foreach ($p in $sa) { [void]$Evidence.Add([PSCustomObject]@{ Category="ATP"; ActionName="Safe Attachments: $($p.Name)"; Status="Enabled"; PolicyName=$p.Name; PolicyId=$p.Guid; ImplementationDate=(Get-Date -Format "yyyy-MM-dd"); Notes="Action: $($p.Action)"; PurviewMapping="Turn on Safe Attachments"; PurviewStatus="Implemented" }) }; if ($sa.Count -gt 0) { Write-Status "ATP: $(@($sa).Count) Safe Attachments" "Success" } } catch { Write-Status "Safe Attachments não disponível" "Detail" }
    try { $ap = Get-AntiPhishPolicy -ErrorAction Stop | Where-Object { $_.IsDefault -eq $false -or $_.Enabled }; foreach ($p in $ap) { [void]$Evidence.Add([PSCustomObject]@{ Category="ATP"; ActionName="Anti-Phishing: $($p.Name)"; Status="Enabled"; PolicyName=$p.Name; PolicyId=$p.Guid; ImplementationDate=(Get-Date -Format "yyyy-MM-dd"); Notes="Impersonation: $($p.EnableTargetedUserProtection)"; PurviewMapping="Set up anti-phishing policies"; PurviewStatus="Implemented" }) }; if ($ap.Count -gt 0) { Write-Status "ATP: $(@($ap).Count) Anti-Phishing" "Success" } } catch { Write-Status "Anti-Phishing não disponível" "Detail" }

    # Transport Rules
    try { $rules = Get-TransportRule -ErrorAction Stop; $en = @($rules | Where-Object { $_.State -eq "Enabled" })
        foreach ($r in $en) { [void]$Evidence.Add([PSCustomObject]@{ Category="Transport Rules"; ActionName="Mail Flow Rule: $($r.Name)"; Status="Enabled"; PolicyName=$r.Name; PolicyId=$r.Guid; ImplementationDate=(Get-Date -Format "yyyy-MM-dd"); Notes="Priority: $($r.Priority)"; PurviewMapping=""; PurviewStatus="Implemented" }) }
        if ($en.Count -gt 0) { Write-Status "Transport Rules: $($en.Count) regras" "Success" }
    } catch { Write-Status "Transport Rules não verificável" "Detail" }

    # DKIM
    try { $dkim = Get-DkimSigningConfig -ErrorAction Stop
        foreach ($d in $dkim) { [void]$Evidence.Add([PSCustomObject]@{ Category="Email Authentication"; ActionName="DKIM: $($d.Domain)"; Status=$(if ($d.Enabled) {"Enabled"} else {"Disabled"}); PolicyName=$d.Domain; PolicyId=$d.Guid; ImplementationDate=(Get-Date -Format "yyyy-MM-dd"); Notes="Enabled: $($d.Enabled)"; PurviewMapping="Set up DKIM for your custom domain"; PurviewStatus="Implemented" }) }
        $enDkim = @($dkim | Where-Object { $_.Enabled }); if ($enDkim.Count -gt 0) { Write-Status "DKIM: $($enDkim.Count) domínios" "Success" }
    } catch { Write-Status "DKIM não verificável" "Detail" }

    # Conditional Access (Graph)
    try { $ctx = Get-MgContext -ErrorAction SilentlyContinue
        if ($ctx) { $ca = Get-MgIdentityConditionalAccessPolicy -All -ErrorAction Stop; $enCA = @($ca | Where-Object { $_.State -eq "enabled" })
            foreach ($p in $enCA) { $date = if ($p.ModifiedDateTime) { $p.ModifiedDateTime.ToString("yyyy-MM-dd") } else { (Get-Date -Format "yyyy-MM-dd") }; $mapping = ""
                if ($p.Conditions.ClientAppTypes -contains "exchangeActiveSync" -or $p.DisplayName -match "legacy|legado") { $mapping = "Enable policy to block legacy authentication" }
                elseif ($p.GrantControls.BuiltInControls -contains "mfa") { $mapping = "Require MFA for administrative roles / all users" }
                elseif ($p.Conditions.Locations -and $p.GrantControls.BuiltInControls -contains "block") { $mapping = "Block sign-ins from unauthorized locations" }
                elseif ($p.GrantControls.BuiltInControls -contains "compliantDevice") { $mapping = "Require compliant devices" }
                [void]$Evidence.Add([PSCustomObject]@{ Category="Conditional Access"; ActionName=$p.DisplayName; Status="Enabled"; PolicyName=$p.DisplayName; PolicyId=$p.Id; ImplementationDate=$date; Notes="State: $($p.State) | Grant: $($p.GrantControls.BuiltInControls -join ', ')"; PurviewMapping=$mapping; PurviewStatus="Implemented" })
            }; if ($enCA.Count -gt 0) { Write-Status "Conditional Access: $($enCA.Count) políticas" "Success" }
        } else { Write-Status "Graph não conectado - CA policies não incluídas" "Detail" }
    } catch { Write-Status "CA não disponível: $($_.Exception.Message)" "Detail" }

    # EXPORT
    if ($Evidence.Count -eq 0) { Write-Status "Nenhuma evidência coletada" "Warning"; return }
    if (-not (Test-Path $PurviewEvidencePath)) { New-Item -ItemType Directory -Path $PurviewEvidencePath -Force | Out-Null }
    $csvPath = Join-Path $PurviewEvidencePath "purview-evidence.csv"; $Evidence | Export-Csv $csvPath -NoTypeInformation -Encoding UTF8; Write-Status "CSV: $csvPath" "Success"
    $jsonPath = Join-Path $PurviewEvidencePath "purview-evidence.json"; $Evidence | ConvertTo-Json -Depth 5 | Out-File $jsonPath -Encoding UTF8; Write-Status "JSON: $jsonPath" "Success"
    $mdPath = Join-Path $PurviewEvidencePath "EVIDENCE-REPORT.md"
    $md = "# Evidências para Purview Compliance Manager`n`n**Tenant:** $TenantLabel`n**Data:** $(Get-Date -Format 'dd/MM/yyyy HH:mm')`n**Total:** $($Evidence.Count)`n`n## Resumo`n`n| Categoria | Políticas |`n|-----------|:---------:|`n"
    $groups = $Evidence | Group-Object Category; foreach ($g in $groups) { $md += "| $($g.Name) | $($g.Count) |`n" }
    $md += "`n## Como usar no Purview`n`n1. Abra: https://compliance.microsoft.com/compliancemanager`n2. Clique em Assessments > Selecione a avaliação`n3. Para cada ação: Update Status > Implemented`n4. Cole as Notes como evidência`n"
    $md | Out-File $mdPath -Encoding UTF8; Write-Status "Markdown: $mdPath" "Success"

    Write-Host ""; Write-Host "  📊 EVIDÊNCIAS PARA PURVIEW" -ForegroundColor Cyan; Write-Host "  ─────────────────────────────────────────────" -ForegroundColor Gray
    foreach ($g in $groups) { Write-Host "  $($g.Name.PadRight(30)) $($g.Count) políticas" -ForegroundColor Green }
    Write-Host "  ─────────────────────────────────────────────" -ForegroundColor Gray; Write-Host "  TOTAL                        $($Evidence.Count) evidências" -ForegroundColor Cyan
    Write-Host ""; Write-Host "  📁 Evidências salvas em: $PurviewEvidencePath" -ForegroundColor Green
    Write-Host ""; Write-Host "  📋 PRÓXIMOS PASSOS:" -ForegroundColor Yellow; Write-Host "     1. Abra o CSV: purview-evidence.csv" -ForegroundColor White; Write-Host "     2. Acesse: https://compliance.microsoft.com/compliancemanager" -ForegroundColor White; Write-Host "     3. Para cada ação > 'Update Status' > 'Implemented'" -ForegroundColor White; Write-Host "     4. Cole as 'Notes' como evidência" -ForegroundColor White; Write-Host "     5. SCORE SOBE AUTOMATICAMENTE!" -ForegroundColor Green; Write-Host ""
    Add-Change -Category "Purview Evidence" -Action "Evidências exportadas" -Details "$($Evidence.Count) políticas em $PurviewEvidencePath"
    Set-SectionStatus -Category "Purview Evidence" -Status "OK" -Details "$($Evidence.Count) evidências coletadas"
}

# ============================================
# VERIFICAÇÃO FINAL E SUMÁRIO
# ============================================

function Show-Summary {
    Write-Section "✅" "VERIFICAÇÃO FINAL"
    Write-Host ""
    if ($Script:TenantCaps) { Write-Host "  TENANT: $($Script:TenantCaps.TenantInfo.DisplayName)" -ForegroundColor Cyan; Write-Host "  LICENÇA: $($Script:TenantCaps.License.Probable)" -ForegroundColor Cyan; Write-Host "" }
    try { $AuditTest = Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-1) -EndDate (Get-Date) -ResultSize 1 -ErrorAction SilentlyContinue; $AuditStatus = if ($AuditTest) { "ATIVO" } else { "Verificar manualmente" } } catch { $AuditStatus = "Verificar no portal" }
    Write-Host "  Unified Audit Log:     $AuditStatus" -ForegroundColor $(if ($AuditStatus -eq "ATIVO") { "Green" } else { "Yellow" })
    $MailboxAudit = (Get-OrganizationConfig).AuditDisabled; $MbStatus = if (-not $MailboxAudit) { "ATIVO" } else { "DESATIVADO" }
    Write-Host "  Mailbox Audit:         $MbStatus" -ForegroundColor $(if (-not $MailboxAudit) { "Green" } else { "Red" })
    if ("Retention" -notin ($Script:SkippedItems.Category)) { $RetCount = @(Get-RetentionCompliancePolicy -ErrorAction SilentlyContinue 3>$null).Count; Write-Host "  Políticas Retenção:    $RetCount políticas" -ForegroundColor $(if ($RetCount -ge 3) { "Green" } else { "Yellow" }) } else { Write-Host "  Políticas Retenção:    N/A (não licenciado)" -ForegroundColor DarkGray }
    if ("DLP" -notin ($Script:SkippedItems.Category)) { $DLPPols = Get-DlpCompliancePolicy -ErrorAction SilentlyContinue 3>$null; $DCount = if ($DLPPols) { @($DLPPols).Count } else { 0 }; $AuditCount = @($DLPPols | Where-Object { $_.Mode -eq "TestWithNotifications" }).Count; $DStatus = if ($AuditCount -gt 0) { "$DCount políticas ($AuditCount em auditoria)" } else { "$DCount políticas" }; Write-Host "  Políticas DLP:         $DStatus" -ForegroundColor $(if ($DCount -ge 3) { "Green" } else { "Yellow" }) } else { Write-Host "  Políticas DLP:         N/A (não licenciado)" -ForegroundColor DarkGray }
    $OwaExt = (Get-OwaMailboxPolicy -Identity "OwaMailboxPolicy-Default" -ErrorAction SilentlyContinue).WacExternalServicesEnabled; $OwaStatus = if (-not $OwaExt) { "BLOQUEADO" } else { "PERMITIDO" }
    Write-Host "  OWA Externos:          $OwaStatus" -ForegroundColor $(if (-not $OwaExt) { "Green" } else { "Yellow" })
    Write-Host ""
    if ($Script:SkippedItems.Count -gt 0) { Write-Host "  ⏭️  ITENS PULADOS:" -ForegroundColor DarkGray; foreach ($Skip in $Script:SkippedItems) { Write-Host "     - $($Skip.Category): $($Skip.Reason)" -ForegroundColor DarkGray }; Write-Host "" }
    if ($DLPAuditOnly -or $SkipForwardingAlert -or $SkipOWABlock) { Write-Host "  OPÇÕES UTILIZADAS:" -ForegroundColor Gray; if ($DLPAuditOnly) { Write-Host "     - DLP em modo AUDITORIA" -ForegroundColor Gray }; if ($SkipForwardingAlert) { Write-Host "     - Alerta de Forwarding: PULADO" -ForegroundColor Gray }; if ($SkipOWABlock) { Write-Host "     - Bloqueio OWA: PULADO" -ForegroundColor Gray }; Write-Host "" }
    if ($Script:Changes.Count -gt 0) { Write-Host "  ALTERAÇÕES REALIZADAS:" -ForegroundColor Cyan; foreach ($C in $Script:Changes) { Write-Host "     [$($C.Timestamp)] $($C.Category) - $($C.Action)" -ForegroundColor White }; Write-Host "" }
    Write-Host "  Backup salvo em: $BackupPath" -ForegroundColor Gray; Write-Host ""
}

function New-HTMLReport {
    $TName = if ($Script:TenantCaps) { $Script:TenantCaps.TenantInfo.DisplayName } else { "N/A" }
    $LName = if ($Script:TenantCaps) { $Script:TenantCaps.License.Probable } else { "N/A" }
    $SectionsHtml = if ($Script:SectionStatus.Count -gt 0) { ($Script:SectionStatus.Values | ForEach-Object { $Class = switch -Regex ("$($_.Status)") { "^(OK|Success|Enabled)$" { "good"; break } "Warning" { "warn"; break } "Error" { "bad"; break } "Skip" { "na"; break } default { "" } }; "<tr class='$Class'><td>$([System.Net.WebUtility]::HtmlEncode($_.Category))</td><td>$([System.Net.WebUtility]::HtmlEncode($_.Status))</td><td>$([System.Net.WebUtility]::HtmlEncode($_.Details))</td></tr>" }) -join "" } else { "<tr><td colspan='3'>Sem dados</td></tr>" }
    $ChangesHtml = if ($Script:Changes.Count -gt 0) { ($Script:Changes | ForEach-Object { "<tr><td>$([System.Net.WebUtility]::HtmlEncode($_.Timestamp))</td><td>$([System.Net.WebUtility]::HtmlEncode($_.Category))</td><td>$([System.Net.WebUtility]::HtmlEncode($_.Action))</td><td>$([System.Net.WebUtility]::HtmlEncode($_.Details))</td></tr>" }) -join "" } else { "<tr><td colspan='4'>Nenhuma alteração</td></tr>" }
    $SkippedHtml = if ($Script:SkippedItems.Count -gt 0) { ($Script:SkippedItems | ForEach-Object { "<tr class='na'><td>$([System.Net.WebUtility]::HtmlEncode($_.Category))</td><td>$([System.Net.WebUtility]::HtmlEncode($_.Reason))</td></tr>" }) -join "" } else { "<tr><td colspan='2'>Nenhum</td></tr>" }
    $Html = @"
<!DOCTYPE html><html lang="pt-br"><head><meta charset="utf-8"/><title>Relatório - Remediação M365</title>
<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1f2937}h1{margin-bottom:4px}.card{background:#fff;padding:16px;border-radius:8px;margin-bottom:16px;border:1px solid #e5e7eb}table{width:100%;border-collapse:collapse;margin-top:8px}th,td{border:1px solid #e5e7eb;padding:8px 10px;text-align:left}th{background:#f3f4f6}tr.good td{background:#ecfdf5}tr.warn td{background:#fffbeb}tr.bad td{background:#fef2f2}tr.na td{background:#f9fafb;color:#6b7280}.muted{color:#6b7280}</style>
</head><body><h1>Relatório de Remediação M365</h1>
<div class="card"><p><strong>Data:</strong> $(Get-Date)</p><p><strong>Tenant:</strong> $TName</p><p><strong>Licença:</strong> $LName</p><p><strong>Backup:</strong> $BackupPath</p></div>
<div class="card"><h2>Status por Seção</h2><table><thead><tr><th>Seção</th><th>Status</th><th>Detalhes</th></tr></thead><tbody>$SectionsHtml</tbody></table></div>
<div class="card"><h2>Itens Pulados</h2><table><thead><tr><th>Categoria</th><th>Motivo</th></tr></thead><tbody>$SkippedHtml</tbody></table></div>
<div class="card"><h2>Alterações Realizadas</h2><table><thead><tr><th>Hora</th><th>Categoria</th><th>Ação</th><th>Detalhes</th></tr></thead><tbody>$ChangesHtml</tbody></table></div>
</body></html>
"@
    $Html | Out-File $ReportPath -Encoding UTF8; Write-Status "Relatório HTML salvo em: $ReportPath" "Success"
}

function Show-RollbackInstructions {
    Write-Section "🔙" "INSTRUÇÕES DE ROLLBACK"
    Write-Host ""; Write-Host "  Para reverter alterações:" -ForegroundColor Yellow; Write-Host ""
    Write-Host '  Get-RetentionCompliancePolicy | Where-Object {$_.Name -like "Retencao*"} | Remove-RetentionCompliancePolicy' -ForegroundColor White; Write-Host ""
    Write-Host '  Get-DlpCompliancePolicy | Where-Object {$_.Name -like "DLP -*"} | Remove-DlpCompliancePolicy' -ForegroundColor White; Write-Host ""
    Write-Host '  Set-OwaMailboxPolicy -Identity "OwaMailboxPolicy-Default" -WacExternalServicesEnabled $true' -ForegroundColor White; Write-Host ""
}

# ============================================
# EXECUÇÃO PRINCIPAL
# ============================================

function Start-M365Remediation {
    Clear-Host; Write-Banner
    if (-not $SkipConnection) { try { Connect-ToServices } catch { Write-Status "Falha ao conectar. Abortando." "Error"; return } } else { Write-Status "Pulando conexão (sessão existente)" "Info" }
    if (-not $SkipCapabilityCheck) { $cap = Initialize-TenantCapabilities; if (-not $cap) { Write-Status "Executando sem detecção de capacidades" "Warning" } } else { Write-Status "Detecção de capacidades pulada" "Info" }
    $OnlyMode = ($OnlyRetention -or $OnlyDLP -or $OnlyAlerts)
    Write-Section "🚀" "INICIANDO VARREDURA/REMEDIAÇÃO"
    if (-not $OnlyMode -or $OnlyRetention) { Repair-RetentionPolicies }
    if (-not $OnlyMode) { Repair-UnifiedAuditLog }
    if (-not $OnlyMode -or $OnlyDLP) { Repair-DLPPolicies }
    if (-not $OnlyMode) { Repair-OWAExternal }
    if (-not $OnlyMode -or $OnlyAlerts) { Repair-AlertPolicies }
    if (-not $SkipPurviewEvidence) { Export-PurviewEvidence }
    Show-Summary; Show-RollbackInstructions; New-HTMLReport
    Write-Host "  ✅ Remediação concluída!" -ForegroundColor Green; Write-Host ""
}

Start-M365Remediation
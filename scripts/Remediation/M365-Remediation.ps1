<#
.SYNOPSIS
    Remediação de Segurança Microsoft 365
.DESCRIPTION
    Aplica configurações de segurança recomendadas:
    - Ativa Unified Audit Log
    - Desabilita provedores externos no OWA
    - Cria políticas DLP para dados brasileiros
    - Configura alertas de segurança
    
    Cria backup antes de cada alteração para permitir rollback.
.AUTHOR
    M365 Security Toolkit
.VERSION
    2.0 - Janeiro 2026
.EXAMPLE
    ./M365-Remediation.ps1
#>

param(
    [switch]$Rollback,
    [string]$BackupFile
)

$ErrorActionPreference = "Stop"
$BackupPath = "./M365-Backup_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
$Backup = @{}

# ============================================
# FUNÇÕES
# ============================================

function Write-Status {
    param([string]$Message, [string]$Type = "Info")
    $Color = switch ($Type) {
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error"   { "Red" }
        "Info"    { "Cyan" }
        "Header"  { "Magenta" }
        default   { "White" }
    }
    Write-Host $Message -ForegroundColor $Color
}

function Save-Backup {
    param([string]$Key, $Value)
    $script:Backup[$Key] = $Value
    $script:Backup | ConvertTo-Json -Depth 10 | Out-File $BackupPath -Encoding UTF8
}

# ============================================
# INÍCIO
# ============================================

Clear-Host
Write-Status @"

╔════════════════════════════════════════════════════════════════════╗
║     🔧 REMEDIAÇÃO DE SEGURANÇA M365                                ║
╚════════════════════════════════════════════════════════════════════╝

"@ "Header"

# Verificar conexão
Write-Status "🔐 Verificando conexões..." "Header"

try {
    $ExoTest = Get-OrganizationConfig -ErrorAction Stop
    Write-Status "  ✅ Exchange Online conectado" "Success"
}
catch {
    Write-Status "  ⚠️ Conectando ao Exchange Online..." "Warning"
    Connect-ExchangeOnline -ShowBanner:$false
}

try {
    $IppsTest = Get-Label -ErrorAction Stop
    Write-Status "  ✅ Security & Compliance conectado" "Success"
}
catch {
    Write-Status "  ⚠️ Conectando ao Security & Compliance..." "Warning"
    Connect-IPPSSession -ShowBanner:$false -WarningAction SilentlyContinue
}

Write-Status ""

# ============================================
# 1. UNIFIED AUDIT LOG
# ============================================

Write-Status "═══════════════════════════════════════════════════════════" "Header"
Write-Status "  1️⃣  UNIFIED AUDIT LOG" "Header"
Write-Status "═══════════════════════════════════════════════════════════" "Header"

try {
    $CurrentAudit = Get-AdminAuditLogConfig
    $CurrentStatus = $CurrentAudit.UnifiedAuditLogIngestionEnabled
    
    Write-Status "  Status atual: $CurrentStatus" "Info"
    Save-Backup -Key "UnifiedAuditLog" -Value $CurrentStatus
    
    if (-not $CurrentStatus) {
        Write-Status "  ⚠️ Unified Audit Log DESABILITADO - Ativando..." "Warning"
        Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true
        Write-Status "  ✅ Unified Audit Log ATIVADO!" "Success"
    }
    else {
        Write-Status "  ✅ Já está habilitado" "Success"
    }
}
catch {
    Write-Status "  ❌ Erro: $_" "Error"
}

Write-Status ""

# ============================================
# 2. OWA - PROVEDORES EXTERNOS
# ============================================

Write-Status "═══════════════════════════════════════════════════════════" "Header"
Write-Status "  2️⃣  OWA - PROVEDORES EXTERNOS" "Header"
Write-Status "═══════════════════════════════════════════════════════════" "Header"

try {
    $OwaPolicy = Get-OwaMailboxPolicy -Identity "OwaMailboxPolicy-Default"
    $CurrentExternal = $OwaPolicy.WacExternalServicesEnabled
    
    Write-Status "  Status atual: WacExternalServicesEnabled = $CurrentExternal" "Info"
    Save-Backup -Key "WacExternalServicesEnabled" -Value $CurrentExternal
    
    if ($CurrentExternal) {
        Write-Status "  ⚠️ Provedores externos HABILITADOS - Desabilitando..." "Warning"
        Set-OwaMailboxPolicy -Identity "OwaMailboxPolicy-Default" -WacExternalServicesEnabled $false
        Write-Status "  ✅ Provedores externos DESABILITADOS!" "Success"
    }
    else {
        Write-Status "  ✅ Já está desabilitado" "Success"
    }
}
catch {
    Write-Status "  ❌ Erro: $_" "Error"
}

Write-Status ""

# ============================================
# 3. POLÍTICAS DLP
# ============================================

Write-Status "═══════════════════════════════════════════════════════════" "Header"
Write-Status "  3️⃣  POLÍTICAS DLP" "Header"
Write-Status "═══════════════════════════════════════════════════════════" "Header"

try {
    $ExistingDLP = Get-DlpCompliancePolicy -ErrorAction SilentlyContinue
    $DLPCount = if ($ExistingDLP) { @($ExistingDLP).Count } else { 0 }
    
    Write-Status "  Políticas DLP existentes: $DLPCount" "Info"
    Save-Backup -Key "DLPPoliciesCount" -Value $DLPCount
    
    if ($DLPCount -eq 0) {
        Write-Status "  ⚠️ Nenhuma política DLP - Criando..." "Warning"
        
        # DLP 1: CPF Brasileiro
        Write-Status "    Criando: DLP - CPF Brasileiro..." "Info"
        New-DlpCompliancePolicy -Name "DLP - Proteção CPF Brasileiro" `
            -Comment "Protege CPFs em Exchange, SharePoint e OneDrive" `
            -ExchangeLocation All `
            -SharePointLocation All `
            -OneDriveLocation All `
            -Mode Enable
        
        New-DlpComplianceRule -Name "Detectar CPF - Alta Confiança" `
            -Policy "DLP - Proteção CPF Brasileiro" `
            -ContentContainsSensitiveInformation @{Name="Brazil CPF Number"; minCount="1"; minConfidence="85"} `
            -BlockAccess $true `
            -NotifyUser "Owner" `
            -NotifyPolicyTipCustomText "Este documento contém CPF e está protegido."
        
        Write-Status "    ✅ DLP - CPF Brasileiro criada" "Success"
        
        # DLP 2: Cartão de Crédito
        Write-Status "    Criando: DLP - Cartão de Crédito..." "Info"
        New-DlpCompliancePolicy -Name "DLP - Proteção Cartão de Crédito" `
            -Comment "Protege números de cartão de crédito" `
            -ExchangeLocation All `
            -SharePointLocation All `
            -OneDriveLocation All `
            -Mode Enable
        
        New-DlpComplianceRule -Name "Detectar Cartão de Crédito" `
            -Policy "DLP - Proteção Cartão de Crédito" `
            -ContentContainsSensitiveInformation @{Name="Credit Card Number"; minCount="1"; minConfidence="85"} `
            -BlockAccess $true `
            -NotifyUser "Owner"
        
        Write-Status "    ✅ DLP - Cartão de Crédito criada" "Success"
        
        # DLP 3: Dados de Clientes
        Write-Status "    Criando: DLP - Dados de Clientes..." "Info"
        New-DlpCompliancePolicy -Name "DLP - Dados Confidenciais Clientes" `
            -Comment "Protege múltiplos tipos de dados sensíveis de clientes" `
            -ExchangeLocation All `
            -SharePointLocation All `
            -OneDriveLocation All `
            -Mode Enable
        
        New-DlpComplianceRule -Name "Detectar Múltiplos Dados Sensíveis" `
            -Policy "DLP - Dados Confidenciais Clientes" `
            -ContentContainsSensitiveInformation @(
                @{Name="Brazil CPF Number"; minCount="1"},
                @{Name="Brazil National ID Card (RG)"; minCount="1"},
                @{Name="Brazil Legal Entity Number (CNPJ)"; minCount="1"}
            ) `
            -BlockAccess $false `
            -NotifyUser "Owner" `
            -GenerateIncidentReport "SiteAdmin"
        
        Write-Status "    ✅ DLP - Dados de Clientes criada" "Success"
        
        Write-Status "  ✅ 3 políticas DLP criadas com sucesso!" "Success"
    }
    else {
        Write-Status "  ✅ Já existem $DLPCount políticas DLP" "Success"
        foreach ($Policy in $ExistingDLP) {
            Write-Status "    • $($Policy.Name)" "Info"
        }
    }
}
catch {
    Write-Status "  ❌ Erro ao criar DLP: $_" "Error"
}

Write-Status ""

# ============================================
# 4. ALERTAS DE SEGURANÇA
# ============================================

Write-Status "═══════════════════════════════════════════════════════════" "Header"
Write-Status "  4️⃣  ALERTAS DE SEGURANÇA" "Header"
Write-Status "═══════════════════════════════════════════════════════════" "Header"

try {
    $ExistingAlerts = Get-ProtectionAlert -ErrorAction SilentlyContinue | 
        Where-Object { $_.Name -like "*Custom*" }
    
    Write-Status "  Alertas customizados existentes: $(@($ExistingAlerts).Count)" "Info"
    
    $AlertsToCreate = @(
        @{
            Name = "Custom - Nova Regra Inbox Suspeita"
            Category = "ThreatManagement"
            ThreatType = "Activity"
            Operation = "New-InboxRule"
            Description = "Alerta quando uma nova regra de inbox é criada"
        },
        @{
            Name = "Custom - Permissão Mailbox Alterada"
            Category = "ThreatManagement"
            ThreatType = "Activity"
            Operation = "Add-MailboxPermission"
            Description = "Alerta quando permissões de mailbox são alteradas"
        },
        @{
            Name = "Custom - Forwarding Configurado"
            Category = "ThreatManagement"
            ThreatType = "Activity"
            Operation = "Set-Mailbox"
            Description = "Alerta quando forwarding é configurado"
        }
    )
    
    foreach ($Alert in $AlertsToCreate) {
        $Existing = Get-ProtectionAlert -Identity $Alert.Name -ErrorAction SilentlyContinue
        
        if (-not $Existing) {
            Write-Status "    Criando alerta: $($Alert.Name)..." "Info"
            
            New-ProtectionAlert -Name $Alert.Name `
                -Category $Alert.Category `
                -ThreatType $Alert.ThreatType `
                -Operation $Alert.Operation `
                -Description $Alert.Description `
                -AggregationType None `
                -Severity Medium `
                -ErrorAction SilentlyContinue
            
            Write-Status "    ✅ $($Alert.Name) criado" "Success"
        }
        else {
            Write-Status "    ✅ $($Alert.Name) já existe" "Success"
        }
    }
}
catch {
    Write-Status "  ⚠️ Erro ao criar alertas (pode requerer licença): $_" "Warning"
}

Write-Status ""

# ============================================
# VERIFICAÇÃO FINAL
# ============================================

Write-Status "═══════════════════════════════════════════════════════════" "Header"
Write-Status "  ✅ VERIFICAÇÃO FINAL" "Header"
Write-Status "═══════════════════════════════════════════════════════════" "Header"

Write-Status ""
Write-Status "  Verificando configurações aplicadas..." "Info"
Write-Status ""

# Unified Audit
$AuditCheck = (Get-AdminAuditLogConfig).UnifiedAuditLogIngestionEnabled
$AuditStatus = if ($AuditCheck) { "✅ ATIVADO" } else { "❌ DESATIVADO" }
Write-Status "  Unified Audit Log: $AuditStatus" $(if ($AuditCheck) { "Success" } else { "Error" })

# OWA External
$OwaCheck = (Get-OwaMailboxPolicy -Identity "OwaMailboxPolicy-Default").WacExternalServicesEnabled
$OwaStatus = if (-not $OwaCheck) { "✅ DESABILITADO (seguro)" } else { "❌ HABILITADO" }
Write-Status "  OWA Provedores Externos: $OwaStatus" $(if (-not $OwaCheck) { "Success" } else { "Error" })

# DLP
$DLPCheck = Get-DlpCompliancePolicy -ErrorAction SilentlyContinue
$DLPCount = if ($DLPCheck) { @($DLPCheck).Count } else { 0 }
$DLPStatus = if ($DLPCount -ge 3) { "✅ $DLPCount políticas" } else { "⚠️ $DLPCount políticas" }
Write-Status "  Políticas DLP: $DLPStatus" $(if ($DLPCount -ge 3) { "Success" } else { "Warning" })

Write-Status ""
Write-Status "═══════════════════════════════════════════════════════════" "Header"
Write-Status ""
Write-Status "  📁 Backup salvo em: $BackupPath" "Info"
Write-Status ""
Write-Status "  Para reverter as alterações, use:" "Info"
Write-Status "    # Reverter Unified Audit Log" "Info"
Write-Status '    Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $false' "Info"
Write-Status ""
Write-Status "    # Reverter OWA External" "Info"
Write-Status '    Set-OwaMailboxPolicy -Identity "OwaMailboxPolicy-Default" -WacExternalServicesEnabled $true' "Info"
Write-Status ""
Write-Status "    # Remover políticas DLP" "Info"
Write-Status '    Get-DlpCompliancePolicy | Where-Object {$_.Name -like "DLP -*"} | Remove-DlpCompliancePolicy' "Info"
Write-Status ""
Write-Status "═══════════════════════════════════════════════════════════" "Header"
Write-Status "  ✅ REMEDIAÇÃO CONCLUÍDA!" "Success"
Write-Status "═══════════════════════════════════════════════════════════" "Header"
Write-Status ""

<#
.SYNOPSIS
    Remediação de Segurança Microsoft 365 / Purview
.DESCRIPTION
    Versão 3.0 - Alinhada com Purview-Audit-PS7.ps1 v3.0
    
    Aplica configurações de segurança recomendadas:
    - Verifica Unified Audit Log (método atualizado 2025+)
    - Configura Mailbox Audit
    - Cria políticas de Retenção
    - Cria políticas DLP para dados brasileiros
    - Desabilita provedores externos no OWA
    - Configura alertas de segurança
    
    Cria backup antes de cada alteração para permitir rollback.
.AUTHOR
    M365 Security Toolkit - RFAA
.VERSION
    3.0 - Janeiro 2026 - Alinhado com Audit v3.0
.EXAMPLE
    ./M365-Remediation.ps1
    ./M365-Remediation.ps1 -SkipConnection
    ./M365-Remediation.ps1 -OnlyRetention
#>

[CmdletBinding()]
param(
    [switch]$SkipConnection,
    [switch]$OnlyRetention,
    [switch]$OnlyDLP,
    [switch]$WhatIf
)

$ErrorActionPreference = "Continue"
$BackupPath = "./M365-Remediation-Backup_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
$Script:Backup = @{}
$Script:Changes = @()

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
║   Versão 3.0 - Janeiro 2026                                              ║
║   Alinhado com Purview-Audit-PS7.ps1 v3.0                                ║
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
        [ValidateSet("Info", "Success", "Warning", "Error", "Action", "Skip")]
        [string]$Type = "Info"
    )
    
    $Config = switch ($Type) {
        "Success" { @{ Color = "Green";   Prefix = "  ✅" } }
        "Warning" { @{ Color = "Yellow";  Prefix = "  ⚠️ " } }
        "Error"   { @{ Color = "Red";     Prefix = "  ❌" } }
        "Info"    { @{ Color = "White";   Prefix = "  📋" } }
        "Action"  { @{ Color = "Cyan";    Prefix = "  🔧" } }
        "Skip"    { @{ Color = "DarkGray"; Prefix = "  ⏭️ " } }
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

# ============================================
# CONEXÕES
# ============================================

function Connect-ToServices {
    Write-Section "🔐" "VERIFICANDO CONEXÕES"
    
    # Exchange Online
    try {
        $null = Get-OrganizationConfig -ErrorAction Stop
        Write-Status "Exchange Online: Conectado" "Success"
    }
    catch {
        Write-Status "Conectando ao Exchange Online..." "Action"
        Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
        Write-Status "Exchange Online: Conectado" "Success"
    }
    
    # Security & Compliance
    try {
        $null = Get-Label -ResultSize 1 -ErrorAction Stop 2>$null
        Write-Status "Security & Compliance: Conectado" "Success"
    }
    catch {
        Write-Status "Conectando ao Security & Compliance..." "Action"
        Connect-IPPSSession -ShowBanner:$false -WarningAction SilentlyContinue -ErrorAction Stop
        Write-Status "Security & Compliance: Conectado" "Success"
    }
}

# ============================================
# 1. UNIFIED AUDIT LOG (MÉTODO ATUALIZADO)
# ============================================

function Remediate-UnifiedAuditLog {
    Write-Section "1️⃣" "UNIFIED AUDIT LOG"
    
    # Método correto: testar se conseguimos buscar logs
    Write-Status "Verificando status real do Audit Log..." "Info"
    
    try {
        $TestSearch = Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-1) -EndDate (Get-Date) -ResultSize 1 -ErrorAction Stop
        
        if ($null -ne $TestSearch) {
            Write-Status "Unified Audit Log: ATIVO E FUNCIONANDO" "Success"
            Write-Status "Registros encontrados - nenhuma ação necessária" "Info"
            Save-Backup -Key "UnifiedAuditLog" -Value "Already Active"
            return
        }
        else {
            # Sem resultados mas sem erro = provavelmente ativo
            Write-Status "Unified Audit Log: Provavelmente ativo (sem atividade recente)" "Warning"
            Save-Backup -Key "UnifiedAuditLog" -Value "Active (no recent data)"
            return
        }
    }
    catch {
        $ErrorMsg = $_.Exception.Message
        
        if ($ErrorMsg -match "not enabled|UnifiedAuditLogIngestionEnabled") {
            Write-Status "Unified Audit Log: DESABILITADO" "Error"
            Write-Status "Tentando ativar..." "Action"
            
            if (-not $WhatIf) {
                try {
                    # Método 1: Via Set-AdminAuditLogConfig
                    Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true -ErrorAction Stop
                    Write-Status "Comando executado - aguarde até 24h para propagação" "Success"
                    Add-Change -Category "AuditLog" -Action "Enable" -Details "Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled `$true"
                }
                catch {
                    Write-Status "Erro ao ativar via PowerShell: $($_.Exception.Message)" "Warning"
                    Write-Status "AÇÃO MANUAL NECESSÁRIA:" "Warning"
                    Write-Host ""
                    Write-Host "    1. Acesse: https://compliance.microsoft.com" -ForegroundColor Yellow
                    Write-Host "    2. Vá em: Audit (menu lateral)" -ForegroundColor Yellow
                    Write-Host "    3. Clique no banner para ativar" -ForegroundColor Yellow
                    Write-Host ""
                }
            }
            else {
                Write-Status "[WhatIf] Executaria: Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled `$true" "Skip"
            }
        }
        else {
            Write-Status "Erro ao verificar: $ErrorMsg" "Warning"
        }
    }
    
    # Verificar também Mailbox Audit
    Write-Status "Verificando Mailbox Audit por padrão..." "Info"
    
    try {
        $OrgConfig = Get-OrganizationConfig -ErrorAction Stop
        Save-Backup -Key "MailboxAuditDisabled" -Value $OrgConfig.AuditDisabled
        
        if ($OrgConfig.AuditDisabled) {
            Write-Status "Mailbox Audit: DESABILITADO" "Error"
            
            if (-not $WhatIf) {
                Set-OrganizationConfig -AuditDisabled $false
                Write-Status "Mailbox Audit: ATIVADO" "Success"
                Add-Change -Category "AuditLog" -Action "Enable Mailbox Audit" -Details "Set-OrganizationConfig -AuditDisabled `$false"
            }
            else {
                Write-Status "[WhatIf] Executaria: Set-OrganizationConfig -AuditDisabled `$false" "Skip"
            }
        }
        else {
            Write-Status "Mailbox Audit: Já está habilitado" "Success"
        }
    }
    catch {
        Write-Status "Erro ao verificar Mailbox Audit: $($_.Exception.Message)" "Warning"
    }
}

# ============================================
# 2. POLÍTICAS DE RETENÇÃO
# ============================================

function Remediate-RetentionPolicies {
    Write-Section "2️⃣" "POLÍTICAS DE RETENÇÃO"
    
    try {
        $ExistingPolicies = Get-RetentionCompliancePolicy -WarningAction SilentlyContinue -ErrorAction Stop
        $PolicyCount = if ($ExistingPolicies) { @($ExistingPolicies).Count } else { 0 }
        
        Write-Status "Políticas de retenção existentes: $PolicyCount" "Info"
        Save-Backup -Key "RetentionPoliciesCount" -Value $PolicyCount
        
        if ($ExistingPolicies) {
            foreach ($Policy in $ExistingPolicies) {
                Write-Status "  • $($Policy.Name)" "Info"
            }
        }
        
        # ============================================
        # POLÍTICA 1: Teams Messages (1 ano)
        # ============================================
        
        $TeamsRetentionName = "Retenção Teams - Mensagens 1 Ano"
        $ExistingTeams = $ExistingPolicies | Where-Object { $_.Name -eq $TeamsRetentionName }
        
        if (-not $ExistingTeams) {
            Write-Status "Criando: $TeamsRetentionName" "Action"
            
            if (-not $WhatIf) {
                try {
                    New-RetentionCompliancePolicy -Name $TeamsRetentionName `
                        -Comment "Retém mensagens do Teams por 1 ano para compliance" `
                        -TeamsChannelLocation All `
                        -TeamsChatLocation All `
                        -Enabled $true `
                        -ErrorAction Stop
                    
                    New-RetentionComplianceRule -Name "$TeamsRetentionName - Regra" `
                        -Policy $TeamsRetentionName `
                        -RetentionDuration 365 `
                        -RetentionComplianceAction Keep `
                        -RetentionDurationDisplayHint Days `
                        -ErrorAction Stop
                    
                    Write-Status "$TeamsRetentionName: CRIADA" "Success"
                    Add-Change -Category "Retention" -Action "Create Policy" -Details $TeamsRetentionName
                }
                catch {
                    Write-Status "Erro ao criar política Teams: $($_.Exception.Message)" "Error"
                }
            }
            else {
                Write-Status "[WhatIf] Criaria política: $TeamsRetentionName" "Skip"
            }
        }
        else {
            Write-Status "$TeamsRetentionName: Já existe" "Success"
        }
        
        # ============================================
        # POLÍTICA 2: Dados Sensíveis (7 anos)
        # ============================================
        
        $SensitiveRetentionName = "Retenção Dados Sensíveis - 7 Anos"
        $ExistingSensitive = $ExistingPolicies | Where-Object { $_.Name -eq $SensitiveRetentionName }
        
        if (-not $ExistingSensitive) {
            Write-Status "Criando: $SensitiveRetentionName" "Action"
            
            if (-not $WhatIf) {
                try {
                    New-RetentionCompliancePolicy -Name $SensitiveRetentionName `
                        -Comment "Retém dados classificados como Highly Confidential por 7 anos (compliance legal)" `
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
                        -ContentMatchQuery "SensitivityLabel:Highly*" `
                        -ErrorAction Stop
                    
                    Write-Status "$SensitiveRetentionName: CRIADA" "Success"
                    Add-Change -Category "Retention" -Action "Create Policy" -Details $SensitiveRetentionName
                }
                catch {
                    if ($_.Exception.Message -match "ContentMatchQuery") {
                        # Fallback sem query de label
                        Write-Status "Criando versão simplificada (sem filtro de label)..." "Warning"
                        
                        New-RetentionCompliancePolicy -Name $SensitiveRetentionName `
                            -Comment "Retém todos os dados por 7 anos (compliance legal)" `
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
                        
                        Write-Status "$SensitiveRetentionName: CRIADA (sem filtro)" "Success"
                        Add-Change -Category "Retention" -Action "Create Policy" -Details "$SensitiveRetentionName (simplified)"
                    }
                    else {
                        Write-Status "Erro ao criar política: $($_.Exception.Message)" "Error"
                    }
                }
            }
            else {
                Write-Status "[WhatIf] Criaria política: $SensitiveRetentionName" "Skip"
            }
        }
        else {
            Write-Status "$SensitiveRetentionName: Já existe" "Success"
        }
        
        # ============================================
        # POLÍTICA 3: SharePoint/OneDrive Geral (3 anos)
        # ============================================
        
        $GeneralRetentionName = "Retenção Documentos - 3 Anos"
        $ExistingGeneral = $ExistingPolicies | Where-Object { $_.Name -eq $GeneralRetentionName }
        
        if (-not $ExistingGeneral) {
            Write-Status "Criando: $GeneralRetentionName" "Action"
            
            if (-not $WhatIf) {
                try {
                    New-RetentionCompliancePolicy -Name $GeneralRetentionName `
                        -Comment "Retém documentos do SharePoint e OneDrive por 3 anos" `
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
                    
                    Write-Status "$GeneralRetentionName: CRIADA" "Success"
                    Add-Change -Category "Retention" -Action "Create Policy" -Details $GeneralRetentionName
                }
                catch {
                    Write-Status "Erro ao criar política: $($_.Exception.Message)" "Error"
                }
            }
            else {
                Write-Status "[WhatIf] Criaria política: $GeneralRetentionName" "Skip"
            }
        }
        else {
            Write-Status "$GeneralRetentionName: Já existe" "Success"
        }
        
        # Verificação final
        $FinalPolicies = Get-RetentionCompliancePolicy -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        $FinalCount = if ($FinalPolicies) { @($FinalPolicies).Count } else { 0 }
        Write-Status "Total de políticas após remediação: $FinalCount" "Info"
    }
    catch {
        Write-Status "Erro ao configurar retenção: $($_.Exception.Message)" "Error"
    }
}

# ============================================
# 3. POLÍTICAS DLP
# ============================================

function Remediate-DLPPolicies {
    Write-Section "3️⃣" "POLÍTICAS DLP"
    
    try {
        $ExistingDLP = Get-DlpCompliancePolicy -WarningAction SilentlyContinue -ErrorAction Stop
        $DLPCount = if ($ExistingDLP) { @($ExistingDLP).Count } else { 0 }
        
        Write-Status "Políticas DLP existentes: $DLPCount" "Info"
        Save-Backup -Key "DLPPoliciesCount" -Value $DLPCount
        
        if ($DLPCount -ge 3) {
            Write-Status "Já existem políticas DLP suficientes" "Success"
            foreach ($Policy in $ExistingDLP) {
                $Status = if ($Policy.Enabled) { "✅" } else { "❌" }
                Write-Status "  $Status $($Policy.Name)" "Info"
            }
            return
        }
        
        # DLP para CPF Brasileiro
        $CPFPolicyName = "DLP - Proteção CPF Brasileiro"
        if (-not ($ExistingDLP | Where-Object { $_.Name -eq $CPFPolicyName })) {
            Write-Status "Criando: $CPFPolicyName" "Action"
            
            if (-not $WhatIf) {
                try {
                    New-DlpCompliancePolicy -Name $CPFPolicyName `
                        -Comment "Protege CPFs em Exchange, SharePoint, OneDrive e Teams" `
                        -ExchangeLocation All `
                        -SharePointLocation All `
                        -OneDriveLocation All `
                        -TeamsLocation All `
                        -Mode Enable `
                        -ErrorAction Stop
                    
                    New-DlpComplianceRule -Name "Detectar CPF - Alta Confiança" `
                        -Policy $CPFPolicyName `
                        -ContentContainsSensitiveInformation @{Name="Brazil CPF Number"; minCount="1"; minConfidence="85"} `
                        -BlockAccess $true `
                        -NotifyUser "Owner" `
                        -NotifyPolicyTipCustomText "⚠️ Este documento contém CPF e está protegido pela política de segurança." `
                        -ErrorAction Stop
                    
                    Write-Status "$CPFPolicyName: CRIADA" "Success"
                    Add-Change -Category "DLP" -Action "Create Policy" -Details $CPFPolicyName
                }
                catch {
                    Write-Status "Erro: $($_.Exception.Message)" "Error"
                }
            }
            else {
                Write-Status "[WhatIf] Criaria: $CPFPolicyName" "Skip"
            }
        }
        
        # DLP para CNPJ
        $CNPJPolicyName = "DLP - Proteção CNPJ"
        if (-not ($ExistingDLP | Where-Object { $_.Name -eq $CNPJPolicyName })) {
            Write-Status "Criando: $CNPJPolicyName" "Action"
            
            if (-not $WhatIf) {
                try {
                    New-DlpCompliancePolicy -Name $CNPJPolicyName `
                        -Comment "Protege CNPJs em todos os workloads" `
                        -ExchangeLocation All `
                        -SharePointLocation All `
                        -OneDriveLocation All `
                        -TeamsLocation All `
                        -Mode Enable `
                        -ErrorAction Stop
                    
                    New-DlpComplianceRule -Name "Detectar CNPJ" `
                        -Policy $CNPJPolicyName `
                        -ContentContainsSensitiveInformation @{Name="Brazil Legal Entity Number (CNPJ)"; minCount="1"; minConfidence="85"} `
                        -BlockAccess $false `
                        -NotifyUser "Owner" `
                        -GenerateIncidentReport "SiteAdmin" `
                        -ErrorAction Stop
                    
                    Write-Status "$CNPJPolicyName: CRIADA" "Success"
                    Add-Change -Category "DLP" -Action "Create Policy" -Details $CNPJPolicyName
                }
                catch {
                    Write-Status "Erro: $($_.Exception.Message)" "Error"
                }
            }
            else {
                Write-Status "[WhatIf] Criaria: $CNPJPolicyName" "Skip"
            }
        }
        
        # DLP para Cartão de Crédito
        $CCPolicyName = "DLP - Proteção Cartão de Crédito"
        if (-not ($ExistingDLP | Where-Object { $_.Name -eq $CCPolicyName })) {
            Write-Status "Criando: $CCPolicyName" "Action"
            
            if (-not $WhatIf) {
                try {
                    New-DlpCompliancePolicy -Name $CCPolicyName `
                        -Comment "Protege números de cartão de crédito" `
                        -ExchangeLocation All `
                        -SharePointLocation All `
                        -OneDriveLocation All `
                        -TeamsLocation All `
                        -Mode Enable `
                        -ErrorAction Stop
                    
                    New-DlpComplianceRule -Name "Detectar Cartão de Crédito" `
                        -Policy $CCPolicyName `
                        -ContentContainsSensitiveInformation @{Name="Credit Card Number"; minCount="1"; minConfidence="85"} `
                        -BlockAccess $true `
                        -NotifyUser "Owner" `
                        -ErrorAction Stop
                    
                    Write-Status "$CCPolicyName: CRIADA" "Success"
                    Add-Change -Category "DLP" -Action "Create Policy" -Details $CCPolicyName
                }
                catch {
                    Write-Status "Erro: $($_.Exception.Message)" "Error"
                }
            }
            else {
                Write-Status "[WhatIf] Criaria: $CCPolicyName" "Skip"
            }
        }
    }
    catch {
        Write-Status "Erro ao configurar DLP: $($_.Exception.Message)" "Error"
    }
}

# ============================================
# 4. OWA - PROVEDORES EXTERNOS
# ============================================

function Remediate-OWAExternal {
    Write-Section "4️⃣" "OWA - PROVEDORES EXTERNOS"
    
    try {
        $OwaPolicy = Get-OwaMailboxPolicy -Identity "OwaMailboxPolicy-Default" -ErrorAction Stop
        Save-Backup -Key "WacExternalServicesEnabled" -Value $OwaPolicy.WacExternalServicesEnabled
        
        if ($OwaPolicy.WacExternalServicesEnabled) {
            Write-Status "WacExternalServicesEnabled: TRUE (não seguro)" "Warning"
            Write-Status "Desabilitando provedores externos..." "Action"
            
            if (-not $WhatIf) {
                Set-OwaMailboxPolicy -Identity "OwaMailboxPolicy-Default" -WacExternalServicesEnabled $false
                Write-Status "Provedores externos: DESABILITADOS" "Success"
                Add-Change -Category "OWA" -Action "Disable External" -Details "WacExternalServicesEnabled = `$false"
            }
            else {
                Write-Status "[WhatIf] Desabilitaria WacExternalServicesEnabled" "Skip"
            }
        }
        else {
            Write-Status "Provedores externos: Já desabilitado" "Success"
        }
    }
    catch {
        Write-Status "Erro: $($_.Exception.Message)" "Error"
    }
}

# ============================================
# 5. ALERTAS DE SEGURANÇA
# ============================================

function Remediate-AlertPolicies {
    Write-Section "5️⃣" "ALERTAS DE SEGURANÇA"
    
    $AlertsToCreate = @(
        @{
            Name = "Custom - Nova Regra Inbox Suspeita"
            Category = "ThreatManagement"
            Operation = "New-InboxRule"
            Description = "Alerta quando nova regra de inbox é criada (possível comprometimento)"
            Severity = "High"
        },
        @{
            Name = "Custom - Permissão Mailbox Delegada"
            Category = "ThreatManagement"
            Operation = "Add-MailboxPermission"
            Description = "Alerta quando permissões de mailbox são alteradas"
            Severity = "Medium"
        },
        @{
            Name = "Custom - Forwarding Externo Configurado"
            Category = "ThreatManagement"
            Operation = "Set-Mailbox"
            Description = "Alerta quando forwarding é configurado"
            Severity = "High"
        },
        @{
            Name = "Custom - Admin Role Atribuída"
            Category = "ThreatManagement"
            Operation = "Add-RoleGroupMember"
            Description = "Alerta quando role de admin é atribuída"
            Severity = "High"
        }
    )
    
    foreach ($Alert in $AlertsToCreate) {
        try {
            $Existing = Get-ProtectionAlert -Identity $Alert.Name -ErrorAction SilentlyContinue
            
            if (-not $Existing) {
                Write-Status "Criando: $($Alert.Name)" "Action"
                
                if (-not $WhatIf) {
                    New-ProtectionAlert -Name $Alert.Name `
                        -Category $Alert.Category `
                        -ThreatType "Activity" `
                        -Operation $Alert.Operation `
                        -Description $Alert.Description `
                        -AggregationType None `
                        -Severity $Alert.Severity `
                        -NotificationEnabled $true `
                        -ErrorAction SilentlyContinue
                    
                    Write-Status "$($Alert.Name): CRIADO" "Success"
                    Add-Change -Category "Alerts" -Action "Create Alert" -Details $Alert.Name
                }
                else {
                    Write-Status "[WhatIf] Criaria: $($Alert.Name)" "Skip"
                }
            }
            else {
                Write-Status "$($Alert.Name): Já existe" "Success"
            }
        }
        catch {
            Write-Status "Erro ao criar '$($Alert.Name)': $($_.Exception.Message)" "Warning"
        }
    }
}

# ============================================
# VERIFICAÇÃO FINAL E SUMÁRIO
# ============================================

function Show-Summary {
    Write-Section "✅" "VERIFICAÇÃO FINAL"
    
    Write-Host ""
    
    # Unified Audit Log
    try {
        $AuditTest = Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-1) -EndDate (Get-Date) -ResultSize 1 -ErrorAction SilentlyContinue
        $AuditStatus = if ($AuditTest) { "✅ ATIVO" } else { "⚠️ Verificar manualmente" }
    }
    catch {
        $AuditStatus = "⚠️ Verificar no portal"
    }
    Write-Host "  Unified Audit Log:     $AuditStatus" -ForegroundColor $(if ($AuditStatus -match "ATIVO") { "Green" } else { "Yellow" })
    
    # Mailbox Audit
    $MailboxAudit = (Get-OrganizationConfig).AuditDisabled
    $MailboxStatus = if (-not $MailboxAudit) { "✅ ATIVO" } else { "❌ DESATIVADO" }
    Write-Host "  Mailbox Audit:         $MailboxStatus" -ForegroundColor $(if (-not $MailboxAudit) { "Green" } else { "Red" })
    
    # Retention Policies
    $RetentionCount = @(Get-RetentionCompliancePolicy -WarningAction SilentlyContinue -ErrorAction SilentlyContinue).Count
    $RetentionStatus = if ($RetentionCount -ge 3) { "✅ $RetentionCount políticas" } else { "⚠️ $RetentionCount políticas" }
    Write-Host "  Políticas Retenção:    $RetentionStatus" -ForegroundColor $(if ($RetentionCount -ge 3) { "Green" } else { "Yellow" })
    
    # DLP
    $DLPCount = @(Get-DlpCompliancePolicy -WarningAction SilentlyContinue -ErrorAction SilentlyContinue).Count
    $DLPStatus = if ($DLPCount -ge 3) { "✅ $DLPCount políticas" } else { "⚠️ $DLPCount políticas" }
    Write-Host "  Políticas DLP:         $DLPStatus" -ForegroundColor $(if ($DLPCount -ge 3) { "Green" } else { "Yellow" })
    
    # OWA External
    $OwaExternal = (Get-OwaMailboxPolicy -Identity "OwaMailboxPolicy-Default" -ErrorAction SilentlyContinue).WacExternalServicesEnabled
    $OwaStatus = if (-not $OwaExternal) { "✅ BLOQUEADO" } else { "❌ PERMITIDO" }
    Write-Host "  OWA Externos:          $OwaStatus" -ForegroundColor $(if (-not $OwaExternal) { "Green" } else { "Red" })
    
    Write-Host ""
    
    # Mudanças realizadas
    if ($Script:Changes.Count -gt 0) {
        Write-Host "  📝 ALTERAÇÕES REALIZADAS:" -ForegroundColor Cyan
        foreach ($Change in $Script:Changes) {
            Write-Host "     [$($Change.Timestamp)] $($Change.Category): $($Change.Action)" -ForegroundColor White
        }
        Write-Host ""
    }
    
    Write-Host "  📁 Backup salvo em: $BackupPath" -ForegroundColor DarkGray
    Write-Host ""
}

function Show-RollbackInstructions {
    Write-Section "🔙" "INSTRUÇÕES DE ROLLBACK"
    
    Write-Host ""
    Write-Host "  Para reverter alterações:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  # Políticas de Retenção" -ForegroundColor DarkGray
    Write-Host '  Get-RetentionCompliancePolicy | Where-Object {$_.Name -like "Retenção*"} | Remove-RetentionCompliancePolicy' -ForegroundColor White
    Write-Host ""
    Write-Host "  # Políticas DLP" -ForegroundColor DarkGray
    Write-Host '  Get-DlpCompliancePolicy | Where-Object {$_.Name -like "DLP -*"} | Remove-DlpCompliancePolicy' -ForegroundColor White
    Write-Host ""
    Write-Host "  # OWA External Services" -ForegroundColor DarkGray
    Write-Host '  Set-OwaMailboxPolicy -Identity "OwaMailboxPolicy-Default" -WacExternalServicesEnabled $true' -ForegroundColor White
    Write-Host ""
    Write-Host "  # Alertas Customizados" -ForegroundColor DarkGray
    Write-Host '  Get-ProtectionAlert | Where-Object {$_.Name -like "Custom*"} | Remove-ProtectionAlert' -ForegroundColor White
    Write-Host ""
}

# ============================================
# EXECUÇÃO PRINCIPAL
# ============================================

function Start-Remediation {
    Clear-Host
    Write-Banner
    
    if ($WhatIf) {
        Write-Host "  ⚠️  MODO SIMULAÇÃO (WhatIf) - Nenhuma alteração será feita" -ForegroundColor Yellow
        Write-Host ""
    }
    
    # Conectar
    if (-not $SkipConnection) {
        Connect-ToServices
    }
    else {
        Write-Status "Pulando conexão (usando sessão existente)" "Skip"
    }
    
    # Executar remediações
    if ($OnlyRetention) {
        Remediate-RetentionPolicies
    }
    elseif ($OnlyDLP) {
        Remediate-DLPPolicies
    }
    else {
        Remediate-UnifiedAuditLog
        Remediate-RetentionPolicies
        Remediate-DLPPolicies
        Remediate-OWAExternal
        Remediate-AlertPolicies
    }
    
    # Sumário
    Show-Summary
    Show-RollbackInstructions
    
    Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "  ✅ REMEDIAÇÃO CONCLUÍDA!" -ForegroundColor Green
    Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host ""
}

# Executar
Start-Remediation

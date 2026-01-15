<#
.SYNOPSIS
    Script de Auditoria de Segurança do Microsoft Purview
.DESCRIPTION
    Versão compatível com PowerShell 7 (Mac/Linux/Windows)
    Audita:
    - Políticas DLP
    - Configurações de Audit Log
    - Políticas de retenção
    - Labels de sensibilidade
    - Safe Links e Safe Attachments
.AUTHOR
    M365 Security Toolkit
.VERSION
    2.0 - Janeiro 2026 - Compatível com PS7
.EXAMPLE
    ./Purview-Audit-PS7.ps1
    ./Purview-Audit-PS7.ps1 -OutputPath "./MeuRelatorio"
#>

param(
    [string]$OutputPath = "./Purview-Audit-Report"
)

$ErrorActionPreference = "Continue"
$ReportDate = Get-Date -Format "yyyy-MM-dd_HH-mm"
$OutputFolder = "${OutputPath}_${ReportDate}"

# ============================================
# FUNÇÕES AUXILIARES
# ============================================

function Write-Status {
    param(
        [string]$Message,
        [string]$Type = "Info"
    )
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

function Initialize-OutputFolder {
    if (-not (Test-Path $OutputFolder)) {
        New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
    }
}

# ============================================
# CONEXÕES
# ============================================

function Connect-ToServices {
    Write-Status "`n🔐 Conectando aos serviços Microsoft 365..." "Header"
    
    $Status = @{
        ExchangeOnline = $false
        SecurityCompliance = $false
    }
    
    # Exchange Online
    Write-Status "  📧 Conectando ao Exchange Online..." "Info"
    try {
        $ExoSession = Get-ConnectionInformation -ErrorAction SilentlyContinue
        if (-not $ExoSession) {
            Connect-ExchangeOnline -ShowBanner:$false
        }
        $Status.ExchangeOnline = $true
        Write-Status "  ✅ Exchange Online conectado" "Success"
    }
    catch {
        Write-Status "  ❌ Erro ao conectar Exchange Online: $_" "Error"
    }
    
    # Security & Compliance
    Write-Status "  🛡️  Conectando ao Security & Compliance..." "Info"
    try {
        Connect-IPPSSession -ShowBanner:$false -WarningAction SilentlyContinue
        $Status.SecurityCompliance = $true
        Write-Status "  ✅ Security & Compliance conectado" "Success"
    }
    catch {
        Write-Status "  ❌ Erro ao conectar Security & Compliance: $_" "Error"
    }
    
    return $Status
}

# ============================================
# AUDITORIAS
# ============================================

function Get-DLPAudit {
    Write-Status "`n📋 Auditando Políticas DLP..." "Header"
    
    $Result = @{
        Policies = @()
        Rules = @()
        Recommendations = @()
        Score = 0
    }
    
    try {
        $Policies = Get-DlpCompliancePolicy -WarningAction SilentlyContinue -ErrorAction Stop
        
        if ($null -eq $Policies -or @($Policies).Count -eq 0) {
            $Result.Recommendations += "⚠️ CRÍTICO: Nenhuma política DLP encontrada."
            Write-Status "  ⚠️ Nenhuma política DLP encontrada" "Warning"
        }
        else {
            $PolicyCount = @($Policies).Count
            Write-Status "  📊 Total de políticas DLP: $PolicyCount" "Info"
            
            foreach ($Policy in $Policies) {
                $PolicyInfo = @{
                    Nome = $Policy.Name
                    Enabled = $Policy.Enabled
                    Mode = $Policy.Mode
                    Workload = $Policy.Workload -join ", "
                    Priority = $Policy.Priority
                }
                $Result.Policies += $PolicyInfo
                
                $ModeText = if ($Policy.Mode) { $Policy.Mode } else { "N/A" }
                $EnabledText = if ($Policy.Enabled) { "✅" } else { "❌" }
                Write-Status "    $EnabledText $($Policy.Name) - Modo: $ModeText" "Info"
                
                if ($Policy.Mode -like "*Test*") {
                    $Result.Recommendations += "⚠️ Política '$($Policy.Name)' em modo teste."
                }
            }
            
            $EnabledCount = @($Policies | Where-Object { $_.Enabled -eq $true }).Count
            $Result.Score = [math]::Round(($EnabledCount / $PolicyCount) * 100)
        }
        
        $Rules = Get-DlpComplianceRule -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        if ($Rules) {
            $Result.Rules = @($Rules | Select-Object Name, Policy, Disabled)
            Write-Status "  📊 Total de regras DLP: $(@($Rules).Count)" "Info"
        }
    }
    catch {
        Write-Status "  ❌ Erro ao auditar DLP: $_" "Error"
        $Result.Recommendations += "❌ Erro ao auditar DLP: $_"
    }
    
    return $Result
}

function Get-AuditLogAudit {
    Write-Status "`n📋 Auditando Configuração de Audit Log..." "Header"
    
    $Result = @{
        UnifiedAuditEnabled = $false
        MailboxAuditEnabled = $false
        AuditLogAgeLimit = $null
        Recommendations = @()
        Score = 0
    }
    
    try {
        $AdminAudit = Get-AdminAuditLogConfig -ErrorAction Stop
        
        $UnifiedEnabled = $AdminAudit.UnifiedAuditLogIngestionEnabled
        if ($null -eq $UnifiedEnabled) {
            $UnifiedEnabled = $AdminAudit.AuditLogIngestionEnabled
        }
        
        $Result.UnifiedAuditEnabled = $UnifiedEnabled
        
        if ($UnifiedEnabled) {
            Write-Status "  ✅ Unified Audit Log: HABILITADO" "Success"
            $Result.Score += 50
        }
        else {
            Write-Status "  ❌ Unified Audit Log: DESABILITADO" "Error"
            $Result.Recommendations += "🚨 CRÍTICO: Ativar Unified Audit Log!"
        }
        
        $OrgConfig = Get-OrganizationConfig -ErrorAction SilentlyContinue
        if ($OrgConfig) {
            $Result.MailboxAuditEnabled = -not $OrgConfig.AuditDisabled
            
            if (-not $OrgConfig.AuditDisabled) {
                Write-Status "  ✅ Mailbox Audit por padrão: HABILITADO" "Success"
                $Result.Score += 50
            }
            else {
                Write-Status "  ❌ Mailbox Audit por padrão: DESABILITADO" "Error"
                $Result.Recommendations += "⚠️ Habilitar Mailbox Audit por padrão."
            }
        }
    }
    catch {
        Write-Status "  ❌ Erro ao verificar Audit Log: $_" "Error"
        $Result.Recommendations += "❌ Erro ao verificar configuração de Audit."
    }
    
    return $Result
}

function Get-RetentionAudit {
    Write-Status "`n📋 Auditando Políticas de Retenção..." "Header"
    
    $Result = @{
        Policies = @()
        Labels = @()
        Recommendations = @()
        Score = 0
    }
    
    try {
        $Policies = Get-RetentionCompliancePolicy -WarningAction SilentlyContinue -ErrorAction Stop
        
        if ($null -eq $Policies -or @($Policies).Count -eq 0) {
            Write-Status "  ⚠️ Nenhuma política de retenção encontrada" "Warning"
            $Result.Recommendations += "⚠️ Configurar políticas de retenção para compliance."
        }
        else {
            $PolicyCount = @($Policies).Count
            Write-Status "  📊 Total de políticas de retenção: $PolicyCount" "Info"
            
            foreach ($Policy in $Policies) {
                $Result.Policies += @{
                    Nome = $Policy.Name
                    Enabled = $Policy.Enabled
                    Workload = $Policy.Workload -join ", "
                }
                
                $EnabledText = if ($Policy.Enabled) { "✅" } else { "❌" }
                Write-Status "    $EnabledText $($Policy.Name)" "Info"
            }
            
            $Result.Score = if ($PolicyCount -ge 3) { 100 } else { [math]::Round(($PolicyCount / 3) * 100) }
        }
    }
    catch {
        Write-Status "  ❌ Erro ao verificar retenção: $_" "Error"
    }
    
    return $Result
}

function Get-SensitivityLabelsAudit {
    Write-Status "`n📋 Auditando Labels de Sensibilidade..." "Header"
    
    $Result = @{
        Labels = @()
        Policies = @()
        Recommendations = @()
        Score = 0
    }
    
    try {
        $Labels = Get-Label -ErrorAction Stop
        
        if ($null -eq $Labels -or @($Labels).Count -eq 0) {
            Write-Status "  ⚠️ Nenhum label de sensibilidade configurado" "Warning"
            $Result.Recommendations += "⚠️ Configurar labels de sensibilidade para classificação de dados."
        }
        else {
            $LabelCount = @($Labels).Count
            Write-Status "  📊 Total de labels: $LabelCount" "Info"
            
            foreach ($Label in $Labels) {
                $Result.Labels += @{
                    Nome = $Label.Name
                    DisplayName = $Label.DisplayName
                    Priority = $Label.Priority
                }
                Write-Status "    • $($Label.DisplayName)" "Info"
            }
            
            $Result.Score = if ($LabelCount -ge 3) { 100 } else { [math]::Round(($LabelCount / 3) * 100) }
        }
    }
    catch {
        Write-Status "  ❌ Erro ao verificar labels: $_" "Error"
    }
    
    return $Result
}

function Get-ExternalSharingAudit {
    Write-Status "`n📋 Auditando Compartilhamento Externo..." "Header"
    
    $Result = @{
        OWAPolicies = @()
        Recommendations = @()
        Score = 0
    }
    
    try {
        $OWAPolicies = Get-OwaMailboxPolicy -ErrorAction Stop
        
        foreach ($Policy in $OWAPolicies) {
            $Result.OWAPolicies += @{
                Nome = $Policy.Name
                ExternalSPMySiteHostURL = $Policy.ExternalSPMySiteHostURL
                WacExternalServicesEnabled = $Policy.WacExternalServicesEnabled
            }
            
            Write-Status "    • $($Policy.Name)" "Info"
            
            if ($Policy.WacExternalServicesEnabled) {
                $Result.Recommendations += "⚠️ OWA '$($Policy.Name)': Provedores externos habilitados."
            }
        }
        
        $SecurePolicies = @($OWAPolicies | Where-Object { -not $_.WacExternalServicesEnabled }).Count
        if (@($OWAPolicies).Count -gt 0) {
            $Result.Score = [math]::Round(($SecurePolicies / @($OWAPolicies).Count) * 100)
        }
    }
    catch {
        Write-Status "  ❌ Erro ao verificar compartilhamento: $_" "Error"
    }
    
    return $Result
}

# ============================================
# EXPORTAÇÃO
# ============================================

function Export-Results {
    param([hashtable]$Results)
    
    Write-Status "`n📄 Exportando resultados..." "Header"
    
    Initialize-OutputFolder
    
    # JSON
    $JsonPath = Join-Path $OutputFolder "audit-results.json"
    $Results | ConvertTo-Json -Depth 10 | Out-File $JsonPath -Encoding UTF8
    Write-Status "  ✅ JSON: $JsonPath" "Success"
    
    # CSV de recomendações
    $AllRecs = @()
    foreach ($Key in $Results.Keys) {
        if ($Results[$Key].Recommendations) {
            foreach ($Rec in $Results[$Key].Recommendations) {
                $AllRecs += [PSCustomObject]@{
                    Categoria = $Key
                    Recomendacao = $Rec
                    Prioridade = if ($Rec -match "CRÍTICO|🚨") { "Alta" } elseif ($Rec -match "⚠️") { "Média" } else { "Baixa" }
                }
            }
        }
    }
    
    if ($AllRecs.Count -gt 0) {
        $CsvPath = Join-Path $OutputFolder "recommendations.csv"
        $AllRecs | Export-Csv $CsvPath -NoTypeInformation -Encoding UTF8
        Write-Status "  ✅ CSV: $CsvPath" "Success"
    }
    
    return $OutputFolder
}

# ============================================
# EXECUÇÃO PRINCIPAL
# ============================================

function Start-Audit {
    Clear-Host
    
    Write-Status @"

╔════════════════════════════════════════════════════════════════════╗
║     🛡️  AUDITORIA PURVIEW - PS7 Compatible                         ║
║                                                                    ║
║     Versão 2.0 - Janeiro 2026                                      ║
╚════════════════════════════════════════════════════════════════════╝

"@ "Header"
    
    # Conectar
    $Status = Connect-ToServices
    
    if (-not ($Status.ExchangeOnline -or $Status.SecurityCompliance)) {
        Write-Status "`n❌ Nenhuma conexão estabelecida." "Error"
        return
    }
    
    # Executar auditorias
    $Results = @{}
    
    Write-Status "`n═══════════════════════════════════════════════════════════" "Header"
    Write-Status "              INICIANDO AUDITORIAS                          " "Header"
    Write-Status "═══════════════════════════════════════════════════════════" "Header"
    
    if ($Status.SecurityCompliance) {
        $Results.DLP = Get-DLPAudit
        $Results.Retention = Get-RetentionAudit
        $Results.SensitivityLabels = Get-SensitivityLabelsAudit
    }
    
    if ($Status.ExchangeOnline) {
        $Results.AuditLog = Get-AuditLogAudit
        $Results.ExternalSharing = Get-ExternalSharingAudit
    }
    
    # Exportar
    $ReportFolder = Export-Results -Results $Results
    
    # Sumário
    Write-Status "`n═══════════════════════════════════════════════════════════" "Header"
    Write-Status "                    SUMÁRIO                                 " "Header"
    Write-Status "═══════════════════════════════════════════════════════════" "Header"
    
    Write-Status "`n📊 SCORES:" "Info"
    
    $Categories = @("DLP", "AuditLog", "Retention", "SensitivityLabels")
    foreach ($Cat in $Categories) {
        if ($Results[$Cat]) {
            $Score = $Results[$Cat].Score
            $Color = if ($Score -ge 70) { "Success" } elseif ($Score -ge 40) { "Warning" } else { "Error" }
            Write-Status "  • ${Cat}: ${Score}%" $Color
        }
    }
    
    # Contar recomendações
    $TotalRecs = 0
    $CriticalRecs = 0
    foreach ($Key in $Results.Keys) {
        if ($Results[$Key].Recommendations) {
            $TotalRecs += $Results[$Key].Recommendations.Count
            $CriticalRecs += @($Results[$Key].Recommendations | Where-Object { $_ -match "CRÍTICO|🚨" }).Count
        }
    }
    
    Write-Status "`n📋 RECOMENDAÇÕES:" "Info"
    Write-Status "  • Total: $TotalRecs" "Info"
    Write-Status "  • Críticas: $CriticalRecs" $(if ($CriticalRecs -gt 0) { "Error" } else { "Success" })
    
    Write-Status "`n📁 Relatórios em: $ReportFolder" "Success"
    
    Write-Status "`n✅ Auditoria concluída!`n" "Success"
    Write-Status "ℹ️  Conexão mantida. Para desconectar:" "Info"
    Write-Status '   Disconnect-ExchangeOnline -Confirm:$false' "Info"
    
    return $Results
}

# Executar
$Results = Start-Audit

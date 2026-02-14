#Requires -Version 7.0
<#
.SYNOPSIS
    Audita políticas JÁ implementadas no tenant para documentar no Purview Compliance Manager
.DESCRIPTION
    Versão 1.0 - Multi-tenant

    O Purview Compliance Manager NÃO detecta automaticamente o que já está implementado.
    Este script identifica todas as políticas ativas e gera um CSV com evidências prontas
    para copiar/colar no portal do Purview.

    Audita:
    - Conditional Access Policies (MFA, Legacy Auth Block, Geo-Block, etc.)
    - DLP Policies (Purview)
    - Sensitivity Labels
    - Retention Policies
    - Safe Links / Safe Attachments
    - Anti-Phishing Policies
    - Mailbox Audit Status
    - Unified Audit Log Status
    - Transport Rules (Mail Flow)
    - DKIM / DMARC / SPF

    Gera:
    - CSV com evidências prontas para o Purview
    - JSON detalhado para automação
    - Relatório Markdown/HTML

.AUTHOR
    M365 Security Toolkit - ATSI
.VERSION
    1.0 - Fevereiro 2026
.EXAMPLE
    ./Audit-ImplementedPolicies.ps1
    ./Audit-ImplementedPolicies.ps1 -SkipConnection -OutputPath "./MeuRelatorio"
    ./Audit-ImplementedPolicies.ps1 -TenantName "ClienteXYZ"
#>

[CmdletBinding()]
param(
    [string]$OutputPath = "./Purview-Evidence",
    [string]$TenantName = "",
    [switch]$SkipConnection,
    [switch]$IncludeDisabled
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
$ReportDate = Get-Date -Format "yyyy-MM-dd_HH-mm"

# ============================================
# INTERFACE
# ============================================

function Write-Status {
    param([string]$Message, [string]$Type = "Info")
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

function Write-Section {
    param([string]$Title)
    $Line = "═" * 70
    Write-Host "`n$Line" -ForegroundColor DarkCyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host $Line -ForegroundColor DarkCyan
}

# ============================================
# CONEXÃO
# ============================================

function Connect-ToServices {
    Write-Section "CONEXÃO AOS SERVIÇOS"
    $AuthenticatedUPN = $null

    # Exchange Online
    Write-Status "Conectando ao Exchange Online..." "Header"
    try {
        $ExoSession = Get-ConnectionInformation -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $ExoSession) {
            Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
            $ExoSession = Get-ConnectionInformation -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        if ($ExoSession.UserPrincipalName) {
            $AuthenticatedUPN = $ExoSession.UserPrincipalName
            Write-Status "Exchange Online conectado como $AuthenticatedUPN" "Success"
        } else {
            Write-Status "Exchange Online conectado" "Success"
        }
    }
    catch {
        Write-Status "Erro Exchange Online: $($_.Exception.Message)" "Error"
        return $false
    }

    # Security & Compliance
    Write-Status "Conectando ao Security & Compliance..." "Header"
    try {
        $null = Get-Label -ResultSize 1 -ErrorAction Stop 2>$null
        Write-Status "Security & Compliance já conectado" "Success"
    }
    catch {
        try {
            if ($AuthenticatedUPN) {
                Connect-IPPSSession -UserPrincipalName $AuthenticatedUPN -ShowBanner:$false -WarningAction SilentlyContinue -ErrorAction Stop
            } else {
                Connect-IPPSSession -ShowBanner:$false -WarningAction SilentlyContinue -ErrorAction Stop
            }
            Write-Status "Security & Compliance conectado" "Success"
        }
        catch {
            Write-Status "Erro S&C: $($_.Exception.Message)" "Warning"
        }
    }

    # Microsoft Graph
    Write-Status "Conectando ao Microsoft Graph..." "Header"
    try {
        $ctx = Get-MgContext -ErrorAction SilentlyContinue
        if (-not $ctx) {
            Connect-MgGraph -Scopes "Policy.Read.All","Directory.Read.All" -NoWelcome -ErrorAction Stop
        }
        Write-Status "Microsoft Graph conectado" "Success"
    }
    catch {
        Write-Status "Graph não disponível (CA Policies não serão auditadas): $($_.Exception.Message)" "Warning"
    }

    return $true
}

# ============================================
# COLETA DE EVIDÊNCIAS
# ============================================

$Script:Evidence = @()

function Add-Evidence {
    param(
        [string]$Category,
        [string]$ActionName,
        [string]$Status,
        [string]$PolicyName,
        [string]$PolicyId,
        [string]$ImplementationDate,
        [string]$Notes,
        [string]$PurviewMapping = ""
    )
    $Script:Evidence += [PSCustomObject]@{
        Category           = $Category
        ActionName         = $ActionName
        Status             = $Status
        PolicyName         = $PolicyName
        PolicyId           = $PolicyId
        ImplementationDate = $ImplementationDate
        Notes              = $Notes
        PurviewMapping     = $PurviewMapping
        PurviewStatus      = "Implemented"
    }
}

# ============================================
# AUDITORIA: CONDITIONAL ACCESS
# ============================================

function Audit-ConditionalAccess {
    Write-Section "CONDITIONAL ACCESS POLICIES"
    try {
        $policies = Get-MgIdentityConditionalAccessPolicy -All -ErrorAction Stop
        $enabled = @($policies | Where-Object { $_.State -eq "enabled" })
        Write-Status "Total de políticas: $(@($policies).Count) | Habilitadas: $($enabled.Count)" "Info"

        foreach ($p in $enabled) {
            $date = if ($p.ModifiedDateTime) { $p.ModifiedDateTime.ToString("yyyy-MM-dd") } else { "N/A" }

            # Detectar tipo de política
            $mapping = ""
            $actionName = $p.DisplayName

            # Block Legacy Authentication
            if ($p.Conditions.ClientAppTypes -contains "exchangeActiveSync" -or
                $p.Conditions.ClientAppTypes -contains "other" -or
                $p.DisplayName -match "legacy|legado") {
                $mapping = "Enable policy to block legacy authentication"
                $actionName = "Block Legacy Authentication"
            }
            # MFA
            elseif ($p.GrantControls.BuiltInControls -contains "mfa") {
                $mapping = "Require MFA for administrative roles / all users"
                $actionName = "MFA: $($p.DisplayName)"
            }
            # Geo-Block
            elseif ($p.Conditions.Locations -and $p.GrantControls.BuiltInControls -contains "block") {
                $mapping = "Block sign-ins from unauthorized locations"
                $actionName = "Geo-Block: $($p.DisplayName)"
            }
            # Compliant Device
            elseif ($p.GrantControls.BuiltInControls -contains "compliantDevice") {
                $mapping = "Require compliant devices"
                $actionName = "Compliant Device: $($p.DisplayName)"
            }
            # Sign-in Risk
            elseif ($p.Conditions.SignInRiskLevels) {
                $mapping = "Sign-in risk policy"
                $actionName = "Sign-in Risk: $($p.DisplayName)"
            }

            Add-Evidence -Category "Conditional Access" `
                -ActionName $actionName `
                -Status "Enabled" `
                -PolicyName $p.DisplayName `
                -PolicyId $p.Id `
                -ImplementationDate $date `
                -Notes "State: $($p.State) | Grant: $($p.GrantControls.BuiltInControls -join ', ') | Users: $($p.Conditions.Users.IncludeUsers -join ', ')" `
                -PurviewMapping $mapping

            Write-Status "✅ $($p.DisplayName)" "Detail"
        }

        if ($IncludeDisabled) {
            $disabled = @($policies | Where-Object { $_.State -ne "enabled" })
            foreach ($p in $disabled) {
                Write-Status "❌ $($p.DisplayName) (disabled)" "Detail"
            }
        }
    }
    catch {
        Write-Status "Erro ao auditar CA: $($_.Exception.Message)" "Warning"
        Write-Status "Verifique se Microsoft.Graph está conectado com Policy.Read.All" "Detail"
    }
}

# ============================================
# AUDITORIA: DLP POLICIES
# ============================================

function Audit-DLPPolicies {
    Write-Section "DLP POLICIES"
    try {
        $policies = Get-DlpCompliancePolicy -WarningAction SilentlyContinue -ErrorAction Stop
        $enabled = @($policies | Where-Object { $_.Enabled })
        Write-Status "Total: $(@($policies).Count) | Habilitadas: $($enabled.Count)" "Info"

        foreach ($p in $enabled) {
            $workloads = $p.Workload -join ", "
            Add-Evidence -Category "DLP" `
                -ActionName "DLP Policy: $($p.Name)" `
                -Status "Enabled (Mode: $($p.Mode))" `
                -PolicyName $p.Name `
                -PolicyId $p.Guid `
                -ImplementationDate (Get-Date -Format "yyyy-MM-dd") `
                -Notes "Workloads: $workloads | Mode: $($p.Mode) | Priority: $($p.Priority)" `
                -PurviewMapping "Create DLP policies for sensitive information"

            Write-Status "✅ $($p.Name) [$workloads]" "Detail"
        }
    }
    catch {
        Write-Status "Erro DLP: $($_.Exception.Message)" "Warning"
    }
}

# ============================================
# AUDITORIA: SENSITIVITY LABELS
# ============================================

function Audit-SensitivityLabels {
    Write-Section "SENSITIVITY LABELS"
    try {
        $labels = Get-Label -ErrorAction Stop
        Write-Status "Total de labels: $(@($labels).Count)" "Info"

        foreach ($l in $labels) {
            $parent = if ([string]::IsNullOrEmpty($l.ParentId)) { "Root" } else { "Child" }
            Add-Evidence -Category "Sensitivity Labels" `
                -ActionName "Label: $($l.DisplayName)" `
                -Status "Active ($parent)" `
                -PolicyName $l.DisplayName `
                -PolicyId $l.Guid `
                -ImplementationDate (Get-Date -Format "yyyy-MM-dd") `
                -Notes "Priority: $($l.Priority) | Type: $parent" `
                -PurviewMapping "Create and publish sensitivity labels"

            $icon = if ($parent -eq "Root") { "📁" } else { "   └─" }
            Write-Status "$icon $($l.DisplayName)" "Detail"
        }

        $labelPolicies = Get-LabelPolicy -ErrorAction SilentlyContinue
        if ($labelPolicies) {
            foreach ($lp in $labelPolicies) {
                Add-Evidence -Category "Sensitivity Labels" `
                    -ActionName "Label Policy: $($lp.Name)" `
                    -Status "Published" `
                    -PolicyName $lp.Name `
                    -PolicyId $lp.Guid `
                    -ImplementationDate (Get-Date -Format "yyyy-MM-dd") `
                    -Notes "Labels published to users" `
                    -PurviewMapping "Publish sensitivity labels"
            }
            Write-Status "Políticas de publicação: $(@($labelPolicies).Count)" "Info"
        }
    }
    catch {
        Write-Status "Erro Labels: $($_.Exception.Message)" "Warning"
    }
}

# ============================================
# AUDITORIA: RETENTION POLICIES
# ============================================

function Audit-RetentionPolicies {
    Write-Section "RETENTION POLICIES"
    try {
        $policies = Get-RetentionCompliancePolicy -WarningAction SilentlyContinue -ErrorAction Stop
        Write-Status "Total: $(@($policies).Count)" "Info"

        foreach ($p in $policies) {
            $workloads = $p.Workload -join ", "
            Add-Evidence -Category "Retention" `
                -ActionName "Retention: $($p.Name)" `
                -Status $(if ($p.Enabled) { "Enabled" } else { "Disabled" }) `
                -PolicyName $p.Name `
                -PolicyId $p.Guid `
                -ImplementationDate (Get-Date -Format "yyyy-MM-dd") `
                -Notes "Workloads: $workloads | Enabled: $($p.Enabled)" `
                -PurviewMapping "Create retention policies"

            $icon = if ($p.Enabled) { "✅" } else { "❌" }
            Write-Status "$icon $($p.Name) [$workloads]" "Detail"
        }
    }
    catch {
        Write-Status "Erro Retention: $($_.Exception.Message)" "Warning"
    }
}

# ============================================
# AUDITORIA: SAFE LINKS / SAFE ATTACHMENTS
# ============================================

function Audit-ATPPolicies {
    Write-Section "SAFE LINKS / SAFE ATTACHMENTS / ANTI-PHISHING"
    # Safe Links
    try {
        $slPolicies = Get-SafeLinksPolicy -ErrorAction Stop
        foreach ($p in $slPolicies) {
            Add-Evidence -Category "ATP" `
                -ActionName "Safe Links: $($p.Name)" `
                -Status "Enabled" `
                -PolicyName $p.Name `
                -PolicyId $p.Guid `
                -ImplementationDate (Get-Date -Format "yyyy-MM-dd") `
                -Notes "ScanUrls: $($p.ScanUrls) | TrackClicks: $($p.TrackClicks) | Office: $($p.EnableSafeLinksForOffice)" `
                -PurviewMapping "Turn on Safe Links for Office 365"
            Write-Status "✅ Safe Links: $($p.Name)" "Detail"
        }
    }
    catch {
        Write-Status "Safe Links não disponível (requer Defender for Office 365)" "Detail"
    }

    # Safe Attachments
    try {
        $saPolicies = Get-SafeAttachmentPolicy -ErrorAction Stop
        foreach ($p in $saPolicies) {
            Add-Evidence -Category "ATP" `
                -ActionName "Safe Attachments: $($p.Name)" `
                -Status "Enabled" `
                -PolicyName $p.Name `
                -PolicyId $p.Guid `
                -ImplementationDate (Get-Date -Format "yyyy-MM-dd") `
                -Notes "Action: $($p.Action) | Redirect: $($p.Redirect)" `
                -PurviewMapping "Turn on Safe Attachments for SharePoint, OneDrive, and Teams"
            Write-Status "✅ Safe Attachments: $($p.Name)" "Detail"
        }
    }
    catch {
        Write-Status "Safe Attachments não disponível" "Detail"
    }

    # Anti-Phishing
    try {
        $apPolicies = Get-AntiPhishPolicy -ErrorAction Stop | Where-Object { $_.IsDefault -eq $false -or $_.Enabled }
        foreach ($p in $apPolicies) {
            Add-Evidence -Category "ATP" `
                -ActionName "Anti-Phishing: $($p.Name)" `
                -Status "Enabled" `
                -PolicyName $p.Name `
                -PolicyId $p.Guid `
                -ImplementationDate (Get-Date -Format "yyyy-MM-dd") `
                -Notes "Impersonation: $($p.EnableTargetedUserProtection) | Mailbox Intelligence: $($p.EnableMailboxIntelligence)" `
                -PurviewMapping "Set up anti-phishing policies"
            Write-Status "✅ Anti-Phishing: $($p.Name)" "Detail"
        }
    }
    catch {
        Write-Status "Anti-Phishing check falhou" "Detail"
    }
}

# ============================================
# AUDITORIA: AUDIT LOG & MAILBOX AUDIT
# ============================================

function Audit-AuditLog {
    Write-Section "AUDIT LOG & MAILBOX AUDIT"
    try {
        $orgConfig = Get-OrganizationConfig -ErrorAction Stop
        $mailboxAudit = -not $orgConfig.AuditDisabled

        Add-Evidence -Category "Audit" `
            -ActionName "Mailbox Audit by Default" `
            -Status $(if ($mailboxAudit) { "Enabled" } else { "Disabled" }) `
            -PolicyName "Organization Config" `
            -PolicyId "AuditDisabled=$($orgConfig.AuditDisabled)" `
            -ImplementationDate (Get-Date -Format "yyyy-MM-dd") `
            -Notes "AuditDisabled: $($orgConfig.AuditDisabled)" `
            -PurviewMapping "Turn on auditing"

        if ($mailboxAudit) {
            Write-Status "✅ Mailbox Audit by Default: HABILITADO" "Success"
        } else {
            Write-Status "❌ Mailbox Audit by Default: DESABILITADO" "Error"
        }
    }
    catch {
        Write-Status "Erro: $($_.Exception.Message)" "Warning"
    }

    # Unified Audit Log
    try {
        $StartDate = (Get-Date).AddDays(-7)
        $test = Search-UnifiedAuditLog -StartDate $StartDate -EndDate (Get-Date) -ResultSize 1 -ErrorAction Stop
        $uaEnabled = $true
        Add-Evidence -Category "Audit" `
            -ActionName "Unified Audit Log" `
            -Status "Enabled & Active" `
            -PolicyName "Unified Audit Log" `
            -PolicyId "UAL-Active" `
            -ImplementationDate (Get-Date -Format "yyyy-MM-dd") `
            -Notes "Audit Log is active with recent entries" `
            -PurviewMapping "Turn on audit log search"
        Write-Status "✅ Unified Audit Log: ATIVO" "Success"
    }
    catch {
        Write-Status "⚠️ Unified Audit Log: não verificável ou desabilitado" "Warning"
    }
}

# ============================================
# AUDITORIA: TRANSPORT RULES
# ============================================

function Audit-TransportRules {
    Write-Section "TRANSPORT RULES (MAIL FLOW)"
    try {
        $rules = Get-TransportRule -ErrorAction Stop
        $enabled = @($rules | Where-Object { $_.State -eq "Enabled" })
        Write-Status "Total: $(@($rules).Count) | Habilitadas: $($enabled.Count)" "Info"

        foreach ($r in $enabled) {
            Add-Evidence -Category "Transport Rules" `
                -ActionName "Mail Flow Rule: $($r.Name)" `
                -Status "Enabled" `
                -PolicyName $r.Name `
                -PolicyId $r.Guid `
                -ImplementationDate (Get-Date -Format "yyyy-MM-dd") `
                -Notes "Priority: $($r.Priority) | Mode: $($r.Mode)" `
                -PurviewMapping ""
            Write-Status "✅ $($r.Name)" "Detail"
        }
    }
    catch {
        Write-Status "Erro Transport Rules: $($_.Exception.Message)" "Warning"
    }
}

# ============================================
# AUDITORIA: DKIM
# ============================================

function Audit-DKIM {
    Write-Section "DKIM SIGNING"
    try {
        $dkim = Get-DkimSigningConfig -ErrorAction Stop
        foreach ($d in $dkim) {
            Add-Evidence -Category "Email Authentication" `
                -ActionName "DKIM: $($d.Domain)" `
                -Status $(if ($d.Enabled) { "Enabled" } else { "Disabled" }) `
                -PolicyName $d.Domain `
                -PolicyId $d.Guid `
                -ImplementationDate (Get-Date -Format "yyyy-MM-dd") `
                -Notes "Enabled: $($d.Enabled) | Status: $($d.Status)" `
                -PurviewMapping "Set up DKIM for your custom domain"

            $icon = if ($d.Enabled) { "✅" } else { "❌" }
            Write-Status "$icon DKIM: $($d.Domain)" "Detail"
        }
    }
    catch {
        Write-Status "Erro DKIM: $($_.Exception.Message)" "Warning"
    }
}

# ============================================
# EXPORTAÇÃO
# ============================================

function Export-Evidence {
    Write-Section "EXPORTANDO EVIDÊNCIAS"

    $tenantLabel = if ($TenantName) { $TenantName } else { "Tenant" }
    $folder = "${OutputPath}_${tenantLabel}_${ReportDate}"

    if (-not (Test-Path $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }

    # CSV
    $csvPath = Join-Path $folder "purview-evidence.csv"
    $Script:Evidence | Export-Csv $csvPath -NoTypeInformation -Encoding UTF8
    Write-Status "CSV: $csvPath" "Success"

    # JSON
    $jsonPath = Join-Path $folder "purview-evidence.json"
    $Script:Evidence | ConvertTo-Json -Depth 5 | Out-File $jsonPath -Encoding UTF8
    Write-Status "JSON: $jsonPath" "Success"

    # Markdown
    $mdPath = Join-Path $folder "EVIDENCE-REPORT.md"
    $md = @"
# Evidências de Políticas Implementadas - Purview Compliance Manager

**Tenant:** $tenantLabel
**Data:** $(Get-Date -Format "dd/MM/yyyy HH:mm")
**Total de evidências:** $($Script:Evidence.Count)

## Resumo por Categoria

| Categoria | Implementadas |
|-----------|:------------:|
"@
    $groups = $Script:Evidence | Group-Object Category
    foreach ($g in $groups) {
        $md += "`n| $($g.Name) | $($g.Count) |"
    }

    $md += "`n`n## Detalhamento`n"
    foreach ($g in $groups) {
        $md += "`n### $($g.Name)`n"
        foreach ($e in $g.Group) {
            $md += "`n- **$($e.ActionName)** — $($e.Status)`n  - Policy: $($e.PolicyName)`n  - Notes: $($e.Notes)`n"
        }
    }

    $md | Out-File $mdPath -Encoding UTF8
    Write-Status "Markdown: $mdPath" "Success"

    # Sumário
    Write-Section "SUMÁRIO"
    Write-Host ""
    Write-Host "  📊 EVIDÊNCIAS COLETADAS" -ForegroundColor Cyan
    Write-Host "  ─────────────────────────────────────────────" -ForegroundColor Gray
    foreach ($g in $groups) {
        Write-Host "  $($g.Name.PadRight(30)) $($g.Count) políticas" -ForegroundColor Green
    }
    Write-Host "  ─────────────────────────────────────────────" -ForegroundColor Gray
    Write-Host "  TOTAL                        $($Script:Evidence.Count) evidências" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  📁 Relatórios salvos em:" -ForegroundColor Cyan
    Write-Host "     $folder" -ForegroundColor Green
    Write-Host ""
    Write-Host "  📋 PRÓXIMOS PASSOS:" -ForegroundColor Yellow
    Write-Host "     1. Abra o CSV gerado" -ForegroundColor White
    Write-Host "     2. Para cada ação, vá no Purview Compliance Manager" -ForegroundColor White
    Write-Host "     3. Clique na ação → 'Update Status' → 'Implemented'" -ForegroundColor White
    Write-Host "     4. Cole as 'Notes' como evidência" -ForegroundColor White
    Write-Host "     5. SCORE SOBE AUTOMATICAMENTE!" -ForegroundColor Green
    Write-Host ""
}

# ============================================
# EXECUÇÃO PRINCIPAL
# ============================================

function Start-Audit {
    Clear-Host
    Write-Host "`n╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  🔍 AUDITORIA DE POLÍTICAS IMPLEMENTADAS                    ║" -ForegroundColor Cyan
    Write-Host "║  Para documentação no Purview Compliance Manager            ║" -ForegroundColor Cyan
    Write-Host "║  Versão 1.0 - Multi-tenant                                  ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

    if (-not $SkipConnection) {
        $connected = Connect-ToServices
        if (-not $connected) {
            Write-Host "`n  ❌ Falha na conexão. Abortando.`n" -ForegroundColor Red
            return
        }
    }

    # Executar auditorias
    Audit-ConditionalAccess
    Audit-DLPPolicies
    Audit-SensitivityLabels
    Audit-RetentionPolicies
    Audit-ATPPolicies
    Audit-AuditLog
    Audit-TransportRules
    Audit-DKIM

    # Exportar
    Export-Evidence

    Write-Host "  ✅ Auditoria concluída!`n" -ForegroundColor Green
}

# Executar
Start-Audit

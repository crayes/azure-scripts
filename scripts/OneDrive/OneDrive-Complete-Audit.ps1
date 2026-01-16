<#
.SYNOPSIS
    Auditoria COMPLETA de Segurança do OneDrive for Business
.DESCRIPTION
    Script abrangente que audita TODAS as configurações de segurança do OneDrive/SharePoint.
    Usa REST API pura (Graph API) - compatível com macOS, Windows e Linux.
    Não requer módulos adicionais como PnP.PowerShell.
.VERSION
    5.1.0 - Enhanced Edition with Error Handling and Validation Improvements
.REQUIREMENTS
    - PowerShell 7.0+
    - Conta com permissão SharePoint Admin ou Global Admin
.USAGE
    ./OneDrive-Complete-Audit.ps1 -TenantName "contoso"
.OUTPUTS
    - OneDrive-Audit-Findings_<timestamp>.csv
    - OneDrive-Audit-AllSettings_<timestamp>.csv
    - OneDrive-Complete-Audit-Report_<timestamp>.html
    - OneDrive-Audit-Findings_<timestamp>.json (opcional)
.NOTES
    A remediação deve ser feita manualmente no SharePoint Admin Center.
    Consulte REMEDIATION-CHECKLIST.md para instruções detalhadas.
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$TenantName,
    
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "$HOME/OneDrive-Audit-Report",
    
    [Parameter(Mandatory = $false)]
    [switch]$ExportJson,
    
    [Parameter(Mandatory = $false)]
    [switch]$SkipSharingAnalysis
)

# Validate TenantName input
if ([string]::IsNullOrWhiteSpace($TenantName)) {
    $TenantName = Read-Host "`nDigite o nome do tenant (ex: contoso)"
}
if ($TenantName -notmatch '^[a-zA-Z0-9\-]+$') {
    Write-Error "Nome do tenant inválido. Use apenas letras, números e hífens (ex: contoso)."
    exit 1
}
$TenantName = $TenantName -replace "\.onmicrosoft\.com$", ""
$TenantId = "$TenantName.onmicrosoft.com"

#region Variables
$script:AccessToken = $null
$script:SPOAccessToken = $null
$script:Findings = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:AllSettings = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$script:TenantAdminUrl = ""
#endregion

#region Helper Functions
function Write-Log {
    param([string]$Message, [string]$Level = "Info")
    $colors = @{ Info = "White"; Warning = "Yellow"; Error = "Red"; Success = "Green"; Section = "Cyan" }
    $ts = Get-Date -Format "HH:mm:ss"
    if ($Level -eq "Section") {
        Write-Host "`n[$ts] === $Message ===" -ForegroundColor $colors[$Level]
    } else {
        Write-Host "[$ts] [$Level] $Message" -ForegroundColor $colors[$Level]
    }
}

function Add-Setting {
    param(
        [string]$Category,
        [string]$SubCategory,
        [string]$Setting,
        [string]$Value,
        [string]$Description,
        [string]$Source = "API"
    )
    $script:AllSettings.Add([PSCustomObject]@{
        Category    = $Category
        SubCategory = $SubCategory
        Setting     = $Setting
        Value       = $Value
        Description = $Description
        Source      = $Source
    })
}

function Add-Finding {
    param(
        [string]$Category,
        [string]$Setting,
        [string]$CurrentValue,
        [string]$RecommendedValue,
        [ValidateSet("CRÍTICO", "ALTO", "MÉDIO", "BAIXO", "INFO")]
        [string]$Risk,
        [string]$Description,
        [string]$Remediation,
        [string]$Impact
    )
    $script:Findings.Add([PSCustomObject]@{
        Category         = $Category
        Setting          = $Setting
        CurrentValue     = $CurrentValue
        RecommendedValue = $RecommendedValue
        Risk             = $Risk
        Description      = $Description
        Remediation      = $Remediation
        Impact           = $Impact
    })
    
    $color = switch ($Risk) { "CRÍTICO" { "Red" } "ALTO" { "DarkYellow" } "MÉDIO" { "Yellow" } default { "Gray" } }
    $icon = switch ($Risk) { "CRÍTICO" { "🔴" } "ALTO" { "🟠" } "MÉDIO" { "🟡" } "BAIXO" { "🔵" } default { "⚪" } }
    Write-Host "  $icon [$Risk] $Setting = $CurrentValue" -ForegroundColor $color
}

function Get-DeviceCodeToken {
    param(
        [string]$TenantId,
        [string]$Resource = "https://graph.microsoft.com"
    )
    
    $clientId = "1950a258-227b-4e31-a9cf-717495945fc2"  # Azure PowerShell
    $deviceCodeUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode"
    $tokenUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $scope = "https://graph.microsoft.com/.default offline_access"
    
    try {
        $body = "client_id=$clientId&scope=$([uri]::EscapeDataString($scope))"
        $deviceCodeResponse = Invoke-RestMethod -Uri $deviceCodeUrl -Method POST -Body $body -ContentType "application/x-www-form-urlencoded"
        
        Write-Host "`n"
        Write-Host "╔═════════════════════════════════════════════════════════╗"
        Write-Host "║                   AUTENTICAÇÃO NECESSÁRIA                     ║" -ForegroundColor Yellow
        Write-Host "╠═════════════════════════════════════════════════════════╣"
        Write-Host "║  1. Abra o navegador e acesse:                                ║" -ForegroundColor White
        Write-Host "║     https://microsoft.com/devicelogin                         ║" -ForegroundColor Cyan
        Write-Host "║                                                               ║" -ForegroundColor Yellow
        Write-Host "║  2. Digite o código:                                          ║" -ForegroundColor White
        Write-Host "║     $($deviceCodeResponse.user_code.PadRight(10))                                            ║" -ForegroundColor Green
        Write-Host "║                                                               ║" -ForegroundColor Yellow
        Write-Host "║  3. Faça login com conta de SharePoint Admin ou Global Admin  ║" -ForegroundColor White
        Write-Host "╚═════════════════════════════════════════════════════════╝"
        Write-Host ""
        
        $interval = $deviceCodeResponse.interval
        $expiresIn = $deviceCodeResponse.expires_in
        $startTime = Get-Date
        
        while (((Get-Date) - $startTime).TotalSeconds -lt $expiresIn) {
            Start-Sleep -Seconds $interval
            
            try {
                $tokenBody = "grant_type=urn:ietf:params:oauth:grant-type:device_code&client_id=$clientId&device_code=$($deviceCodeResponse.device_code)"
                $tokenResponse = Invoke-RestMethod -Uri $tokenUrl -Method POST -Body $tokenBody -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
                
                Write-Log "Autenticação concluída!" -Level "Success"
                return $tokenResponse.access_token
            }
            catch {
                $errorBody = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($errorBody.error -eq "authorization_pending") {
                    Write-Host "." -NoNewline -ForegroundColor Gray
                    continue
                }
                elseif ($errorBody.error -eq "authorization_declined") {
                    throw "Autenticação negada"
                }
                elseif ($errorBody.error -eq "expired_token") {
                    throw "Código expirado"
                }
            }
        }
        throw "Timeout"
    }
    catch {
        Write-Log "Erro na autenticação: $_" -Level "Error"
        throw
    }
}

function Invoke-GraphAPI {
    param([string]$Uri, [string]$Method = "GET", [switch]$Beta, [int]$RetryCount = 0)
    
    $baseUrl = if ($Beta) { "https://graph.microsoft.com/beta" } else { "https://graph.microsoft.com/v1.0" }
    $fullUri = if ($Uri.StartsWith("http")) { $Uri } else { "$baseUrl$Uri" }
    
    $headers = @{
        "Authorization" = "Bearer $($script:AccessToken)"
        "Content-Type"  = "application/json"
        "ConsistencyLevel" = "eventual"
    }
    
    try {
        $response = Invoke-RestMethod -Uri $fullUri -Method $Method -Headers $headers -ErrorAction Stop
        return $response
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $errorMessage = $_.Exception.Message
        Write-Log "Erro na API ($statusCode): $fullUri - $errorMessage" -Level "Error"
        
        # Retry logic for temporary errors
        if ($statusCode -in 429, 503 -and $RetryCount -lt 3) {
            $waitTime = [math]::Pow(2, $RetryCount) * 5  # Exponential backoff: 5s, 10s, 20s
            Write-Log "Tentando novamente em $waitTime segundos devido a erro temporário (tentativa $($RetryCount + 1)/3)..." -Level "Warning"
            Start-Sleep -Seconds $waitTime
            return Invoke-GraphAPI -Uri $Uri -Method $Method -Beta:$Beta -RetryCount ($RetryCount + 1)
        }
        
        return $null
    }
}
#endregion

#region Audit Functions

function Get-AllSharePointSettings {
    Write-Log "Coletando configurações do SharePoint/OneDrive" -Level "Section"
    
    $settings = @{}
    
    Write-Log "Tentando endpoint v1.0/admin/sharepoint/settings..." -Level "Info"
    $v1Settings = Invoke-GraphAPI -Uri "/admin/sharepoint/settings"
    if ($v1Settings) {
        Write-Log "Endpoint v1.0 retornou dados!" -Level "Success"
        $settings["v1"] = $v1Settings
    }
    
    Write-Log "Tentando endpoint beta/admin/sharepoint/settings..." -Level "Info"
    $betaSettings = Invoke-GraphAPI -Uri "/admin/sharepoint/settings" -Beta
    if ($betaSettings) {
        Write-Log "Endpoint beta retornou dados!" -Level "Success"
        $settings["beta"] = $betaSettings
    }
    
    Write-Log "Tentando endpoint organization..." -Level "Info"
    $orgDetails = Invoke-GraphAPI -Uri "/organization"
    if ($orgDetails) {
        $settings["org"] = $orgDetails.value[0]
    }
    
    Write-Log "Tentando endpoint security defaults..." -Level "Info"
    $securityDefaults = Invoke-GraphAPI -Uri "/policies/identitySecurityDefaultsEnforcementPolicy"
    if ($securityDefaults) {
        $settings["security"] = $securityDefaults
    }
    
    Write-Log "Tentando endpoint conditional access..." -Level "Info"
    $caPolicies = Invoke-GraphAPI -Uri "/identity/conditionalAccess/policies"
    if ($caPolicies) {
        $settings["conditionalAccess"] = $caPolicies.value
    }
    
    return $settings
}

function Analyze-SharingSettings {
    param($Settings)
    
    if ($SkipSharingAnalysis) { return }
    
    Write-Log "Analisando Configurações de Compartilhamento Externo" -Level "Section"
    
    $s = $Settings["beta"] ?? $Settings["v1"]
    
    if (-not $s) {
        Write-Log "Dados de compartilhamento não disponíveis via API" -Level "Warning"
        return
    }
    
    if ($s.sharingCapability) {
        $val = $s.sharingCapability
        Add-Setting -Category "Compartilhamento" -SubCategory "Externo" -Setting "sharingCapability" -Value $val -Description "Nível de compartilhamento externo do tenant"
        
        $sharingLevels = @{
            "disabled" = @{ Risk = "INFO"; Desc = "Compartilhamento externo desabilitado" }
            "externalUserSharingOnly" = @{ Risk = "MÉDIO"; Desc = "Apenas usuários externos autenticados" }
            "externalUserAndGuestSharing" = @{ Risk = "CRÍTICO"; Desc = "Anyone links habilitados - ALTO RISCO" }
            "existingExternalUserSharingOnly" = @{ Risk = "BAIXO"; Desc = "Apenas externos já existentes" }
        }
        
        $level = $sharingLevels[$val]
        if ($level -and $level.Risk -in @("CRÍTICO", "ALTO", "MÉDIO")) {
            Add-Finding -Category "Compartilhamento" -Setting "sharingCapability" -CurrentValue $val `
                -RecommendedValue "disabled ou existingExternalUserSharingOnly" -Risk $level.Risk `
                -Description $level.Desc `
                -Remediation "SharePoint Admin > Policies > Sharing > External sharing" `
                -Impact "Links anônimos permitem acesso sem autenticação"
        }
    }
    
    if ($null -ne $s.isResharingByExternalUsersEnabled) {
        $val = $s.isResharingByExternalUsersEnabled
        Add-Setting -Category "Compartilhamento" -SubCategory "Externo" -Setting "isResharingByExternalUsersEnabled" -Value $val -Description "Externos podem recompartilhar"
        
        if ($val) {
            Add-Finding -Category "Compartilhamento" -Setting "isResharingByExternalUsersEnabled" -CurrentValue "True" `
                -RecommendedValue "False" -Risk "ALTO" `
                -Description "Usuários externos podem recompartilhar conteúdo" `
                -Remediation "SharePoint Admin > Policies > Sharing > Desmarcar 'Allow guests to share'" `
                -Impact "Dados podem ser compartilhados em cadeia"
        }
    }
    
    if ($s.sharingDomainRestrictionMode) {
        $val = $s.sharingDomainRestrictionMode
        Add-Setting -Category "Compartilhamento" -SubCategory "Domínios" -Setting "sharingDomainRestrictionMode" -Value $val -Description "Modo de restrição de domínio"
        
        if ($val -eq "none") {
            Add-Finding -Category "Compartilhamento" -Setting "sharingDomainRestrictionMode" -CurrentValue "none" `
                -RecommendedValue "allowList ou blockList" -Risk "MÉDIO" `
                -Description "Sem restrição de domínios para compartilhamento" `
                -Remediation "SharePoint Admin > Policies > Sharing > Limit by domain" `
                -Impact "Compartilhamento possível com qualquer domínio"
        }
    }
}

function Analyze-LinkSettings {
    param($Settings)
    
    Write-Log "Analisando Configurações de Links" -Level "Section"
    
    $s = $Settings["beta"] ?? $Settings["v1"]
    if (-not $s) { return }
    
    if ($s.defaultSharingLinkType) {
        $val = $s.defaultSharingLinkType
        Add-Setting -Category "Links" -SubCategory "Padrões" -Setting "defaultSharingLinkType" -Value $val -Description "Tipo padrão de link"
        
        if ($val -in @("anonymousAccess", "anyone")) {
            Add-Finding -Category "Links" -Setting "defaultSharingLinkType" -CurrentValue $val `
                -RecommendedValue "specificPeople" -Risk "CRÍTICO" `
                -Description "Links anônimos são o padrão" `
                -Remediation "SharePoint Admin > Policies > Sharing > Default link type" `
                -Impact "Usuários criarão links públicos por padrão"
        }
    }
    
    if ($s.defaultLinkPermission) {
        $val = $s.defaultLinkPermission
        Add-Setting -Category "Links" -SubCategory "Padrões" -Setting "defaultLinkPermission" -Value $val -Description "Permissão padrão de link"
        
        if ($val -eq "edit") {
            Add-Finding -Category "Links" -Setting "defaultLinkPermission" -CurrentValue "edit" `
                -RecommendedValue "view" -Risk "MÉDIO" `
                -Description "Links têm permissão de edição por padrão" `
                -Remediation "SharePoint Admin > Policies > Sharing > Default permission" `
                -Impact "Destinatários podem modificar arquivos"
        }
    }
    
    if ($null -ne $s.anonymousLinkExpirationInDays) {
        $val = $s.anonymousLinkExpirationInDays
        Add-Setting -Category "Links" -SubCategory "Expiração" -Setting "anonymousLinkExpirationInDays" -Value $val -Description "Dias para expiração"
        
        if ($val -eq 0 -or $val -gt 30) {
            Add-Finding -Category "Links" -Setting "anonymousLinkExpirationInDays" -CurrentValue $val.ToString() `
                -RecommendedValue "7-30 dias" -Risk "ALTO" `
                -Description "Links anônimos não expiram ou expiram em muito tempo" `
                -Remediation "SharePoint Admin > Policies > Sharing > Expiration" `
                -Impact "Links permanecem ativos indefinidamente"
        }
    }
}

function Analyze-SyncSettings {
    param($Settings)
    
    Write-Log "Analisando Configurações de Sincronização" -Level "Section"
    
    $s = $Settings["beta"] ?? $Settings["v1"]
    if (-not $s) { return }
    
    if ($null -ne $s.isUnmanagedSyncAppForTenantRestricted) {
        $val = $s.isUnmanagedSyncAppForTenantRestricted
        Add-Setting -Category "Sincronização" -SubCategory "Dispositivos" -Setting "isUnmanagedSyncAppForTenantRestricted" -Value $val -Description "Sync restrito"
        
        if (-not $val) {
            Add-Finding -Category "Sincronização" -Setting "isUnmanagedSyncAppForTenantRestricted" -CurrentValue "False" `
                -RecommendedValue "True" -Risk "ALTO" `
                -Description "Qualquer dispositivo pode sincronizar" `
                -Remediation "SharePoint Admin > Settings > OneDrive > Sync" `
                -Impact "Dados podem ir para dispositivos pessoais"
        }
    }
}

function Analyze-AuthSettings {
    param($Settings)
    
    Write-Log "Analisando Configurações de Autenticação" -Level "Section"
    
    $s = $Settings["beta"] ?? $Settings["v1"]
    
    if ($s -and $null -ne $s.isLegacyAuthProtocolsEnabled) {
        $val = $s.isLegacyAuthProtocolsEnabled
        Add-Setting -Category "Autenticação" -SubCategory "Protocolos" -Setting "isLegacyAuthProtocolsEnabled" -Value $val -Description "Auth legacy"
        
        if ($val) {
            Add-Finding -Category "Autenticação" -Setting "isLegacyAuthProtocolsEnabled" -CurrentValue "True" `
                -RecommendedValue "False" -Risk "CRÍTICO" `
                -Description "Protocolos legacy HABILITADOS" `
                -Remediation "SharePoint Admin > Access control > Apps without modern auth" `
                -Impact "Vulnerável a password spray - não suporta MFA"
        }
    }
    
    $security = $Settings["security"]
    if ($security) {
        $val = $security.isEnabled
        Add-Setting -Category "Autenticação" -SubCategory "Azure AD" -Setting "securityDefaultsEnabled" -Value $val -Description "Security Defaults"
        
        if (-not $val) {
            Add-Finding -Category "Autenticação" -Setting "securityDefaultsEnabled" -CurrentValue "False" `
                -RecommendedValue "True (ou CA)" -Risk "ALTO" `
                -Description "Security Defaults não habilitados" `
                -Remediation "Azure AD > Properties > Security defaults" `
                -Impact "MFA não forçado para todos"
        }
    }
    
    $ca = $Settings["conditionalAccess"]
    if ($ca -and $ca.Count -gt 0) {
        Add-Setting -Category "Autenticação" -SubCategory "Conditional Access" -Setting "conditionalAccessPolicies" -Value "$($ca.Count) políticas" -Description "Número de políticas CA"
    }
}

function Analyze-DataProtection {
    param($Settings)
    
    Write-Log "Analisando Proteção de Dados" -Level "Section"
    
    Add-Finding -Category "Proteção de Dados" -Setting "DisallowInfectedFileDownload" -CurrentValue "VERIFICAR MANUALMENTE" `
        -RecommendedValue "True" -Risk "CRÍTICO" `
        -Description "Download de arquivos infectados" `
        -Remediation "SharePoint Admin > Settings" `
        -Impact "Arquivos maliciosos podem ser baixados"
}

function Analyze-ExternalUsers {
    param($Settings)
    
    Write-Log "Analisando Controles de Usuários Externos" -Level "Section"
    
    $s = $Settings["beta"] ?? $Settings["v1"]
    if (-not $s) { return }
    
    if ($null -ne $s.externalUserExpirationRequired) {
        $val = $s.externalUserExpirationRequired
        Add-Setting -Category "Usuários Externos" -SubCategory "Expiração" -Setting "externalUserExpirationRequired" -Value $val -Description "Expiração obrigatória"
        
        if (-not $val) {
            Add-Finding -Category "Usuários Externos" -Setting "externalUserExpirationRequired" -CurrentValue "False" `
                -RecommendedValue "True" -Risk "ALTO" `
                -Description "Acesso externo não expira" `
                -Remediation "SharePoint Admin > Policies > Sharing > Guest expiration" `
                -Impact "Ex-parceiros mantêm acesso indefinido"
        }
    }
}

function Add-ManualChecks {
    Write-Log "Adicionando verificações manuais" -Level "Section"
    
    $manualChecks = @(
        @{ Category = "Compartilhamento"; Setting = "OneDriveSharingCapability"; Risk = "CRÍTICO"; Description = "Nível de compartilhamento do OneDrive"; Remediation = "SharePoint Admin > Policies > Sharing"; Impact = "Links públicos podem expor dados" }
        @{ Category = "Links"; Setting = "FileAnonymousLinkType"; Risk = "ALTO"; Description = "Permissão de links anônimos de arquivos"; Remediation = "SharePoint Admin > Policies > Sharing"; Impact = "Arquivos podem ser acessados sem autenticação" }
        @{ Category = "Links"; Setting = "FolderAnonymousLinkType"; Risk = "ALTO"; Description = "Permissão de links anônimos de pastas"; Remediation = "SharePoint Admin > Policies > Sharing"; Impact = "Pastas podem ser acessadas sem autenticação" }
        @{ Category = "Sincronização"; Setting = "AllowedDomainListForSyncClient"; Risk = "ALTO"; Description = "Domínios permitidos para sync"; Remediation = "SharePoint Admin > Settings > OneDrive > Sync"; Impact = "Sincronização pode ocorrer de domínios não autorizados" }
        @{ Category = "Usuários Externos"; Setting = "RequireAcceptingAccountMatchInvitedAccount"; Risk = "ALTO"; Description = "Exigir conta igual ao convite"; Remediation = "SharePoint Admin > Policies > Sharing"; Impact = "Usuários podem aceitar convites com contas diferentes" }
        @{ Category = "Controle de Acesso"; Setting = "ConditionalAccessPolicy"; Risk = "ALTO"; Description = "Política para dispositivos não gerenciados"; Remediation = "SharePoint Admin > Access control > Apps"; Impact = "Dispositivos não gerenciados podem acessar dados" }
        @{ Category = "Controle de Acesso"; Setting = "IPAddressAllowList"; Risk = "MÉDIO"; Description = "Restrição por IP"; Remediation = "SharePoint Admin > Access control > Network location"; Impact = "Acesso não restrito por localização de rede" }
        @{ Category = "Notificações"; Setting = "NotifyOwnersWhenItemsReshared"; Risk = "BAIXO"; Description = "Notificar recompartilhamento"; Remediation = "SharePoint Admin > Policies > Sharing"; Impact = "Proprietários podem não ser notificados de recompartilhamentos" }
        @{ Category = "Storage"; Setting = "OrphanedPersonalSitesRetentionPeriod"; Risk = "MÉDIO"; Description = "Retenção de OneDrive órfão"; Remediation = "SharePoint Admin > Settings > OneDrive > Storage"; Impact = "Dados órfãos podem permanecer por muito tempo" }
        @{ Category = "Integração"; Setting = "EnableAzureADB2BIntegration"; Risk = "BAIXO"; Description = "Integração Azure AD B2B"; Remediation = "SharePoint Admin > Policies > Sharing"; Impact = "Integração B2B pode não estar otimizada" }
    )
    
    foreach ($check in $manualChecks) {
        Add-Finding -Category $check.Category -Setting $check.Setting -CurrentValue "VERIFICAR MANUALMENTE" `
            -RecommendedValue "Ver descrição" -Risk $check.Risk `
            -Description $check.Description `
            -Remediation $check.Remediation `
            -Impact $check.Impact
    }
}
#endregion

#region Report Generation
function Export-CompleteReport {
    Write-Log "Gerando relatórios" -Level "Section"
    
    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }
    
    $findingsPath = Join-Path $OutputPath "OneDrive-Audit-Findings_$($script:Timestamp).csv"
    $script:Findings | Export-Csv -Path $findingsPath -NoTypeInformation -Encoding UTF8 -UseQuotes AsNeeded
    Write-Log "Findings: $findingsPath" -Level "Success"
    
    $settingsPath = Join-Path $OutputPath "OneDrive-Audit-AllSettings_$($script:Timestamp).csv"
    $script:AllSettings | Export-Csv -Path $settingsPath -NoTypeInformation -Encoding UTF8 -UseQuotes AsNeeded
    Write-Log "Settings: $settingsPath" -Level "Success"
    
    if ($ExportJson) {
        $jsonPath = Join-Path $OutputPath "OneDrive-Audit-Findings_$($script:Timestamp).json"
        $script:Findings | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
        Write-Log "JSON: $jsonPath" -Level "Success"
    }
    
    $htmlPath = Join-Path $OutputPath "OneDrive-Complete-Audit-Report_$($script:Timestamp).html"
    
    $criticalCount = ($script:Findings | Where-Object { $_.Risk -eq "CRÍTICO" }).Count
    $highCount = ($script:Findings | Where-Object { $_.Risk -eq "ALTO" }).Count
    $mediumCount = ($script:Findings | Where-Object { $_.Risk -eq "MÉDIO" }).Count
    $lowCount = ($script:Findings | Where-Object { $_.Risk -eq "BAIXO" }).Count
    
    $categories = $script:Findings | Group-Object -Property Category
    
    $findingsHtml = ""
    foreach ($cat in $categories) {
        $findingsHtml += "<tr class='category-header'><td colspan='6'><strong>📁 $($cat.Name)</strong> ($($cat.Count) itens)</td></tr>"
        
        foreach ($f in ($cat.Group | Sort-Object { switch ($_.Risk) { "CRÍTICO" { 1 } "ALTO" { 2 } "MÉDIO" { 3 } "BAIXO" { 4 } default { 5 } } })) {
            $bg = switch ($f.Risk) { "CRÍTICO" { "#dc3545" } "ALTO" { "#fd7e14" } "MÉDIO" { "#ffc107" } "BAIXO" { "#17a2b8" } default { "#6c757d" } }
            $txt = if ($f.Risk -in @("MÉDIO", "BAIXO")) { "#333" } else { "#fff" }
            
            $findingsHtml += "<tr><td><span class='risk-badge' style='background:$bg;color:$txt;'>$($f.Risk)</span></td><td><strong>$($f.Setting)</strong></td><td><code>$($f.CurrentValue)</code></td><td>$($f.RecommendedValue)</td><td>$($f.Description)</td><td>$($f.Remediation)</td></tr>"
        }
    }
    
    $html = @"
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Auditoria OneDrive - $TenantName</title>
    <style>
        :root { --critical: #dc3545; --high: #fd7e14; --medium: #ffc107; --low: #17a2b8; --primary: #0078d4; --dark: #1a1a2e; }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #f0f2f5; color: #333; line-height: 1.6; }
        .container { max-width: 1400px; margin: 0 auto; padding: 20px; }
        header { background: linear-gradient(135deg, var(--dark) 0%, #16213e 50%, var(--primary) 100%); color: white; padding: 40px; border-radius: 16px; margin-bottom: 30px; }
        header h1 { font-size: 2em; margin-bottom: 10px; }
        header .meta { opacity: 0.9; }
        header .meta strong { color: #4fc3f7; }
        .summary-cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 20px; margin-bottom: 30px; }
        .card { background: white; border-radius: 16px; padding: 25px; text-align: center; box-shadow: 0 4px 15px rgba(0,0,0,0.08); position: relative; overflow: hidden; }
        .card::before { content: ''; position: absolute; top: 0; left: 0; right: 0; height: 4px; }
        .card.critical::before { background: var(--critical); }
        .card.high::before { background: var(--high); }
        .card.medium::before { background: var(--medium); }
        .card.low::before { background: var(--low); }
        .card .number { font-size: 3.5em; font-weight: 700; line-height: 1; }
        .card.critical .number { color: var(--critical); }
        .card.high .number { color: var(--high); }
        .card.medium .number { color: var(--medium); }
        .card.low .number { color: var(--low); }
        .card .label { font-size: 1em; color: #666; margin-top: 8px; }
        .section { background: white; border-radius: 16px; padding: 30px; margin-bottom: 25px; box-shadow: 0 4px 15px rgba(0,0,0,0.08); }
        .section h2 { color: var(--primary); margin-bottom: 20px; padding-bottom: 15px; border-bottom: 2px solid #f0f2f5; }
        table { width: 100%; border-collapse: collapse; }
        th, td { padding: 14px 16px; text-align: left; border-bottom: 1px solid #eee; }
        th { background: #f8f9fa; font-weight: 600; color: #495057; font-size: 0.85em; text-transform: uppercase; }
        tr:hover { background: #f8f9fa; }
        tr.category-header { background: #e9ecef; }
        tr.category-header td { font-size: 0.95em; color: #495057; }
        .risk-badge { padding: 5px 14px; border-radius: 20px; font-size: 0.75em; font-weight: 700; display: inline-block; }
        code { background: #e9ecef; padding: 4px 10px; border-radius: 6px; font-size: 0.9em; }
        .remediation { background: #e3f2fd; border-left: 4px solid var(--primary); padding: 10px 14px; margin-top: 10px; font-size: 0.9em; border-radius: 0 8px 8px 0; }
        .impact { background: #fff3e0; border-left: 4px solid var(--high); padding: 8px 14px; margin-top: 8px; font-size: 0.85em; border-radius: 0 8px 8px 0; color: #e65100; }
        footer { text-align: center; padding: 30px; color: #888; }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>🔒 Auditoria de Segurança - OneDrive for Business</h1>
            <div class="meta">
                <p>Tenant: <strong>$TenantName</strong></p>
                <p>Data: <strong>$(Get-Date -Format "dd/MM/yyyy HH:mm:ss")</strong></p>
                <p>Total: <strong>$($script:Findings.Count) verificações</strong></p>
            </div>
        </header>
        
        <div class="summary-cards">
            <div class="card critical"><div class="number">$criticalCount</div><div class="label">Críticos</div></div>
            <div class="card high"><div class="number">$highCount</div><div class="label">Altos</div></div>
            <div class="card medium"><div class="number">$mediumCount</div><div class="label">Médios</div></div>
            <div class="card low"><div class="number">$lowCount</div><div class="label">Baixos</div></div>
        </div>
        
        <div class="section">
            <h2>🚨 Findings de Segurança</h2>
            <table>
                <thead><tr><th>Risco</th><th>Configuração</th><th>Atual</th><th>Recomendado</th><th>Descrição</th><th>Ação</th></tr></thead>
                <tbody>$findingsHtml</tbody>
            </table>
        </div>
        
        <div class="section">
            <h2>📌 Próximos Passos</h2>
            <ol style="margin-left: 20px; line-height: 2;">
                <li><strong>Imediato:</strong> Corrigir $criticalCount itens CRÍTICOS</li>
                <li><strong>Curto Prazo:</strong> Corrigir $highCount itens ALTOS</li>
                <li><strong>Médio Prazo:</strong> Avaliar $mediumCount itens MÉDIOS</li>
                <li><strong>Manual:</strong> Verificar itens marcados como "VERIFICAR MANUALMENTE"</li>
            </ol>
        </div>
        
        <footer>OneDrive Security Audit Script v5.1.0 - Enhanced REST API Edition</footer>
    </div>
</body>
</html>
"@

    $html | Out-File -FilePath $htmlPath -Encoding UTF8
    Write-Log "Relatório HTML: $htmlPath" -Level "Success"
    
    if ($IsMacOS) { Start-Process "open" -ArgumentList $htmlPath }
    elseif ($IsWindows) { Start-Process $htmlPath }
    
    return $htmlPath
}

function Show-FinalSummary {
    $c = ($script:Findings | Where-Object { $_.Risk -eq "CRÍTICO" }).Count
    $h = ($script:Findings | Where-Object { $_.Risk -eq "ALTO" }).Count
    $m = ($script:Findings | Where-Object { $_.Risk -eq "MÉDIO" }).Count
    $l = ($script:Findings | Where-Object { $_.Risk -eq "BAIXO" }).Count
    
    Write-Host "`n╔══════════════════════════════════════════════════════════╗"
    Write-Host "║                    RESUMO DA AUDITORIA                     ║" -ForegroundColor Cyan
    Write-Host "╠═════════════════════════════════════════════════════════==═╣"
    Write-Host "║  🔴 CRÍTICOS: $($c.ToString().PadRight(4))    🟠 ALTOS: $($h.ToString().PadRight(4))    🟡 MÉDIOS: $($m.ToString().PadRight(4))    🔵 BAIXOS: $($l.ToString().PadRight(4))    ║"
    Write-Host "╚══════════════════════════════════════════════════════════╝"
    
    if ($c -gt 0) {
        Write-Host "`n⚠️  ATENÇÃO: $c findings CRÍTICOS requerem ação IMEDIATA!" -ForegroundColor Red
    }
}
#endregion

#region Main
Clear-Host
Write-Host @"
╔════════════════════════════════════════════════════════════════╗
║     AUDITORIA DE SEGURANÇA - ONEDRIVE FOR BUSINESS             ║
║     Versão 5.1.0 - Enhanced Edition (macOS/Windows/Linux)      ║
╚════════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan

try {
    Write-Log "Tenant: $TenantName" -Level "Info"
    
    Write-Log "Iniciando autenticação" -Level "Section"
    $script:AccessToken = Get-DeviceCodeToken -TenantId $TenantId
    
    $allData = Get-AllSharePointSettings
    
    Analyze-SharingSettings -Settings $allData
    Analyze-LinkSettings -Settings $allData
    Analyze-SyncSettings -Settings $allData
    Analyze-AuthSettings -Settings $allData
    Analyze-DataProtection -Settings $allData
    Analyze-ExternalUsers -Settings $allData
    Add-ManualChecks
    
    $reportPath = Export-CompleteReport
    Show-FinalSummary
    
    Write-Log "Auditoria concluída com sucesso!" -Level "Success"
    Write-Host "Relatório aberto no navegador: $reportPath" -ForegroundColor Gray
}
catch {
    Write-Log "Erro: $_" -Level "Error"
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
}
#endregion
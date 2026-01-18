#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    Analisa todas as políticas de Conditional Access de um tenant Microsoft 365/Entra ID
.DESCRIPTION
    Este script fornece uma análise completa e detalhada de todas as políticas de 
    Conditional Access configuradas no tenant, incluindo:
    - Estado de cada política (Ativo, Desativado, Report-Only)
    - Ações (Block, MFA, Compliant Device, etc.)
    - Apps e usuários incluídos/excluídos
    - Named Locations configuradas
    - Condições de risco (Sign-in Risk, User Risk)
    - Client App Types
    - Session Controls
.PARAMETER TenantId
    O ID ou nome do tenant (ex: contoso.onmicrosoft.com)
.EXAMPLE
    ./Analyze-CA-Policies.ps1 -TenantId "contoso.onmicrosoft.com"
.EXAMPLE
    ./Analyze-CA-Policies.ps1 -TenantId "12345678-1234-1234-1234-123456789012"
.NOTES
    Requer módulo Microsoft.Graph
    Permissões necessárias: Policy.Read.All, Directory.Read.All
    
    Autor: crayes
    Versão: 1.0
    Data: Janeiro 2026
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$TenantId = "rfaasp.onmicrosoft.com"
)

Write-Host "`n=== Análise de Conditional Access Policies ===" -ForegroundColor Cyan
Write-Host "Tenant: $TenantId" -ForegroundColor Yellow
Write-Host ""

# Conectar
Write-Host "Conectando ao Microsoft Graph..." -ForegroundColor Cyan
Connect-MgGraph -Scopes "Policy.Read.All","Directory.Read.All" -TenantId $TenantId -NoWelcome

$ctx = Get-MgContext
Write-Host "Conectado: $($ctx.Account)" -ForegroundColor Green
Write-Host "Tenant ID: $($ctx.TenantId)`n" -ForegroundColor Gray

# Buscar todas as políticas
Write-Host "Buscando políticas..." -ForegroundColor Cyan
$policies = Get-MgIdentityConditionalAccessPolicy -All

Write-Host "Total de políticas: $($policies.Count)`n" -ForegroundColor White

# Buscar Named Locations para referência
Write-Host "Buscando Named Locations..." -ForegroundColor Cyan
$namedLocations = Get-MgIdentityConditionalAccessNamedLocation -All
$locationHash = @{}
foreach ($loc in $namedLocations) {
    $locationHash[$loc.Id] = $loc.DisplayName
}
Write-Host "Named Locations encontradas: $($namedLocations.Count)`n" -ForegroundColor White

# Mapeamento de App IDs conhecidos
$knownApps = @{
    "00000002-0000-0ff1-ce00-000000000000" = "Exchange Online"
    "00000003-0000-0ff1-ce00-000000000000" = "SharePoint Online"
    "00000004-0000-0ff1-ce00-000000000000" = "Skype for Business"
    "00000002-0000-0000-c000-000000000000" = "Microsoft Graph"
    "00000003-0000-0000-c000-000000000000" = "Microsoft Graph"
    "797f4846-ba00-4fd7-ba43-dac1f8f63013" = "Azure Management"
    "0000000a-0000-0000-c000-000000000000" = "Microsoft Intune"
    "d4ebce55-015a-49b5-a083-c84d1797ae8c" = "Microsoft Intune Enrollment"
    "All" = "TODOS OS APPS"
    "Office365" = "Office 365"
    "MicrosoftAdminPortals" = "Portais de Admin Microsoft"
}

# Analisar cada política
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "ANÁLISE DETALHADA DAS POLÍTICAS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$policyNum = 1
foreach ($pol in $policies) {
    # Status com cor
    $stateColor = switch ($pol.State) {
        "enabled" { "Green" }
        "disabled" { "Red" }
        "enabledForReportingButNotEnforced" { "Yellow" }
        default { "Gray" }
    }
    $stateText = switch ($pol.State) {
        "enabled" { "ATIVO" }
        "disabled" { "DESATIVADO" }
        "enabledForReportingButNotEnforced" { "REPORT-ONLY" }
        default { $pol.State }
    }
    
    Write-Host "[$policyNum] $($pol.DisplayName)" -ForegroundColor White
    Write-Host "    ID: $($pol.Id)" -ForegroundColor Gray
    Write-Host "    Estado: " -NoNewline; Write-Host $stateText -ForegroundColor $stateColor
    
    # Grant Controls - O que a política FAZ
    $grants = $pol.GrantControls.BuiltInControls
    $grantDesc = @()
    
    if ($grants -contains "block") { $grantDesc += "BLOQUEIA acesso" }
    if ($grants -contains "mfa") { $grantDesc += "Exige MFA" }
    if ($grants -contains "compliantDevice") { $grantDesc += "Exige dispositivo GERENCIADO (Intune)" }
    if ($grants -contains "domainJoinedDevice") { $grantDesc += "Exige Hybrid Azure AD Join" }
    if ($grants -contains "approvedApplication") { $grantDesc += "Exige APP APROVADO" }
    if ($grants -contains "compliantApplication") { $grantDesc += "Exige App Protection Policy" }
    if ($grants -contains "passwordChange") { $grantDesc += "Exige troca de senha" }
    
    if ($grantDesc.Count -gt 0) {
        Write-Host "    AÇÃO: $($grantDesc -join ' + ')" -ForegroundColor $(if ($grants -contains "block") { "Red" } else { "Yellow" })
        Write-Host "    Operador: $($pol.GrantControls.Operator)" -ForegroundColor Gray
    }
    
    # Session Controls
    if ($pol.SessionControls) {
        $sessionDesc = @()
        if ($pol.SessionControls.SignInFrequency) {
            $freq = $pol.SessionControls.SignInFrequency
            $sessionDesc += "Sign-in a cada $($freq.Value) $($freq.Type)"
        }
        if ($pol.SessionControls.PersistentBrowser) {
            $sessionDesc += "Persistent Browser: $($pol.SessionControls.PersistentBrowser.Mode)"
        }
        if ($pol.SessionControls.ApplicationEnforcedRestrictions.IsEnabled) {
            $sessionDesc += "App Enforced Restrictions"
        }
        if ($pol.SessionControls.CloudAppSecurity.IsEnabled) {
            $sessionDesc += "Cloud App Security"
        }
        if ($sessionDesc.Count -gt 0) {
            Write-Host "    Sessão: $($sessionDesc -join ', ')" -ForegroundColor Magenta
        }
    }
    
    # Apps
    $apps = $pol.Conditions.Applications
    $appList = @()
    foreach ($app in $apps.IncludeApplications) {
        if ($knownApps.ContainsKey($app)) {
            $appList += $knownApps[$app]
        } else {
            $appList += $app
        }
    }
    Write-Host "    Apps incluídos: $($appList -join ', ')" -ForegroundColor White
    
    if ($apps.ExcludeApplications.Count -gt 0) {
        $exAppList = @()
        foreach ($app in $apps.ExcludeApplications) {
            if ($knownApps.ContainsKey($app)) {
                $exAppList += $knownApps[$app]
            } else {
                $exAppList += $app
            }
        }
        Write-Host "    Apps excluídos: $($exAppList -join ', ')" -ForegroundColor Green
    }
    
    # Usuários
    $users = $pol.Conditions.Users
    if ($users.IncludeUsers -contains "All") {
        Write-Host "    Usuários: TODOS" -ForegroundColor Magenta
    } elseif ($users.IncludeUsers.Count -gt 0) {
        Write-Host "    Usuários incluídos: $($users.IncludeUsers -join ', ')" -ForegroundColor White
    }
    if ($users.IncludeGroups.Count -gt 0) {
        Write-Host "    Grupos incluídos: $($users.IncludeGroups -join ', ')" -ForegroundColor White
    }
    if ($users.ExcludeUsers.Count -gt 0) {
        Write-Host "    Usuários excluídos: $($users.ExcludeUsers -join ', ')" -ForegroundColor Green
    }
    if ($users.ExcludeGroups.Count -gt 0) {
        Write-Host "    Grupos excluídos: $($users.ExcludeGroups -join ', ')" -ForegroundColor Green
    }
    
    # Plataformas
    $platforms = $pol.Conditions.Platforms
    if ($platforms) {
        if ($platforms.IncludePlatforms) {
            Write-Host "    Plataformas: $($platforms.IncludePlatforms -join ', ')" -ForegroundColor White
        }
        if ($platforms.ExcludePlatforms) {
            Write-Host "    Plataformas excluídas: $($platforms.ExcludePlatforms -join ', ')" -ForegroundColor Green
        }
    }
    
    # Localizações
    $locations = $pol.Conditions.Locations
    if ($locations) {
        if ($locations.IncludeLocations) {
            $locNames = $locations.IncludeLocations | ForEach-Object {
                if ($_ -eq "All") { "TODAS" }
                elseif ($_ -eq "AllTrusted") { "Todas Confiáveis" }
                elseif ($locationHash.ContainsKey($_)) { $locationHash[$_] }
                else { $_ }
            }
            Write-Host "    Localizações incluídas: $($locNames -join ', ')" -ForegroundColor White
        }
        if ($locations.ExcludeLocations) {
            $exLocNames = $locations.ExcludeLocations | ForEach-Object {
                if ($_ -eq "AllTrusted") { "Todas Confiáveis" }
                elseif ($locationHash.ContainsKey($_)) { $locationHash[$_] }
                else { $_ }
            }
            Write-Host "    Localizações excluídas: $($exLocNames -join ', ')" -ForegroundColor Green
        }
    }
    
    # Client App Types
    $clientApps = $pol.Conditions.ClientAppTypes
    if ($clientApps -and $clientApps -notcontains "all") {
        $clientDesc = @()
        if ($clientApps -contains "browser") { $clientDesc += "Browser" }
        if ($clientApps -contains "mobileAppsAndDesktopClients") { $clientDesc += "Apps Mobile/Desktop" }
        if ($clientApps -contains "exchangeActiveSync") { $clientDesc += "Exchange ActiveSync (Legacy)" }
        if ($clientApps -contains "other") { $clientDesc += "Outros (Legacy)" }
        Write-Host "    Client Apps: $($clientDesc -join ', ')" -ForegroundColor White
    }
    
    # Risco
    if ($pol.Conditions.SignInRiskLevels.Count -gt 0) {
        Write-Host "    Sign-in Risk: $($pol.Conditions.SignInRiskLevels -join ', ')" -ForegroundColor Yellow
    }
    if ($pol.Conditions.UserRiskLevels.Count -gt 0) {
        Write-Host "    User Risk: $($pol.Conditions.UserRiskLevels -join ', ')" -ForegroundColor Yellow
    }
    
    Write-Host ""
    $policyNum++
}

# Named Locations
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "NAMED LOCATIONS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

foreach ($loc in $namedLocations) {
    Write-Host "• $($loc.DisplayName)" -ForegroundColor White
    Write-Host "  ID: $($loc.Id)" -ForegroundColor Gray
    
    $type = $loc.AdditionalProperties.'@odata.type'
    if ($type -like "*countryNamedLocation*") {
        $countries = $loc.AdditionalProperties.countriesAndRegions -join ", "
        Write-Host "  Tipo: Países ($countries)" -ForegroundColor Yellow
    }
    elseif ($type -like "*ipNamedLocation*") {
        $ranges = $loc.AdditionalProperties.ipRanges | ForEach-Object { $_.'cidrAddress' }
        Write-Host "  Tipo: IP Ranges" -ForegroundColor Yellow
        foreach ($r in $ranges) {
            Write-Host "    - $r" -ForegroundColor Gray
        }
    }
    Write-Host ""
}

# Desconectar
Write-Host "Desconectando..." -ForegroundColor Gray
Disconnect-MgGraph | Out-Null
Write-Host "Análise concluída!`n" -ForegroundColor Green

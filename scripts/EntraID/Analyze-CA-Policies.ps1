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
    - Apps e usuários incluídos/excluídos (com resolução de nomes)
    - Named Locations configuradas
    - Condições de risco (Sign-in Risk, User Risk)
    - Client App Types
    - Session Controls
    - Detecção e limpeza de referências órfãs (objetos deletados)
.PARAMETER TenantId
    O ID ou nome do tenant (ex: contoso.onmicrosoft.com)
.PARAMETER CleanOrphans
    Se especificado, remove referências órfãs das políticas
.EXAMPLE
    ./Analyze-CA-Policies.ps1 -TenantId "contoso.onmicrosoft.com"
.EXAMPLE
    ./Analyze-CA-Policies.ps1 -TenantId "contoso.onmicrosoft.com" -CleanOrphans
.NOTES
    Requer módulo Microsoft.Graph
    Permissões necessárias: Policy.Read.All, Directory.Read.All
    Para limpeza: Policy.ReadWrite.ConditionalAccess
    
    Autor: crayes
    Versão: 2.0
    Data: Janeiro 2026
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$TenantId = "rfaasp.onmicrosoft.com",
    
    [Parameter(Mandatory=$false)]
    [switch]$CleanOrphans
)

# Cache para resolução de nomes
$script:UserCache = @{}
$script:GroupCache = @{}
$script:OrphanUsers = @{}
$script:OrphanGroups = @{}

function Resolve-UserName {
    param([string]$UserId)
    
    if ([string]::IsNullOrEmpty($UserId)) { return $null }
    if ($UserId -eq "All") { return "TODOS" }
    if ($UserId -eq "GuestsOrExternalUsers") { return "Convidados/Externos" }
    if ($UserId -eq "None") { return $null }
    
    # Check cache
    if ($script:UserCache.ContainsKey($UserId)) {
        return $script:UserCache[$UserId]
    }
    
    try {
        $user = Get-MgUser -UserId $UserId -Property "DisplayName,UserPrincipalName" -ErrorAction Stop
        $displayName = "$($user.DisplayName) ($($user.UserPrincipalName))"
        $script:UserCache[$UserId] = $displayName
        return $displayName
    }
    catch {
        # Usuário não encontrado - é órfão
        $script:OrphanUsers[$UserId] = $true
        $script:UserCache[$UserId] = "⚠️ ÓRFÃO: $UserId"
        return "⚠️ ÓRFÃO: $UserId"
    }
}

function Resolve-GroupName {
    param([string]$GroupId)
    
    if ([string]::IsNullOrEmpty($GroupId)) { return $null }
    if ($GroupId -eq "All") { return "TODOS" }
    
    # Check cache
    if ($script:GroupCache.ContainsKey($GroupId)) {
        return $script:GroupCache[$GroupId]
    }
    
    try {
        $group = Get-MgGroup -GroupId $GroupId -Property "DisplayName" -ErrorAction Stop
        $displayName = "$($group.DisplayName)"
        $script:GroupCache[$GroupId] = $displayName
        return $displayName
    }
    catch {
        # Grupo não encontrado - é órfão
        $script:OrphanGroups[$GroupId] = $true
        $script:GroupCache[$GroupId] = "⚠️ ÓRFÃO: $GroupId"
        return "⚠️ ÓRFÃO: $GroupId"
    }
}

function Resolve-UserList {
    param([array]$UserIds)
    
    if ($null -eq $UserIds -or $UserIds.Count -eq 0) { return @() }
    
    $resolved = @()
    foreach ($id in $UserIds) {
        $name = Resolve-UserName -UserId $id
        if ($name) { $resolved += $name }
    }
    return $resolved
}

function Resolve-GroupList {
    param([array]$GroupIds)
    
    if ($null -eq $GroupIds -or $GroupIds.Count -eq 0) { return @() }
    
    $resolved = @()
    foreach ($id in $GroupIds) {
        $name = Resolve-GroupName -GroupId $id
        if ($name) { $resolved += $name }
    }
    return $resolved
}

function Remove-OrphansFromPolicy {
    param(
        [string]$PolicyId,
        [string]$PolicyName,
        [array]$OrphanUserIds,
        [array]$OrphanGroupIds,
        [string]$Location  # "IncludeUsers", "ExcludeUsers", "IncludeGroups", "ExcludeGroups"
    )
    
    if ($OrphanUserIds.Count -eq 0 -and $OrphanGroupIds.Count -eq 0) { return }
    
    Write-Host "    Limpando órfãos de '$PolicyName'..." -ForegroundColor Yellow
    
    # Buscar política atual
    $policy = Get-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $PolicyId
    
    $updateParams = @{
        Conditions = @{
            Users = @{}
        }
    }
    
    # Remover usuários órfãos de ExcludeUsers
    if ($OrphanUserIds.Count -gt 0 -and $Location -eq "ExcludeUsers") {
        $currentExclude = $policy.Conditions.Users.ExcludeUsers | Where-Object { $_ -notin $OrphanUserIds }
        $updateParams.Conditions.Users.ExcludeUsers = @($currentExclude)
        Write-Host "      Removendo $($OrphanUserIds.Count) usuário(s) órfão(s) de ExcludeUsers" -ForegroundColor Cyan
    }
    
    # Remover usuários órfãos de IncludeUsers
    if ($OrphanUserIds.Count -gt 0 -and $Location -eq "IncludeUsers") {
        $currentInclude = $policy.Conditions.Users.IncludeUsers | Where-Object { $_ -notin $OrphanUserIds }
        $updateParams.Conditions.Users.IncludeUsers = @($currentInclude)
        Write-Host "      Removendo $($OrphanUserIds.Count) usuário(s) órfão(s) de IncludeUsers" -ForegroundColor Cyan
    }
    
    # Remover grupos órfãos de ExcludeGroups
    if ($OrphanGroupIds.Count -gt 0 -and $Location -eq "ExcludeGroups") {
        $currentExclude = $policy.Conditions.Users.ExcludeGroups | Where-Object { $_ -notin $OrphanGroupIds }
        $updateParams.Conditions.Users.ExcludeGroups = @($currentExclude)
        Write-Host "      Removendo $($OrphanGroupIds.Count) grupo(s) órfão(s) de ExcludeGroups" -ForegroundColor Cyan
    }
    
    # Remover grupos órfãos de IncludeGroups
    if ($OrphanGroupIds.Count -gt 0 -and $Location -eq "IncludeGroups") {
        $currentInclude = $policy.Conditions.Users.IncludeGroups | Where-Object { $_ -notin $OrphanGroupIds }
        $updateParams.Conditions.Users.IncludeGroups = @($currentInclude)
        Write-Host "      Removendo $($OrphanGroupIds.Count) grupo(s) órfão(s) de IncludeGroups" -ForegroundColor Cyan
    }
    
    try {
        Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $PolicyId -BodyParameter $updateParams
        Write-Host "      ✅ Política atualizada com sucesso!" -ForegroundColor Green
    }
    catch {
        Write-Host "      ❌ Erro ao atualizar: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ========================================
# INÍCIO DO SCRIPT
# ========================================

Write-Host "`n=== Análise de Conditional Access Policies ===" -ForegroundColor Cyan
Write-Host "Tenant: $TenantId" -ForegroundColor Yellow
if ($CleanOrphans) {
    Write-Host "Modo: LIMPEZA DE ÓRFÃOS ATIVADA" -ForegroundColor Red
} else {
    Write-Host "Modo: Apenas Relatório (use -CleanOrphans para limpar)" -ForegroundColor Gray
}
Write-Host ""

# Conectar com permissões apropriadas
Write-Host "Conectando ao Microsoft Graph..." -ForegroundColor Cyan
$scopes = @("Policy.Read.All", "Directory.Read.All", "User.Read.All", "Group.Read.All")
if ($CleanOrphans) {
    $scopes += "Policy.ReadWrite.ConditionalAccess"
}
Connect-MgGraph -Scopes $scopes -TenantId $TenantId -NoWelcome

$ctx = Get-MgContext
Write-Host "Conectado: $($ctx.Account)" -ForegroundColor Green
Write-Host "Tenant ID: $($ctx.TenantId)`n" -ForegroundColor Gray

# Buscar todas as políticas
Write-Host "Buscando políticas..." -ForegroundColor Cyan
$policies = Get-MgIdentityConditionalAccessPolicy -All

Write-Host "Total de políticas: $($policies.Count)" -ForegroundColor White

# Buscar Named Locations para referência
Write-Host "Buscando Named Locations..." -ForegroundColor Cyan
$namedLocations = Get-MgIdentityConditionalAccessNamedLocation -All
$locationHash = @{}
foreach ($loc in $namedLocations) {
    $locationHash[$loc.Id] = $loc.DisplayName
}
Write-Host "Named Locations encontradas: $($namedLocations.Count)" -ForegroundColor White

Write-Host "`nResolvendo nomes de usuários e grupos..." -ForegroundColor Cyan
Write-Host "(isso pode demorar alguns segundos)`n" -ForegroundColor Gray

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

# Coletar órfãos por política para limpeza posterior
$policyOrphans = @{}

# Analisar cada política
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "ANÁLISE DETALHADA DAS POLÍTICAS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$policyNum = 1
foreach ($pol in $policies) {
    # Inicializar tracking de órfãos para esta política
    $policyOrphans[$pol.Id] = @{
        Name = $pol.DisplayName
        ExcludeUsers = @()
        IncludeUsers = @()
        ExcludeGroups = @()
        IncludeGroups = @()
    }
    
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
    
    # Usuários - COM RESOLUÇÃO DE NOMES
    $users = $pol.Conditions.Users
    
    # Usuários incluídos
    if ($users.IncludeUsers -contains "All") {
        Write-Host "    Usuários: TODOS" -ForegroundColor Magenta
    } elseif ($users.IncludeUsers.Count -gt 0) {
        $resolvedUsers = Resolve-UserList -UserIds $users.IncludeUsers
        # Track órfãos
        foreach ($uid in $users.IncludeUsers) {
            if ($script:OrphanUsers.ContainsKey($uid)) {
                $policyOrphans[$pol.Id].IncludeUsers += $uid
            }
        }
        Write-Host "    Usuários incluídos: $($resolvedUsers -join ', ')" -ForegroundColor White
    }
    
    # Grupos incluídos
    if ($users.IncludeGroups.Count -gt 0) {
        $resolvedGroups = Resolve-GroupList -GroupIds $users.IncludeGroups
        # Track órfãos
        foreach ($gid in $users.IncludeGroups) {
            if ($script:OrphanGroups.ContainsKey($gid)) {
                $policyOrphans[$pol.Id].IncludeGroups += $gid
            }
        }
        Write-Host "    Grupos incluídos: $($resolvedGroups -join ', ')" -ForegroundColor White
    }
    
    # Usuários excluídos
    if ($users.ExcludeUsers.Count -gt 0) {
        $resolvedUsers = Resolve-UserList -UserIds $users.ExcludeUsers
        # Track órfãos
        foreach ($uid in $users.ExcludeUsers) {
            if ($script:OrphanUsers.ContainsKey($uid)) {
                $policyOrphans[$pol.Id].ExcludeUsers += $uid
            }
        }
        Write-Host "    Usuários excluídos: $($resolvedUsers -join ', ')" -ForegroundColor Green
    }
    
    # Grupos excluídos
    if ($users.ExcludeGroups.Count -gt 0) {
        $resolvedGroups = Resolve-GroupList -GroupIds $users.ExcludeGroups
        # Track órfãos
        foreach ($gid in $users.ExcludeGroups) {
            if ($script:OrphanGroups.ContainsKey($gid)) {
                $policyOrphans[$pol.Id].ExcludeGroups += $gid
            }
        }
        Write-Host "    Grupos excluídos: $($resolvedGroups -join ', ')" -ForegroundColor Green
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

# ========================================
# RELATÓRIO DE ÓRFÃOS
# ========================================

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "OBJETOS ÓRFÃOS DETECTADOS" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$totalOrphanUsers = $script:OrphanUsers.Keys.Count
$totalOrphanGroups = $script:OrphanGroups.Keys.Count

if ($totalOrphanUsers -eq 0 -and $totalOrphanGroups -eq 0) {
    Write-Host "✅ Nenhum objeto órfão encontrado! Ambiente limpo." -ForegroundColor Green
} else {
    Write-Host "⚠️  Encontrados objetos órfãos (usuários/grupos deletados):" -ForegroundColor Yellow
    Write-Host ""
    
    if ($totalOrphanUsers -gt 0) {
        Write-Host "Usuários órfãos ($totalOrphanUsers):" -ForegroundColor Red
        foreach ($uid in $script:OrphanUsers.Keys) {
            Write-Host "  • $uid" -ForegroundColor Gray
        }
        Write-Host ""
    }
    
    if ($totalOrphanGroups -gt 0) {
        Write-Host "Grupos órfãos ($totalOrphanGroups):" -ForegroundColor Red
        foreach ($gid in $script:OrphanGroups.Keys) {
            Write-Host "  • $gid" -ForegroundColor Gray
        }
        Write-Host ""
    }
    
    # Mostrar quais políticas têm órfãos
    Write-Host "Políticas afetadas:" -ForegroundColor Yellow
    foreach ($polId in $policyOrphans.Keys) {
        $orphanData = $policyOrphans[$polId]
        $hasOrphans = ($orphanData.ExcludeUsers.Count + $orphanData.IncludeUsers.Count + 
                       $orphanData.ExcludeGroups.Count + $orphanData.IncludeGroups.Count) -gt 0
        
        if ($hasOrphans) {
            Write-Host "  • $($orphanData.Name)" -ForegroundColor White
            if ($orphanData.ExcludeUsers.Count -gt 0) {
                Write-Host "      - $($orphanData.ExcludeUsers.Count) usuário(s) órfão(s) em ExcludeUsers" -ForegroundColor Gray
            }
            if ($orphanData.IncludeUsers.Count -gt 0) {
                Write-Host "      - $($orphanData.IncludeUsers.Count) usuário(s) órfão(s) em IncludeUsers" -ForegroundColor Gray
            }
            if ($orphanData.ExcludeGroups.Count -gt 0) {
                Write-Host "      - $($orphanData.ExcludeGroups.Count) grupo(s) órfão(s) em ExcludeGroups" -ForegroundColor Gray
            }
            if ($orphanData.IncludeGroups.Count -gt 0) {
                Write-Host "      - $($orphanData.IncludeGroups.Count) grupo(s) órfão(s) em IncludeGroups" -ForegroundColor Gray
            }
        }
    }
    Write-Host ""
    
    # Limpar órfãos se solicitado
    if ($CleanOrphans) {
        Write-Host "========================================" -ForegroundColor Red
        Write-Host "LIMPEZA DE ÓRFÃOS" -ForegroundColor Red
        Write-Host "========================================`n" -ForegroundColor Red
        
        $confirm = Read-Host "Deseja remover TODOS os órfãos das políticas? (S/N)"
        
        if ($confirm -eq "S" -or $confirm -eq "s") {
            foreach ($polId in $policyOrphans.Keys) {
                $orphanData = $policyOrphans[$polId]
                
                # Remover usuários órfãos de ExcludeUsers
                if ($orphanData.ExcludeUsers.Count -gt 0) {
                    Remove-OrphansFromPolicy -PolicyId $polId -PolicyName $orphanData.Name `
                        -OrphanUserIds $orphanData.ExcludeUsers -OrphanGroupIds @() -Location "ExcludeUsers"
                }
                
                # Remover usuários órfãos de IncludeUsers
                if ($orphanData.IncludeUsers.Count -gt 0) {
                    Remove-OrphansFromPolicy -PolicyId $polId -PolicyName $orphanData.Name `
                        -OrphanUserIds $orphanData.IncludeUsers -OrphanGroupIds @() -Location "IncludeUsers"
                }
                
                # Remover grupos órfãos de ExcludeGroups
                if ($orphanData.ExcludeGroups.Count -gt 0) {
                    Remove-OrphansFromPolicy -PolicyId $polId -PolicyName $orphanData.Name `
                        -OrphanUserIds @() -OrphanGroupIds $orphanData.ExcludeGroups -Location "ExcludeGroups"
                }
                
                # Remover grupos órfãos de IncludeGroups
                if ($orphanData.IncludeGroups.Count -gt 0) {
                    Remove-OrphansFromPolicy -PolicyId $polId -PolicyName $orphanData.Name `
                        -OrphanUserIds @() -OrphanGroupIds $orphanData.IncludeGroups -Location "IncludeGroups"
                }
            }
            Write-Host "`n✅ Limpeza concluída!" -ForegroundColor Green
        } else {
            Write-Host "Limpeza cancelada." -ForegroundColor Yellow
        }
    } else {
        Write-Host "💡 Para limpar os órfãos, execute novamente com: -CleanOrphans" -ForegroundColor Cyan
    }
}

Write-Host ""

# Desconectar
Write-Host "Desconectando..." -ForegroundColor Gray
Disconnect-MgGraph | Out-Null
Write-Host "Análise concluída!`n" -ForegroundColor Green

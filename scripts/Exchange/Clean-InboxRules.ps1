<#
.SYNOPSIS
    Limpa regras de inbox com erros
.DESCRIPTION
    Verifica todas as mailboxes em busca de regras de inbox inválidas
    (pastas deletadas, destinatários inexistentes, etc.) e permite remover.
.AUTHOR
    M365 Security Toolkit
.VERSION
    2.1 - Janeiro 2026
    - Adicionada verificação e correção automática de módulos
.PARAMETER RemoveAll
    Remove todas sem perguntar
.PARAMETER ReportOnly
    Apenas gera relatório, não remove nada
.EXAMPLE
    ./Clean-InboxRules.ps1 -ReportOnly
    ./Clean-InboxRules.ps1 -RemoveAll
#>

#Requires -Version 5.1

param(
    [switch]$RemoveAll,
    [switch]$ReportOnly,
    [string]$ExportPath = ".\InboxRules-Errors_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
)

# ============================================
# FUNÇÕES AUXILIARES
# ============================================

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
}

function Write-Check {
    param(
        [string]$Item,
        [string]$Status,
        [string]$Level = "OK"
    )
    
    $Icon = switch ($Level) {
        "OK"      { "✅" }
        "WARNING" { "⚠️" }
        "ERROR"   { "❌" }
        "INFO"    { "ℹ️" }
        default   { "•" }
    }
    
    $Color = switch ($Level) {
        "OK"      { "Green" }
        "WARNING" { "Yellow" }
        "ERROR"   { "Red" }
        "INFO"    { "White" }
        default   { "White" }
    }
    
    Write-Host "  $Icon $Item" -ForegroundColor $Color -NoNewline
    if ($Status) {
        Write-Host " - $Status" -ForegroundColor Gray
    } else {
        Write-Host ""
    }
}

# ============================================
# VERIFICAÇÃO E CORREÇÃO DE MÓDULOS
# ============================================

function Test-AndFixModules {
    Write-Section "🔧  VERIFICAÇÃO DE MÓDULOS"
    
    $ModulesToCheck = @(
        "ExchangeOnlineManagement"
    )
    
    $ModulesFixed = $false
    
    foreach ($ModuleName in $ModulesToCheck) {
        Write-Host ""
        Write-Host "  📦 Verificando módulo: $ModuleName" -ForegroundColor Yellow
        
        # Obter todas as versões instaladas
        $InstalledVersions = Get-Module -ListAvailable -Name $ModuleName -ErrorAction SilentlyContinue | 
            Sort-Object Version -Descending
        
        if (-not $InstalledVersions) {
            # Módulo não instalado - instalar
            Write-Check "Módulo não encontrado" "Instalando..." "WARNING"
            try {
                Install-Module -Name $ModuleName -Force -AllowClobber -Scope CurrentUser -ErrorAction Stop
                Write-Check "Módulo instalado com sucesso" "" "OK"
                $ModulesFixed = $true
            }
            catch {
                Write-Check "Erro ao instalar módulo" $_.Exception.Message "ERROR"
                Write-Host ""
                Write-Host "  ⚠️ Execute manualmente: Install-Module $ModuleName -Force" -ForegroundColor Yellow
            }
        }
        elseif ($InstalledVersions.Count -gt 1) {
            # Múltiplas versões - remover antigas e manter a mais nova
            $LatestVersion = $InstalledVersions[0]
            $OldVersions = $InstalledVersions | Select-Object -Skip 1
            
            Write-Check "Versão atual" $LatestVersion.Version.ToString() "OK"
            Write-Check "Versões duplicadas encontradas" "$($OldVersions.Count) versão(ões) antiga(s)" "WARNING"
            
            foreach ($OldVersion in $OldVersions) {
                Write-Host "     Removendo versão $($OldVersion.Version)..." -ForegroundColor Gray
                try {
                    $ModulePath = $OldVersion.ModuleBase
                    if (Test-Path $ModulePath) {
                        Remove-Item -Path $ModulePath -Recurse -Force -ErrorAction Stop
                        Write-Host "     ✅ Removida: $($OldVersion.Version)" -ForegroundColor Green
                        $ModulesFixed = $true
                    }
                }
                catch {
                    Write-Host "     ❌ Erro ao remover $($OldVersion.Version): $_" -ForegroundColor Red
                }
            }
        }
        else {
            # Apenas uma versão instalada - OK
            Write-Check "Versão instalada" $InstalledVersions[0].Version.ToString() "OK"
        }
        
        # Verificar se há atualização disponível
        try {
            $OnlineVersion = Find-Module -Name $ModuleName -ErrorAction SilentlyContinue
            $CurrentVersion = (Get-Module -ListAvailable -Name $ModuleName | Sort-Object Version -Descending | Select-Object -First 1).Version
            
            if ($OnlineVersion -and $CurrentVersion -and $OnlineVersion.Version -gt $CurrentVersion) {
                Write-Check "Atualização disponível" "v$($OnlineVersion.Version) (atual: v$CurrentVersion)" "INFO"
                Write-Host "     Atualizando módulo..." -ForegroundColor Gray
                try {
                    Update-Module -Name $ModuleName -Force -ErrorAction Stop
                    Write-Check "Módulo atualizado com sucesso" "" "OK"
                    $ModulesFixed = $true
                }
                catch {
                    Write-Host "     ⚠️ Não foi possível atualizar automaticamente" -ForegroundColor Yellow
                }
            }
        }
        catch {
            # Ignorar erros ao verificar atualizações online
        }
    }
    
    # Verificar e limpar módulos Microsoft.Graph duplicados (causa conflito de MSAL)
    Write-Host ""
    Write-Host "  📦 Verificando módulos Microsoft.Graph (conflito MSAL)..." -ForegroundColor Yellow
    
    $GraphModules = Get-Module -ListAvailable -Name "Microsoft.Graph*" -ErrorAction SilentlyContinue | 
        Group-Object Name
    
    foreach ($ModuleGroup in $GraphModules) {
        $Versions = $ModuleGroup.Group | Sort-Object Version -Descending
        
        if ($Versions.Count -gt 1) {
            $LatestVersion = $Versions[0]
            $OldVersions = $Versions | Select-Object -Skip 1
            
            Write-Host "     $($ModuleGroup.Name): $($Versions.Count) versões encontradas" -ForegroundColor Gray
            
            foreach ($OldVersion in $OldVersions) {
                try {
                    $ModulePath = $OldVersion.ModuleBase
                    if (Test-Path $ModulePath) {
                        Remove-Item -Path $ModulePath -Recurse -Force -ErrorAction Stop
                        Write-Host "     ✅ Removida: $($ModuleGroup.Name) v$($OldVersion.Version)" -ForegroundColor Green
                        $ModulesFixed = $true
                    }
                }
                catch {
                    # Silenciar erros de remoção de módulos Graph
                }
            }
        }
    }
    
    # Verificar Az.Accounts duplicados (também causa conflito)
    $AzModules = Get-Module -ListAvailable -Name "Az.Accounts" -ErrorAction SilentlyContinue | 
        Sort-Object Version -Descending
    
    if ($AzModules.Count -gt 1) {
        Write-Host ""
        Write-Host "  📦 Verificando módulo Az.Accounts..." -ForegroundColor Yellow
        
        $OldAzVersions = $AzModules | Select-Object -Skip 1
        
        foreach ($OldVersion in $OldAzVersions) {
            try {
                $ModulePath = $OldVersion.ModuleBase
                if (Test-Path $ModulePath) {
                    Remove-Item -Path $ModulePath -Recurse -Force -ErrorAction Stop
                    Write-Host "     ✅ Removida: Az.Accounts v$($OldVersion.Version)" -ForegroundColor Green
                    $ModulesFixed = $true
                }
            }
            catch {
                # Silenciar erros
            }
        }
    }
    
    if ($ModulesFixed) {
        Write-Host ""
        Write-Check "Módulos corrigidos" "Reinicie o PowerShell se houver erros de carregamento" "INFO"
    }
    
    Write-Host ""
    Write-Check "Verificação de módulos concluída" "" "OK"
}

# ============================================
# INÍCIO
# ============================================

Clear-Host
Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  🧹 LIMPEZA DE REGRAS DE INBOX COM ERROS                      ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Verificar e corrigir módulos antes de conectar
Test-AndFixModules

# Verificar conexão
Write-Host ""
$Connected = Get-PSSession | Where-Object { $_.ConfigurationName -eq "Microsoft.Exchange" -and $_.State -eq "Opened" }

if (-not $Connected) {
    Write-Host "Conectando ao Exchange Online..." -ForegroundColor Yellow
    Connect-ExchangeOnline -ShowBanner:$false
}
Write-Host "✅ Conectado ao Exchange Online" -ForegroundColor Green
Write-Host ""

# ============================================
# COLETAR TODAS AS MAILBOXES
# ============================================

Write-Host "📬 Obtendo lista de mailboxes..." -ForegroundColor Cyan
$Mailboxes = Get-Mailbox -ResultSize Unlimited -RecipientTypeDetails UserMailbox
Write-Host "   Total de mailboxes: $($Mailboxes.Count)" -ForegroundColor Gray
Write-Host ""

# ============================================
# VERIFICAR REGRAS COM ERROS
# ============================================

Write-Host "🔍 Verificando regras de inbox (isso pode demorar alguns minutos)..." -ForegroundColor Cyan
Write-Host ""

$BrokenRules = @()
$ProcessedCount = 0
$TotalMailboxes = $Mailboxes.Count

foreach ($Mailbox in $Mailboxes) {
    $ProcessedCount++
    $Percent = [math]::Round(($ProcessedCount / $TotalMailboxes) * 100)
    Write-Progress -Activity "Verificando regras de inbox" -Status "$ProcessedCount de $TotalMailboxes ($Percent%)" -PercentComplete $Percent -CurrentOperation $Mailbox.UserPrincipalName
    
    try {
        $WarningMessages = @()
        $Rules = Get-InboxRule -Mailbox $Mailbox.Identity -ErrorAction SilentlyContinue -WarningAction SilentlyContinue -WarningVariable WarningMessages
        
        if ($WarningMessages.Count -gt 0) {
            foreach ($Warning in $WarningMessages) {
                if ($Warning -match '"([^"]+)"') {
                    $RuleName = $Matches[1]
                    
                    $BrokenRules += [PSCustomObject]@{
                        Mailbox = $Mailbox.UserPrincipalName
                        DisplayName = $Mailbox.DisplayName
                        RuleName = $RuleName
                        Error = $Warning.ToString()
                        Status = "Com Erro"
                    }
                }
            }
        }
    }
    catch {
        Write-Host "   ⚠️ Erro ao verificar $($Mailbox.UserPrincipalName): $_" -ForegroundColor Yellow
    }
}

Write-Progress -Activity "Verificando regras de inbox" -Completed

# ============================================
# MOSTRAR RESULTADOS
# ============================================

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  📊 RESULTADO DA VERIFICAÇÃO" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

if ($BrokenRules.Count -eq 0) {
    Write-Host "  ✅ Nenhuma regra com erro encontrada!" -ForegroundColor Green
    Write-Host ""
    exit 0
}

Write-Host "  ⚠️ Regras com erros encontradas: $($BrokenRules.Count)" -ForegroundColor Yellow
Write-Host ""

$GroupedRules = $BrokenRules | Group-Object Mailbox

foreach ($Group in $GroupedRules) {
    Write-Host "  📧 $($Group.Name)" -ForegroundColor White
    foreach ($Rule in $Group.Group) {
        Write-Host "     • $($Rule.RuleName)" -ForegroundColor Gray
    }
    Write-Host ""
}

# ============================================
# EXPORTAR RELATÓRIO
# ============================================

Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  📄 EXPORTANDO RELATÓRIO" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$BrokenRules | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Host "  ✅ Relatório salvo em: $ExportPath" -ForegroundColor Green
Write-Host ""

# ============================================
# REMOVER REGRAS
# ============================================

if ($ReportOnly) {
    Write-Host "  ℹ️ Modo ReportOnly - nenhuma regra foi removida" -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  🗑️ REMOÇÃO DE REGRAS" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

if (-not $RemoveAll) {
    Write-Host "  Deseja remover as regras com erro?" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    [1] Remover TODAS as regras listadas" -ForegroundColor White
    Write-Host "    [2] Escolher uma por uma" -ForegroundColor White
    Write-Host "    [3] Não remover nada (sair)" -ForegroundColor White
    Write-Host ""
    $Choice = Read-Host "  Escolha (1/2/3)"
} else {
    $Choice = "1"
}

switch ($Choice) {
    "1" {
        Write-Host ""
        Write-Host "  Removendo todas as regras com erro..." -ForegroundColor Yellow
        Write-Host ""
        
        $Removed = 0
        $Failed = 0
        
        foreach ($Rule in $BrokenRules) {
            try {
                Remove-InboxRule -Mailbox $Rule.Mailbox -Identity $Rule.RuleName -Confirm:$false -ErrorAction Stop
                Write-Host "    ✅ Removida: $($Rule.RuleName) ($($Rule.Mailbox))" -ForegroundColor Green
                $Removed++
            }
            catch {
                Write-Host "    ❌ Falha ao remover: $($Rule.RuleName) ($($Rule.Mailbox))" -ForegroundColor Red
                Write-Host "       Erro: $_" -ForegroundColor Gray
                $Failed++
            }
        }
        
        Write-Host ""
        Write-Host "  📊 Resultado: $Removed removidas, $Failed falhas" -ForegroundColor Cyan
    }
    "2" {
        Write-Host ""
        foreach ($Rule in $BrokenRules) {
            Write-Host "  Regra: $($Rule.RuleName)" -ForegroundColor White
            Write-Host "  Mailbox: $($Rule.Mailbox)" -ForegroundColor Gray
            $Confirm = Read-Host "  Remover? (S/N)"
            
            if ($Confirm -eq "S" -or $Confirm -eq "s") {
                try {
                    Remove-InboxRule -Mailbox $Rule.Mailbox -Identity $Rule.RuleName -Confirm:$false -ErrorAction Stop
                    Write-Host "    ✅ Removida!" -ForegroundColor Green
                }
                catch {
                    Write-Host "    ❌ Falha: $_" -ForegroundColor Red
                }
            } else {
                Write-Host "    ⏭️ Pulada" -ForegroundColor Gray
            }
            Write-Host ""
        }
    }
    "3" {
        Write-Host ""
        Write-Host "  ℹ️ Nenhuma regra foi removida" -ForegroundColor Cyan
    }
    default {
        Write-Host ""
        Write-Host "  ℹ️ Opção inválida - nenhuma regra foi removida" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  ✅ CONCLUÍDO" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "  ℹ️ Conexão mantida. Para desconectar:" -ForegroundColor Cyan
Write-Host "     Disconnect-ExchangeOnline -Confirm:`$false" -ForegroundColor Gray
Write-Host ""

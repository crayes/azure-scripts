<#
.SYNOPSIS
    Limpa regras de inbox com erros
.DESCRIPTION
    Verifica todas as mailboxes em busca de regras de inbox inválidas
    (pastas deletadas, destinatários inexistentes, etc.) e permite remover.
.AUTHOR
    M365 Security Toolkit
.VERSION
    2.0 - Janeiro 2026
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
# INÍCIO
# ============================================

Clear-Host
Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  🧹 LIMPEZA DE REGRAS DE INBOX COM ERROS                      ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Verificar conexão
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

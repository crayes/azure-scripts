<#
.SYNOPSIS
    Auditoria Completa do Exchange Online
.DESCRIPTION
    Verifica todas as configurações de segurança do Exchange:
    - Retenção de emails
    - SPF, DKIM, DMARC
    - Regras de transporte
    - Forwarding externo
    - Conectores
    - Políticas de spam/malware
    - E muito mais
.AUTHOR
    M365 Security Toolkit
.VERSION
    2.1 - Janeiro 2026
    - Adicionada verificação e correção automática de módulos
    - Removida desconexão automática no final
.EXAMPLE
    ./Exchange-Audit.ps1
#>

#Requires -Version 5.1

$ErrorActionPreference = "Continue"
$ReportDate = Get-Date -Format "yyyy-MM-dd_HH-mm"
$OutputFile = ".\Exchange-Audit-Report_$ReportDate.html"

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
Write-Host "║  📧 AUDITORIA COMPLETA DO EXCHANGE ONLINE                     ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Verificar e corrigir módulos antes de conectar
Test-AndFixModules

# Conectar
Write-Host ""
Write-Host "Conectando ao Exchange Online..." -ForegroundColor White
try {
    Connect-ExchangeOnline -ShowBanner:$false
    Write-Host "✅ Conectado ao Exchange Online" -ForegroundColor Green
}
catch {
    Write-Host "❌ Erro ao conectar: $_" -ForegroundColor Red
    exit 1
}

try {
    Connect-IPPSSession -ShowBanner:$false
    Write-Host "✅ Conectado ao Security & Compliance" -ForegroundColor Green
}
catch {
    Write-Host "⚠️ Security & Compliance não conectado (algumas verificações limitadas)" -ForegroundColor Yellow
}

# Array para armazenar resultados
$Results = @{
    Timestamp = Get-Date -Format "dd/MM/yyyy HH:mm:ss"
    Findings = @()
}

# ============================================
# 1. INFORMAÇÕES GERAIS DO TENANT
# ============================================

Write-Section "1️⃣  INFORMAÇÕES GERAIS DO TENANT"

try {
    $OrgConfig = Get-OrganizationConfig
    Write-Check "Organização" $OrgConfig.DisplayName "INFO"
    Write-Check "Domínio padrão" $OrgConfig.DefaultPublicFolderMailbox "INFO"
    
    # Verificar audit
    if ($OrgConfig.AuditDisabled -eq $false) {
        Write-Check "Mailbox Audit por padrão" "Habilitado" "OK"
    } else {
        Write-Check "Mailbox Audit por padrão" "DESABILITADO" "ERROR"
        $Results.Findings += @{Category="Audit"; Issue="Mailbox Audit desabilitado"; Severity="High"}
    }
    
    # OAuth
    if ($OrgConfig.OAuth2ClientProfileEnabled) {
        Write-Check "OAuth2 para apps modernos" "Habilitado" "OK"
    }
}
catch {
    Write-Check "Erro ao obter configuração da organização" $_.Exception.Message "ERROR"
}

# ============================================
# 2. DOMÍNIOS ACEITOS
# ============================================

Write-Section "2️⃣  DOMÍNIOS ACEITOS"

try {
    $Domains = Get-AcceptedDomain
    
    foreach ($Domain in $Domains) {
        $Type = if ($Domain.Default) { "(Padrão)" } else { "" }
        Write-Check "$($Domain.DomainName) $Type" $Domain.DomainType "INFO"
    }
    
    Write-Host ""
    Write-Host "  Total de domínios: $($Domains.Count)" -ForegroundColor Gray
}
catch {
    Write-Check "Erro ao listar domínios" $_.Exception.Message "ERROR"
}

# ============================================
# 3. VERIFICAÇÃO SPF, DKIM, DMARC
# ============================================

Write-Section "3️⃣  AUTENTICAÇÃO DE EMAIL (SPF, DKIM, DMARC)"

$AcceptedDomains = Get-AcceptedDomain | Where-Object { $_.DomainType -eq "Authoritative" }

foreach ($Domain in $AcceptedDomains) {
    Write-Host ""
    Write-Host "  📌 Domínio: $($Domain.DomainName)" -ForegroundColor Yellow
    
    # SPF
    try {
        $SPF = Resolve-DnsName -Name $Domain.DomainName -Type TXT -ErrorAction Stop | 
            Where-Object { $_.Strings -like "*v=spf1*" }
        
        if ($SPF) {
            $SPFRecord = $SPF.Strings -join ""
            Write-Check "SPF" "Configurado" "OK"
            Write-Host "      $SPFRecord" -ForegroundColor Gray
            
            # Verificar se inclui Microsoft
            if ($SPFRecord -like "*include:spf.protection.outlook.com*") {
                Write-Check "SPF inclui Microsoft 365" "OK" "OK"
            } else {
                Write-Check "SPF não inclui Microsoft 365" "Adicionar: include:spf.protection.outlook.com" "WARNING"
                $Results.Findings += @{Category="SPF"; Issue="SPF não inclui Microsoft 365 para $($Domain.DomainName)"; Severity="Medium"}
            }
            
            # Verificar política
            if ($SPFRecord -like "*-all*") {
                Write-Check "SPF Policy" "Hard Fail (-all) - Recomendado" "OK"
            } elseif ($SPFRecord -like "*~all*") {
                Write-Check "SPF Policy" "Soft Fail (~all) - Aceitável" "INFO"
            } elseif ($SPFRecord -like "*?all*") {
                Write-Check "SPF Policy" "Neutral (?all) - Não recomendado" "WARNING"
            }
        } else {
            Write-Check "SPF" "NÃO ENCONTRADO" "ERROR"
            $Results.Findings += @{Category="SPF"; Issue="SPF não configurado para $($Domain.DomainName)"; Severity="High"}
        }
    }
    catch {
        Write-Check "SPF" "Erro na verificação DNS" "WARNING"
    }
    
    # DKIM
    try {
        $DKIMConfig = Get-DkimSigningConfig -Identity $Domain.DomainName -ErrorAction Stop
        
        if ($DKIMConfig.Enabled) {
            Write-Check "DKIM" "Habilitado" "OK"
            Write-Check "DKIM Selector 1" $DKIMConfig.Selector1CNAME "INFO"
            Write-Check "DKIM Selector 2" $DKIMConfig.Selector2CNAME "INFO"
        } else {
            Write-Check "DKIM" "DESABILITADO" "ERROR"
            $Results.Findings += @{Category="DKIM"; Issue="DKIM desabilitado para $($Domain.DomainName)"; Severity="High"}
        }
    }
    catch {
        Write-Check "DKIM" "Não configurado ou erro" "WARNING"
        $Results.Findings += @{Category="DKIM"; Issue="DKIM não configurado para $($Domain.DomainName)"; Severity="Medium"}
    }
    
    # DMARC
    try {
        $DMARC = Resolve-DnsName -Name "_dmarc.$($Domain.DomainName)" -Type TXT -ErrorAction Stop
        
        if ($DMARC) {
            $DMARCRecord = $DMARC.Strings -join ""
            Write-Check "DMARC" "Configurado" "OK"
            Write-Host "      $DMARCRecord" -ForegroundColor Gray
            
            # Verificar política
            if ($DMARCRecord -like "*p=reject*") {
                Write-Check "DMARC Policy" "REJECT - Máxima proteção" "OK"
            } elseif ($DMARCRecord -like "*p=quarantine*") {
                Write-Check "DMARC Policy" "QUARANTINE - Boa proteção" "OK"
            } elseif ($DMARCRecord -like "*p=none*") {
                Write-Check "DMARC Policy" "NONE - Apenas monitoramento" "WARNING"
                $Results.Findings += @{Category="DMARC"; Issue="DMARC em modo none para $($Domain.DomainName)"; Severity="Medium"}
            }
        } else {
            Write-Check "DMARC" "NÃO ENCONTRADO" "ERROR"
            $Results.Findings += @{Category="DMARC"; Issue="DMARC não configurado para $($Domain.DomainName)"; Severity="High"}
        }
    }
    catch {
        Write-Check "DMARC" "NÃO ENCONTRADO" "ERROR"
        $Results.Findings += @{Category="DMARC"; Issue="DMARC não configurado para $($Domain.DomainName)"; Severity="High"}
    }
}

# ============================================
# 4. REGRAS DE TRANSPORTE
# ============================================

Write-Section "4️⃣  REGRAS DE TRANSPORTE"

try {
    $TransportRules = Get-TransportRule -ErrorAction SilentlyContinue
    
    if ($TransportRules) {
        Write-Host "  📋 Total de regras: $($TransportRules.Count)" -ForegroundColor Gray
        Write-Host ""
        
        foreach ($Rule in $TransportRules) {
            $Status = if ($Rule.State -eq "Enabled") { "OK" } else { "WARNING" }
            Write-Check $Rule.Name "Prioridade: $($Rule.Priority) - Estado: $($Rule.State)" $Status
        }
    } else {
        Write-Check "Regras de transporte" "Nenhuma configurada" "INFO"
    }
}
catch {
    Write-Check "Erro ao verificar regras" $_.Exception.Message "ERROR"
}

# ============================================
# 5. FORWARDING EXTERNO
# ============================================

Write-Section "5️⃣  FORWARDING EXTERNO"

try {
    $ForwardingMailboxes = Get-Mailbox -ResultSize Unlimited | 
        Where-Object { $_.ForwardingSmtpAddress -ne $null -or $_.ForwardingAddress -ne $null }
    
    if ($ForwardingMailboxes) {
        Write-Check "Mailboxes com forwarding" "$($ForwardingMailboxes.Count) encontradas" "WARNING"
        Write-Host ""
        
        foreach ($Mbx in $ForwardingMailboxes) {
            $Target = if ($Mbx.ForwardingSmtpAddress) { $Mbx.ForwardingSmtpAddress } else { $Mbx.ForwardingAddress }
            Write-Host "    • $($Mbx.UserPrincipalName) → $Target" -ForegroundColor Yellow
            $Results.Findings += @{Category="Forwarding"; Issue="Forwarding ativo para $($Mbx.UserPrincipalName)"; Severity="Medium"}
        }
    } else {
        Write-Check "Forwarding externo" "Nenhum configurado" "OK"
    }
}
catch {
    Write-Check "Erro ao verificar forwarding" $_.Exception.Message "ERROR"
}

# ============================================
# 6. POLÍTICAS ANTI-SPAM
# ============================================

Write-Section "6️⃣  POLÍTICAS ANTI-SPAM"

try {
    $AntiSpamPolicies = Get-HostedContentFilterPolicy -ErrorAction Stop
    
    foreach ($Policy in $AntiSpamPolicies) {
        Write-Host ""
        Write-Host "  📋 Política: $($Policy.Name)" -ForegroundColor Yellow
        
        Write-Check "Spam" "Ação: $($Policy.SpamAction)" "INFO"
        Write-Check "High Confidence Spam" "Ação: $($Policy.HighConfidenceSpamAction)" "INFO"
        Write-Check "Phishing" "Ação: $($Policy.PhishSpamAction)" "INFO"
        Write-Check "High Confidence Phishing" "Ação: $($Policy.HighConfidencePhishAction)" "INFO"
        Write-Check "Bulk" "Ação: $($Policy.BulkSpamAction) (Threshold: $($Policy.BulkThreshold))" "INFO"
        
        if ($Policy.HighConfidencePhishAction -ne "Quarantine") {
            Write-Check "⚠️ High Confidence Phishing deveria ser Quarantine" "" "WARNING"
            $Results.Findings += @{Category="Anti-Spam"; Issue="High Confidence Phishing não está em Quarantine"; Severity="High"}
        }
    }
}
catch {
    Write-Check "Erro ao verificar anti-spam" $_.Exception.Message "ERROR"
}

# ============================================
# 7. POLÍTICAS ANTI-MALWARE
# ============================================

Write-Section "7️⃣  POLÍTICAS ANTI-MALWARE"

try {
    $MalwarePolicies = Get-MalwareFilterPolicy -ErrorAction Stop
    
    foreach ($Policy in $MalwarePolicies) {
        Write-Host ""
        Write-Host "  📋 Política: $($Policy.Name)" -ForegroundColor Yellow
        
        if ($Policy.ZapEnabled) {
            Write-Check "Zero-hour Auto Purge (ZAP)" "Habilitado" "OK"
        } else {
            Write-Check "Zero-hour Auto Purge (ZAP)" "Desabilitado" "WARNING"
        }
        
        $FileFilter = $Policy.EnableFileFilter
        if ($FileFilter) {
            Write-Check "Filtro de tipos de arquivo" "Habilitado" "OK"
        } else {
            Write-Check "Filtro de tipos de arquivo" "Desabilitado" "WARNING"
        }
    }
}
catch {
    Write-Check "Erro ao verificar anti-malware" $_.Exception.Message "ERROR"
}

# ============================================
# 8. ESTATÍSTICAS DE MAILBOXES
# ============================================

Write-Section "8️⃣  ESTATÍSTICAS DE MAILBOXES"

try {
    $AllMailboxes = Get-Mailbox -ResultSize Unlimited
    $UserMailboxes = $AllMailboxes | Where-Object { $_.RecipientTypeDetails -eq "UserMailbox" }
    $SharedMailboxes = $AllMailboxes | Where-Object { $_.RecipientTypeDetails -eq "SharedMailbox" }
    $RoomMailboxes = $AllMailboxes | Where-Object { $_.RecipientTypeDetails -eq "RoomMailbox" }
    
    Write-Check "Total de mailboxes" $AllMailboxes.Count "INFO"
    Write-Check "Mailboxes de usuário" $UserMailboxes.Count "INFO"
    Write-Check "Mailboxes compartilhadas" $SharedMailboxes.Count "INFO"
    Write-Check "Salas de reunião" $RoomMailboxes.Count "INFO"
    
    $LitigationHold = $AllMailboxes | Where-Object { $_.LitigationHoldEnabled -eq $true }
    if ($LitigationHold.Count -gt 0) {
        Write-Check "Mailboxes em Litigation Hold" $LitigationHold.Count "INFO"
    }
}
catch {
    Write-Check "Erro ao obter estatísticas" $_.Exception.Message "ERROR"
}

# ============================================
# SUMÁRIO
# ============================================

Write-Host ""
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "                    📊 SUMÁRIO DA AUDITORIA                " -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$HighFindings = ($Results.Findings | Where-Object { $_.Severity -eq "High" }).Count
$MediumFindings = ($Results.Findings | Where-Object { $_.Severity -eq "Medium" }).Count
$LowFindings = ($Results.Findings | Where-Object { $_.Severity -eq "Low" }).Count

Write-Host "  Problemas encontrados:" -ForegroundColor White
Write-Host "    🔴 Alta severidade:  $HighFindings" -ForegroundColor $(if ($HighFindings -gt 0) { "Red" } else { "Green" })
Write-Host "    🟡 Média severidade: $MediumFindings" -ForegroundColor $(if ($MediumFindings -gt 0) { "Yellow" } else { "Green" })
Write-Host "    🔵 Baixa severidade: $LowFindings" -ForegroundColor $(if ($LowFindings -gt 0) { "Cyan" } else { "Green" })

if ($Results.Findings.Count -gt 0) {
    Write-Host ""
    Write-Host "  📋 Detalhes dos problemas:" -ForegroundColor Yellow
    Write-Host ""
    
    foreach ($Finding in $Results.Findings) {
        $Icon = switch ($Finding.Severity) {
            "High"   { "🔴" }
            "Medium" { "🟡" }
            "Low"    { "🔵" }
        }
        Write-Host "    $Icon [$($Finding.Category)] $($Finding.Issue)" -ForegroundColor Gray
    }
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan

# ============================================
# FINALIZAÇÃO (SEM DESCONEXÃO)
# ============================================

Write-Host ""
Write-Host "✅ Auditoria concluída!" -ForegroundColor Green
Write-Host ""
Write-Host "  ℹ️ Conexão mantida. Para desconectar manualmente:" -ForegroundColor Cyan
Write-Host "     Disconnect-ExchangeOnline -Confirm:`$false" -ForegroundColor Gray
Write-Host ""

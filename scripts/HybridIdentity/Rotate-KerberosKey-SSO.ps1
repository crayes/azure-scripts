<#
.SYNOPSIS
    Rotação de Chave Kerberos - Azure AD Seamless SSO
.DESCRIPTION
    Script para rotacionar a chave Kerberos da conta AZUREADSSOACC
    usada pelo Seamless Single Sign-On do Microsoft Entra Connect.
    
    Funcionalidades:
    - Verifica pré-requisitos (Azure AD Connect, módulo AD)
    - Mostra informações da conta AZUREADSSOACC
    - Verifica status do SSO no tenant
    - Executa rotação da chave com confirmação
    - Gera log de todas as operações
    
    IMPORTANTE: Execute este script no servidor Azure AD Connect
    como Administrador.
.PARAMETER SkipConfirmation
    Pula a confirmação antes de executar a rotação
.PARAMETER CheckOnly
    Apenas verifica o status, não executa rotação
.AUTHOR
    M365 Security Toolkit
.VERSION
    2.0 - Janeiro 2026
.EXAMPLE
    # Apenas verificar status (não altera nada)
    ./Rotate-KerberosKey-SSO.ps1 -CheckOnly
    
    # Executar rotação com confirmação
    ./Rotate-KerberosKey-SSO.ps1
    
    # Executar rotação sem confirmação (automação)
    ./Rotate-KerberosKey-SSO.ps1 -SkipConfirmation
#>

#Requires -RunAsAdministrator

param(
    [switch]$SkipConfirmation,
    [switch]$CheckOnly
)

$ErrorActionPreference = "Stop"

# Configuracoes
$AzureADConnectPath = "$env:ProgramFiles\Microsoft Azure Active Directory Connect"
$LogFile = "$env:TEMP\KerberosKeyRotation_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    switch ($Level) {
        "ERROR" { Write-Host $logMessage -ForegroundColor Red }
        "WARN"  { Write-Host $logMessage -ForegroundColor Yellow }
        "OK"    { Write-Host $logMessage -ForegroundColor Green }
        default { Write-Host $logMessage -ForegroundColor Cyan }
    }
    
    Add-Content -Path $LogFile -Value $logMessage -ErrorAction SilentlyContinue
}

function Get-AzureADSSOAccountInfo {
    try {
        $ssoAccount = Get-ADComputer -Identity "AZUREADSSOACC" -Properties PasswordLastSet, Created, Description -ErrorAction Stop
        $daysSince = [math]::Round((New-TimeSpan -Start $ssoAccount.PasswordLastSet -End (Get-Date)).TotalDays)
        
        return @{
            Name = $ssoAccount.Name
            PasswordLastSet = $ssoAccount.PasswordLastSet
            Created = $ssoAccount.Created
            DaysSinceRotation = $daysSince
            Description = $ssoAccount.Description
        }
    }
    catch {
        return $null
    }
}

# Banner
Write-Host ""
Write-Host "================================================================" -ForegroundColor Magenta
Write-Host "     ROTACAO DE CHAVE KERBEROS - SEAMLESS SSO                   " -ForegroundColor Magenta
Write-Host "     Microsoft Entra Connect (Azure AD Connect)                 " -ForegroundColor Magenta
Write-Host "================================================================" -ForegroundColor Magenta
Write-Host ""

# 1. Verificar pre-requisitos
Write-Log "Verificando pre-requisitos..."

# Verificar se esta no servidor Azure AD Connect
$ssoModulePath = Join-Path $AzureADConnectPath "AzureADSSO.psd1"
if (-not (Test-Path $ssoModulePath)) {
    Write-Log "Azure AD Connect nao encontrado em: $AzureADConnectPath" "ERROR"
    Write-Log "Este script deve ser executado no servidor Azure AD Connect." "ERROR"
    exit 1
}
Write-Log "Azure AD Connect encontrado." "OK"

# Verificar modulo AD
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Log "Modulo ActiveDirectory nao encontrado. Instalando..." "WARN"
    try {
        Import-Module ServerManager
        Add-WindowsFeature RSAT-AD-PowerShell
    }
    catch {
        Write-Log "Falha ao instalar modulo AD: $_" "ERROR"
        exit 1
    }
}
Import-Module ActiveDirectory -ErrorAction Stop
Write-Log "Modulo ActiveDirectory carregado." "OK"

# 2. Importar modulo SSO
Write-Log "Importando modulo AzureADSSO..."
try {
    Push-Location $AzureADConnectPath
    Import-Module .\AzureADSSO.psd1 -ErrorAction Stop
    Pop-Location
    Write-Log "Modulo AzureADSSO carregado." "OK"
}
catch {
    Pop-Location
    Write-Log "Falha ao carregar modulo SSO: $_" "ERROR"
    exit 1
}

# 3. Verificar conta AZUREADSSOACC no AD
Write-Host ""
Write-Log "Verificando conta AZUREADSSOACC no Active Directory..."
$ssoAccountInfo = Get-AzureADSSOAccountInfo

if ($ssoAccountInfo) {
    Write-Host ""
    Write-Host "  INFORMACOES DA CONTA AZUREADSSOACC" -ForegroundColor White
    Write-Host "  ---------------------------------------------------" -ForegroundColor Gray
    
    $lastRotation = $ssoAccountInfo.PasswordLastSet.ToString("dd/MM/yyyy HH:mm")
    Write-Host "  Ultima rotacao: $lastRotation" -ForegroundColor White
    
    $days = $ssoAccountInfo.DaysSinceRotation
    if ($days -gt 30) {
        Write-Host "  Dias desde ultima rotacao: $days" -ForegroundColor Yellow
    }
    else {
        Write-Host "  Dias desde ultima rotacao: $days" -ForegroundColor Green
    }
    
    $created = $ssoAccountInfo.Created.ToString("dd/MM/yyyy")
    Write-Host "  Conta criada em: $created" -ForegroundColor White
    Write-Host "  ---------------------------------------------------" -ForegroundColor Gray
    Write-Host ""
    
    if ($days -gt 30) {
        Write-Log "ATENCAO: A chave nao e rotacionada ha mais de 30 dias!" "WARN"
    }
    else {
        Write-Log "Chave dentro do periodo recomendado de 30 dias." "OK"
    }
}
else {
    Write-Log "Conta AZUREADSSOACC nao encontrada no AD local." "WARN"
    Write-Log "O Seamless SSO pode nao estar configurado nesta floresta." "WARN"
}

# 4. Autenticar no Azure AD/Entra ID
Write-Host ""
Write-Log "Iniciando autenticacao no Microsoft Entra ID..."
Write-Host "  -> Uma janela do navegador sera aberta para autenticacao." -ForegroundColor Yellow
Write-Host "  -> Use uma conta com permissao de:" -ForegroundColor Yellow
Write-Host "     - Global Administrator, ou" -ForegroundColor Gray
Write-Host "     - Hybrid Identity Administrator" -ForegroundColor Gray
Write-Host ""

try {
    New-AzureADSSOAuthenticationContext
    Write-Log "Autenticacao concluida com sucesso." "OK"
}
catch {
    Write-Log "Falha na autenticacao: $_" "ERROR"
    exit 1
}

# 5. Verificar status do SSO no tenant
Write-Host ""
Write-Log "Consultando status do Seamless SSO no tenant..."

try {
    $ssoStatus = Get-AzureADSSOStatus | ConvertFrom-Json
    
    Write-Host ""
    Write-Host "  STATUS DO SEAMLESS SSO" -ForegroundColor White
    Write-Host "  ---------------------------------------------------" -ForegroundColor Gray
    
    foreach ($forest in $ssoStatus) {
        Write-Host "  Floresta: $($forest.ForestFQDN)" -ForegroundColor White
        
        if ($forest.Enable -eq $true) {
            Write-Host "  Status: Habilitado" -ForegroundColor Green
        }
        else {
            Write-Host "  Status: Desabilitado" -ForegroundColor Red
        }
        
        if ($forest.Domains) {
            $domainList = $forest.Domains -join ", "
            Write-Host "  Dominios: $domainList" -ForegroundColor Gray
        }
        Write-Host "  ---------------------------------------------------" -ForegroundColor Gray
    }
}
catch {
    Write-Log "Falha ao obter status SSO: $_" "WARN"
}

# Se for apenas verificacao, parar aqui
if ($CheckOnly) {
    Write-Host ""
    Write-Log "Modo de verificacao concluido. Nenhuma alteracao foi feita."
    Write-Host ""
    exit 0
}

# 6. Solicitar credenciais do AD local
Write-Host ""
Write-Log "Credenciais do Active Directory local necessarias..."
Write-Host "  -> Use formato: DOMINIO\usuario" -ForegroundColor Yellow
Write-Host "  -> Conta precisa de permissao de Domain Admin ou" -ForegroundColor Yellow
Write-Host "     permissao de escrita na conta AZUREADSSOACC" -ForegroundColor Yellow
Write-Host ""

$adCreds = Get-Credential -Message "Administrador de Dominio do AD local (DOMINIO\usuario)"

if (-not $adCreds) {
    Write-Log "Credenciais nao fornecidas. Operacao cancelada." "ERROR"
    exit 1
}

# Validar formato das credenciais
if ($adCreds.UserName -notmatch "\\") {
    Write-Log "Formato incorreto! Use: DOMINIO\usuario" "ERROR"
    exit 1
}

# 7. Confirmacao
if (-not $SkipConfirmation) {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Yellow
    Write-Host "                       CONFIRMACAO                              " -ForegroundColor Yellow
    Write-Host "================================================================" -ForegroundColor Yellow
    Write-Host "  A rotacao da chave Kerberos sera executada.                   " -ForegroundColor Yellow
    Write-Host "                                                                " -ForegroundColor Yellow
    Write-Host "  IMPORTANTE:                                                   " -ForegroundColor Yellow
    Write-Host "  - NAO execute mais de uma vez por floresta                    " -ForegroundColor Yellow
    Write-Host "  - Aguarde 10-15 min para propagacao                           " -ForegroundColor Yellow
    Write-Host "  - Usuarios podem precisar fazer novo login                    " -ForegroundColor Yellow
    Write-Host "================================================================" -ForegroundColor Yellow
    Write-Host ""
    
    $confirm = Read-Host "Deseja continuar? (S/N)"
    
    if ($confirm -notmatch "^[Ss]$") {
        Write-Log "Operacao cancelada pelo usuario."
        exit 0
    }
}

# 8. Executar rotacao
Write-Host ""
Write-Log "Executando rotacao da chave Kerberos..."

try {
    Update-AzureADSSOForest -OnPremCredentials $adCreds -PreserveCustomPermissionsOnDesktopSsoAccount
    
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host "              ROTACAO CONCLUIDA COM SUCESSO!                    " -ForegroundColor Green
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host ""
    
    # Verificar nova data
    Start-Sleep -Seconds 3
    $newInfo = Get-AzureADSSOAccountInfo
    if ($newInfo) {
        $newDate = $newInfo.PasswordLastSet.ToString("dd/MM/yyyy HH:mm")
        Write-Log "Nova data da chave: $newDate" "OK"
    }
    
    Write-Host ""
    Write-Host "  PROXIMOS PASSOS:" -ForegroundColor White
    Write-Host "  ---------------------------------------------------" -ForegroundColor Gray
    Write-Host "  1. Aguarde 10-15 minutos para propagacao completa" -ForegroundColor Gray
    Write-Host "  2. Teste o SSO com um usuario em dispositivo corporativo" -ForegroundColor Gray
    Write-Host "  3. Verifique no portal Entra: Identity > Hybrid management" -ForegroundColor Gray
    Write-Host "     > Microsoft Entra Connect > Connect Sync > Seamless SSO" -ForegroundColor Gray
    Write-Host "  4. Agende proxima rotacao em 30 dias" -ForegroundColor Gray
    Write-Host ""
    Write-Log "Log salvo em: $LogFile"
}
catch {
    Write-Log "FALHA na rotacao: $_" "ERROR"
    Write-Host ""
    Write-Host "  Possiveis causas:" -ForegroundColor Yellow
    Write-Host "  - Credenciais do AD sem permissao suficiente" -ForegroundColor Gray
    Write-Host "  - Problemas de conectividade com Domain Controller" -ForegroundColor Gray
    Write-Host "  - Conta AZUREADSSOACC protegida ou movida" -ForegroundColor Gray
    Write-Host ""
    exit 1
}

Write-Host ""
Write-Log "Script finalizado."

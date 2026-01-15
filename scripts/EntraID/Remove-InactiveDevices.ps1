<#
.SYNOPSIS
    Identifica e remove dispositivos inativos no Microsoft Entra ID

.DESCRIPTION
    1. Lista dispositivos sem atividade há mais de X meses
    2. Gera relatório antes de excluir
    3. Remove dispositivos com confirmação

.PARAMETER TenantId
    ID ou domínio do tenant (opcional)

.PARAMETER MonthsInactive
    Número de meses de inatividade (padrão: 6)

.PARAMETER Delete
    Se especificado, exclui os dispositivos (requer confirmação)

.PARAMETER ExportOnly
    Apenas exporta relatório, não exclui nada

.EXAMPLE
    ./Remove-InactiveDevices.ps1 -TenantId "contoso.com"
    ./Remove-InactiveDevices.ps1 -TenantId "contoso.com" -MonthsInactive 3
    ./Remove-InactiveDevices.ps1 -TenantId "contoso.com" -Delete
#>

[CmdletBinding()]
param(
    [string]$TenantId,
    [int]$MonthsInactive = 6,
    [switch]$Delete,
    [switch]$ExportOnly
)

#Requires -Version 7.0

$ErrorActionPreference = "Stop"

#region ===== FUNÇÕES AUXILIARES =====

function Write-Header {
    param([string]$Text)
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  $($Text.PadRight(68))║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Section {
    param([string]$Text)
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host "  $Text" -ForegroundColor Yellow
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host ""
}

#endregion

#region ===== CONEXÃO =====

Write-Header "LIMPEZA DE DISPOSITIVOS INATIVOS"

# Verificar conexão
$context = Get-MgContext
if (-not $context) {
    Write-Host "[*] Conectando ao Microsoft Graph..." -ForegroundColor Yellow
    
    $scopes = @(
        "Device.Read.All",
        "Device.ReadWrite.All",
        "Directory.ReadWrite.All"
    )
    
    if ($TenantId) {
        Connect-MgGraph -TenantId $TenantId -Scopes $scopes -NoWelcome
    } else {
        Connect-MgGraph -Scopes $scopes -NoWelcome
    }
}

$context = Get-MgContext
Write-Host "[✓] Conectado ao tenant: $($context.TenantId)" -ForegroundColor Green

# Obter informações do tenant
$org = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/organization" -OutputType PSObject
$tenantName = $org.value[0].displayName
$primaryDomain = ($org.value[0].verifiedDomains | Where-Object { $_.isDefault }).name

Write-Host "[✓] Tenant: $tenantName ($primaryDomain)" -ForegroundColor Green
Write-Host "[*] Período de inatividade: $MonthsInactive meses" -ForegroundColor Cyan

#endregion

#region ===== BUSCAR DISPOSITIVOS =====

Write-Section "Buscando Dispositivos Inativos"

$cutoffDate = (Get-Date).AddMonths(-$MonthsInactive)
$cutoffDateString = $cutoffDate.ToString("yyyy-MM-ddTHH:mm:ssZ")

Write-Host "[*] Data de corte: $($cutoffDate.ToString('dd/MM/yyyy'))" -ForegroundColor Yellow
Write-Host "[*] Dispositivos sem atividade desde esta data serão listados" -ForegroundColor Gray
Write-Host ""

try {
    # Buscar todos os dispositivos
    $allDevices = @()
    $nextLink = "https://graph.microsoft.com/v1.0/devices?`$select=id,displayName,operatingSystem,operatingSystemVersion,approximateLastSignInDateTime,deviceId,registrationDateTime,trustType,accountEnabled&`$top=999"
    
    while ($nextLink) {
        $response = Invoke-MgGraphRequest -Method GET -Uri $nextLink -OutputType PSObject
        $allDevices += $response.value
        $nextLink = $response.'@odata.nextLink'
    }
    
    Write-Host "[✓] Total de dispositivos encontrados: $($allDevices.Count)" -ForegroundColor Green
    
    # Filtrar dispositivos inativos
    $inactiveDevices = @()
    
    foreach ($device in $allDevices) {
        $lastActivity = $null
        
        if ($device.approximateLastSignInDateTime) {
            $lastActivity = [DateTime]$device.approximateLastSignInDateTime
        }
        elseif ($device.registrationDateTime) {
            $lastActivity = [DateTime]$device.registrationDateTime
        }
        
        if ($lastActivity -and $lastActivity -lt $cutoffDate) {
            $daysSinceActivity = [math]::Round(((Get-Date) - $lastActivity).TotalDays)
            
            $inactiveDevices += [PSCustomObject]@{
                Id = $device.id
                DeviceId = $device.deviceId
                DisplayName = $device.displayName
                OS = $device.operatingSystem
                OSVersion = $device.operatingSystemVersion
                LastActivity = $lastActivity.ToString("dd/MM/yyyy")
                DaysInactive = $daysSinceActivity
                TrustType = $device.trustType
                Enabled = $device.accountEnabled
            }
        }
    }
    
    $inactiveDevices = $inactiveDevices | Sort-Object DaysInactive -Descending
    
    Write-Host "[✓] Dispositivos inativos (> $MonthsInactive meses): $($inactiveDevices.Count)" -ForegroundColor $(if ($inactiveDevices.Count -gt 0) { "Yellow" } else { "Green" })
}
catch {
    Write-Host "[X] Erro ao buscar dispositivos: $_" -ForegroundColor Red
    exit 1
}

#endregion

#region ===== EXIBIR RESULTADOS =====

if ($inactiveDevices.Count -eq 0) {
    Write-Host ""
    Write-Host "[✓] Nenhum dispositivo inativo encontrado!" -ForegroundColor Green
    Write-Host ""
    exit 0
}

Write-Section "Dispositivos Inativos Encontrados"

# Agrupar por SO
$byOS = $inactiveDevices | Group-Object OS | Sort-Object Count -Descending

Write-Host "  📊 Resumo por Sistema Operacional:" -ForegroundColor Cyan
Write-Host ""
foreach ($os in $byOS) {
    Write-Host "     $($os.Name): $($os.Count) dispositivo(s)" -ForegroundColor Gray
}
Write-Host ""

# Mostrar tabela dos 20 mais antigos
Write-Host "  📋 Top 20 dispositivos mais antigos:" -ForegroundColor Cyan
Write-Host ""
Write-Host "  ┌────────────────────────────┬────────────┬──────────────┬───────────────┐" -ForegroundColor Gray
Write-Host "  │ Nome                       │ SO         │ Última Ativ. │ Dias Inativo  │" -ForegroundColor Gray
Write-Host "  ├────────────────────────────┼────────────┼──────────────┼───────────────┤" -ForegroundColor Gray

$top20 = $inactiveDevices | Select-Object -First 20
foreach ($device in $top20) {
    $name = $device.DisplayName
    if ($name.Length -gt 26) { $name = $name.Substring(0, 23) + "..." }
    $name = $name.PadRight(26)
    
    $os = $device.OS
    if ($os.Length -gt 10) { $os = $os.Substring(0, 7) + "..." }
    $os = $os.PadRight(10)
    
    $lastAct = $device.LastActivity.PadRight(12)
    $days = $device.DaysInactive.ToString().PadLeft(11)
    
    $color = if ($device.DaysInactive -gt 365) { "Red" } elseif ($device.DaysInactive -gt 180) { "Yellow" } else { "White" }
    
    Write-Host "  │ $name │ $os │ $lastAct │ $days   │" -ForegroundColor $color
}
Write-Host "  └────────────────────────────┴────────────┴──────────────┴───────────────┘" -ForegroundColor Gray

if ($inactiveDevices.Count -gt 20) {
    Write-Host ""
    Write-Host "  ... e mais $($inactiveDevices.Count - 20) dispositivo(s)" -ForegroundColor Gray
}

#endregion

#region ===== EXPORTAR RELATÓRIO =====

Write-Section "Exportando Relatório"

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$csvPath = "./InactiveDevices-$primaryDomain-$timestamp.csv"
$htmlPath = "./InactiveDevices-$primaryDomain-$timestamp.html"

# Exportar CSV
$inactiveDevices | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Host "[✓] CSV exportado: $csvPath" -ForegroundColor Green

# Gerar HTML
$htmlContent = @"
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <title>Dispositivos Inativos - $tenantName</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: 'Segoe UI', Tahoma, sans-serif; background: #f5f5f5; padding: 20px; }
        .container { max-width: 1400px; margin: 0 auto; }
        .header { background: linear-gradient(135deg, #d32f2f, #c62828); color: white; padding: 30px; border-radius: 10px; margin-bottom: 20px; }
        .header h1 { font-size: 24px; }
        .summary { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 15px; margin-bottom: 20px; }
        .card { background: white; padding: 20px; border-radius: 10px; box-shadow: 0 2px 5px rgba(0,0,0,0.1); text-align: center; }
        .card .number { font-size: 36px; font-weight: bold; color: #d32f2f; }
        .card .label { color: #666; }
        table { width: 100%; border-collapse: collapse; background: white; border-radius: 10px; overflow: hidden; box-shadow: 0 2px 5px rgba(0,0,0,0.1); }
        th { background: #333; color: white; padding: 15px; text-align: left; }
        td { padding: 12px 15px; border-bottom: 1px solid #eee; }
        tr:hover { background: #f5f5f5; }
        .danger { color: #d32f2f; font-weight: bold; }
        .warning { color: #f57c00; }
        .footer { text-align: center; padding: 20px; color: #666; font-size: 12px; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🗑️ Dispositivos Inativos - $tenantName</h1>
            <p>Relatório gerado em $(Get-Date -Format "dd/MM/yyyy HH:mm") | Critério: > $MonthsInactive meses sem atividade</p>
        </div>
        
        <div class="summary">
            <div class="card">
                <div class="number">$($inactiveDevices.Count)</div>
                <div class="label">Total Inativos</div>
            </div>
            <div class="card">
                <div class="number">$(($inactiveDevices | Where-Object { $_.DaysInactive -gt 365 }).Count)</div>
                <div class="label">> 1 Ano</div>
            </div>
            <div class="card">
                <div class="number">$(($inactiveDevices | Where-Object { $_.OS -eq "Windows" }).Count)</div>
                <div class="label">Windows</div>
            </div>
            <div class="card">
                <div class="number">$(($inactiveDevices | Where-Object { $_.OS -like "*iOS*" -or $_.OS -like "*Android*" }).Count)</div>
                <div class="label">Mobile</div>
            </div>
        </div>
        
        <table>
            <tr>
                <th>Nome</th>
                <th>SO</th>
                <th>Versão</th>
                <th>Última Atividade</th>
                <th>Dias Inativo</th>
                <th>Tipo</th>
            </tr>
"@

foreach ($device in $inactiveDevices) {
    $rowClass = if ($device.DaysInactive -gt 365) { "danger" } elseif ($device.DaysInactive -gt 180) { "warning" } else { "" }
    $htmlContent += @"
            <tr>
                <td>$($device.DisplayName)</td>
                <td>$($device.OS)</td>
                <td>$($device.OSVersion)</td>
                <td>$($device.LastActivity)</td>
                <td class="$rowClass">$($device.DaysInactive) dias</td>
                <td>$($device.TrustType)</td>
            </tr>
"@
}

$htmlContent += @"
        </table>
        
        <div class="footer">
            Relatório de dispositivos inativos | $tenantName | $(Get-Date -Format "dd/MM/yyyy HH:mm:ss")
        </div>
    </div>
</body>
</html>
"@

$htmlContent | Out-File -FilePath $htmlPath -Encoding UTF8
Write-Host "[✓] HTML exportado: $htmlPath" -ForegroundColor Green

#endregion

#region ===== DELETAR DISPOSITIVOS =====

if ($ExportOnly) {
    Write-Host ""
    Write-Host "[✓] Modo somente exportação - nenhum dispositivo foi removido" -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

if ($Delete) {
    Write-Section "Remoção de Dispositivos"
    
    Write-Host "  ⚠️  ATENÇÃO: Você está prestes a REMOVER $($inactiveDevices.Count) dispositivos!" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Esta ação é IRREVERSÍVEL!" -ForegroundColor Red
    Write-Host ""
    
    Write-Host "  Para confirmar, digite 'REMOVER' (em maiúsculas): " -NoNewline -ForegroundColor Yellow
    $confirmation = Read-Host
    
    if ($confirmation -ne "REMOVER") {
        Write-Host ""
        Write-Host "[!] Operação cancelada pelo usuário" -ForegroundColor Yellow
        Write-Host ""
        exit 0
    }
    
    Write-Host ""
    Write-Host "[*] Iniciando remoção..." -ForegroundColor Yellow
    Write-Host ""
    
    $removed = 0
    $failed = 0
    $errors = @()
    
    foreach ($device in $inactiveDevices) {
        try {
            Write-Host "  Removendo: $($device.DisplayName)..." -NoNewline -ForegroundColor Gray
            
            Invoke-MgGraphRequest -Method DELETE `
                -Uri "https://graph.microsoft.com/v1.0/devices/$($device.Id)" | Out-Null
            
            Write-Host " ✓" -ForegroundColor Green
            $removed++
        }
        catch {
            Write-Host " ✗" -ForegroundColor Red
            $failed++
            $errors += @{
                Device = $device.DisplayName
                Error = $_.Exception.Message
            }
        }
        
        Start-Sleep -Milliseconds 100
    }
    
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "  REMOÇÃO CONCLUÍDA" -ForegroundColor Green
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host ""
    Write-Host "  ✅ Removidos com sucesso: $removed" -ForegroundColor Green
    if ($failed -gt 0) {
        Write-Host "  ❌ Falhas: $failed" -ForegroundColor Red
    }
    Write-Host ""
    
    if ($errors.Count -gt 0) {
        Write-Host "  Erros encontrados:" -ForegroundColor Yellow
        foreach ($err in $errors) {
            Write-Host "    • $($err.Device): $($err.Error)" -ForegroundColor Gray
        }
        Write-Host ""
    }
}
else {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  PRÓXIMOS PASSOS" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  📄 Revise os relatórios gerados:" -ForegroundColor White
    Write-Host "     • $csvPath" -ForegroundColor Gray
    Write-Host "     • $htmlPath" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  🗑️  Para remover os dispositivos, execute novamente com -Delete:" -ForegroundColor White
    Write-Host "     ./Remove-InactiveDevices.ps1 -TenantId `"$primaryDomain`" -Delete" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  ⚙️  Para alterar o período de inatividade:" -ForegroundColor White
    Write-Host "     ./Remove-InactiveDevices.ps1 -TenantId `"$primaryDomain`" -MonthsInactive 12" -ForegroundColor Yellow
    Write-Host ""
}

#endregion

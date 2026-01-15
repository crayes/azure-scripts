<#
.SYNOPSIS
    Runbook para remover dispositivos inativos no Microsoft Entra ID
    
.DESCRIPTION
    Versão para Azure Automation com Managed Identity
    Remove dispositivos sem atividade há mais de X meses
    
    Configuração:
    1. Criar Automation Account no Azure
    2. Habilitar System Managed Identity
    3. Atribuir permissões no Graph API:
       - Device.Read.All
       - Device.ReadWrite.All
       - Directory.ReadWrite.All
    4. Importar módulo Microsoft.Graph
    5. Agendar execução semanal/mensal
    
.PARAMETER MonthsInactive
    Número de meses de inatividade (padrão: 6)
    
.PARAMETER DeleteDevices
    Se $true, remove os dispositivos. Se $false, apenas relatório.
    
.EXAMPLE
    # Apenas relatório
    ./Remove-InactiveDevices-AzureAutomation.ps1 -MonthsInactive 6 -DeleteDevices $false
    
    # Remover dispositivos
    ./Remove-InactiveDevices-AzureAutomation.ps1 -MonthsInactive 6 -DeleteDevices $true
#>

param(
    [int]$MonthsInactive = 6,
    [bool]$DeleteDevices = $false,
    [bool]$SendEmail = $false,
    [string]$EmailTo = ""
)

# Conectar usando Managed Identity
Write-Output "🔐 Conectando ao Microsoft Graph com Managed Identity..."

try {
    Connect-MgGraph -Identity -NoWelcome
    Write-Output "✅ Conectado com sucesso!"
}
catch {
    Write-Error "❌ Falha ao conectar: $_"
    throw
}

# Obter informações do tenant
$org = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/organization" -OutputType PSObject
$tenantName = $org.value[0].displayName
$primaryDomain = ($org.value[0].verifiedDomains | Where-Object { $_.isDefault }).name

Write-Output "📍 Tenant: $tenantName ($primaryDomain)"
Write-Output "📅 Período de inatividade: $MonthsInactive meses"
Write-Output "🗑️ Modo delete: $DeleteDevices"
Write-Output ""

# Calcular data de corte
$cutoffDate = (Get-Date).AddMonths(-$MonthsInactive)
Write-Output "📆 Data de corte: $($cutoffDate.ToString('dd/MM/yyyy'))"
Write-Output ""

# Buscar todos os dispositivos
Write-Output "🔍 Buscando dispositivos..."

$allDevices = @()
$nextLink = "https://graph.microsoft.com/v1.0/devices?`$select=id,displayName,operatingSystem,operatingSystemVersion,approximateLastSignInDateTime,deviceId,registrationDateTime,trustType,accountEnabled&`$top=999"

while ($nextLink) {
    $response = Invoke-MgGraphRequest -Method GET -Uri $nextLink -OutputType PSObject
    $allDevices += $response.value
    $nextLink = $response.'@odata.nextLink'
}

Write-Output "📊 Total de dispositivos: $($allDevices.Count)"

# Filtrar inativos
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
            DisplayName = $device.displayName
            OS = $device.operatingSystem
            LastActivity = $lastActivity.ToString("dd/MM/yyyy")
            DaysInactive = $daysSinceActivity
            TrustType = $device.trustType
        }
    }
}

$inactiveDevices = $inactiveDevices | Sort-Object DaysInactive -Descending

Write-Output "⚠️ Dispositivos inativos (> $MonthsInactive meses): $($inactiveDevices.Count)"
Write-Output ""

# Resumo por SO
$byOS = $inactiveDevices | Group-Object OS | Sort-Object Count -Descending
Write-Output "📊 Resumo por SO:"
foreach ($os in $byOS) {
    Write-Output "   - $($os.Name): $($os.Count)"
}
Write-Output ""

# Se não há dispositivos inativos
if ($inactiveDevices.Count -eq 0) {
    Write-Output "✅ Nenhum dispositivo inativo encontrado!"
    Disconnect-MgGraph | Out-Null
    return
}

# Mostrar top 20
Write-Output "📋 Top 20 mais antigos:"
$top20 = $inactiveDevices | Select-Object -First 20
foreach ($device in $top20) {
    Write-Output "   - $($device.DisplayName) | $($device.OS) | $($device.LastActivity) | $($device.DaysInactive) dias"
}
Write-Output ""

# Deletar se habilitado
if ($DeleteDevices) {
    Write-Output "🗑️ INICIANDO REMOÇÃO DE $($inactiveDevices.Count) DISPOSITIVOS..."
    Write-Output ""
    
    $removed = 0
    $failed = 0
    $errors = @()
    
    foreach ($device in $inactiveDevices) {
        try {
            Invoke-MgGraphRequest -Method DELETE `
                -Uri "https://graph.microsoft.com/v1.0/devices/$($device.Id)" | Out-Null
            
            Write-Output "   ✅ Removido: $($device.DisplayName)"
            $removed++
        }
        catch {
            Write-Output "   ❌ Falha: $($device.DisplayName) - $_"
            $failed++
            $errors += $device.DisplayName
        }
        
        Start-Sleep -Milliseconds 100
    }
    
    Write-Output ""
    Write-Output "═══════════════════════════════════════════════════"
    Write-Output "📊 RESULTADO DA LIMPEZA"
    Write-Output "═══════════════════════════════════════════════════"
    Write-Output "✅ Removidos: $removed"
    Write-Output "❌ Falhas: $failed"
    Write-Output "═══════════════════════════════════════════════════"
}
else {
    Write-Output "ℹ️ Modo somente relatório (DeleteDevices = false)"
    Write-Output "   Para remover, execute com -DeleteDevices `$true"
}

# Desconectar
Disconnect-MgGraph | Out-Null

Write-Output ""
Write-Output "✅ Execução concluída em $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')"

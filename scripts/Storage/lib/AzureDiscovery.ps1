# ============================================================================
# AzureDiscovery.ps1 - Descoberta de Storage Accounts e Containers
# ============================================================================

function Get-TargetStorageAccounts {
    Write-Log "Buscando Storage Accounts..." "SECTION"
    $cfg = $global:ImmAuditCfg
    $params = @{}
    if ($cfg.ResourceGroupName) {
        $params['ResourceGroupName'] = $cfg.ResourceGroupName
        Write-Log "Filtro Resource Group: $($cfg.ResourceGroupName)" "INFO"
    }
    try {
        $accounts = Get-AzStorageAccount @params
        if ($cfg.StorageAccountName) {
            $accounts = $accounts | Where-Object { $_.StorageAccountName -eq $cfg.StorageAccountName }
            Write-Log "Filtro Storage Account: $($cfg.StorageAccountName)" "INFO"
        }
        $accounts = $accounts | Where-Object { $_.Kind -in @('StorageV2','BlobStorage','BlockBlobStorage') }
        Write-Log "Encontradas $($accounts.Count) Storage Account(s) compatíveis" "INFO"
        return $accounts
    }
    catch {
        Add-ErrorDetail "Get-TargetStorageAccounts" $_.Exception.Message
        return @()
    }
}

function Get-ContainerImmutabilityInfo {
    param(
        [string]$AccountName,
        [string]$AccountResourceGroup,
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.IStorageContext]$StorageContext
    )
    $cfg = $global:ImmAuditCfg
    $stats = $global:ImmAuditStats
    $containersToProcess = @()
    try {
        $armContainers = Get-AzRmStorageContainer -ResourceGroupName $AccountResourceGroup -StorageAccountName $AccountName
        if ($cfg.ContainerName) {
            $armContainers = $armContainers | Where-Object { $_.Name -eq $cfg.ContainerName }
        }
        foreach ($armContainer in $armContainers) {
            $stats.ContainersScanned++
            $containerInfo = [PSCustomObject]@{
                Name                    = $armContainer.Name
                HasImmutabilityPolicy   = $armContainer.HasImmutabilityPolicy
                HasLegalHold            = $armContainer.HasLegalHold
                ImmutabilityPolicyState = $null
                RetentionDays           = $null
                VersionLevelWorm        = $false
                LegalHoldTags           = @()
            }

            if ($armContainer.ImmutableStorageWithVersioning) {
                $containerInfo.VersionLevelWorm = $true
                Write-Log "  Container '$($armContainer.Name)': Version-level WORM habilitado" "INFO"
            }

            if ($armContainer.HasImmutabilityPolicy) {
                $stats.ContainersWithPolicy++
                try {
                    $policy = Get-AzRmStorageContainerImmutabilityPolicy `
                        -ResourceGroupName $AccountResourceGroup `
                        -StorageAccountName $AccountName `
                        -ContainerName $armContainer.Name
                    $containerInfo.ImmutabilityPolicyState = $policy.State
                    $containerInfo.RetentionDays = $policy.ImmutabilityPeriodSinceCreationInDays
                    Write-Log "  Container '$($armContainer.Name)': Política=$($policy.State), Retenção=$($policy.ImmutabilityPeriodSinceCreationInDays)d" "INFO"
                }
                catch {
                    Write-Log "  Container '$($armContainer.Name)': Erro ao obter política - $($_.Exception.Message)" "WARN"
                }
            }

            if ($armContainer.HasLegalHold) {
                $containerInfo.LegalHoldTags = $armContainer.LegalHold.Tags | ForEach-Object { $_.Tag }
                Write-Log "  Container '$($armContainer.Name)': Legal Hold ativo (Tags: $($containerInfo.LegalHoldTags -join ', '))" "WARN"
            }

            $global:ImmAuditContainerResults.Add($containerInfo)
            $containersToProcess += $armContainer.Name
        }
    }
    catch {
        Add-ErrorDetail "Get-ContainerImmutabilityInfo($AccountName)" $_.Exception.Message
    }
    return $containersToProcess
}

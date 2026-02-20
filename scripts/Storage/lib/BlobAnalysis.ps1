# ============================================================================
# BlobAnalysis.ps1 - Análise de imutabilidade e ações em blobs
# ============================================================================
#
# CORREÇÕES APLICADAS:
# 1. VersionId capturado e propagado no pipeline inteiro
# 2. IsCurrentVersion rastreado
# 3. Invoke-BlobAction passa -VersionId para Remove-AzStorageBlob
# 4. Remoção de política trata Locked e Unlocked (ambos expirados)
# 5. ShouldProcess removido — controle via $global:ImmAuditCfg
# ============================================================================

function Test-BlobImmutabilityExpired {
    param(
        [Microsoft.WindowsAzure.Commands.Common.Storage.ResourceModel.AzureStorageBlob]$Blob,
        [string]$AccountName,
        [string]$ContainerNameLocal
    )

    $cfg = $global:ImmAuditCfg
    $stats = $global:ImmAuditStats

    # Extrair VersionId (null se não versionado)
    $versionId = $null
    try { $versionId = $Blob.VersionId } catch { }

    $isCurrentVersion = $null
    try { $isCurrentVersion = $Blob.IsCurrentVersion } catch { }

    $result = [PSCustomObject]@{
        StorageAccount        = $AccountName
        Container             = $ContainerNameLocal
        BlobName              = $Blob.Name
        VersionId             = $versionId
        IsCurrentVersion      = $isCurrentVersion
        BlobType              = $Blob.BlobType
        Length                = $Blob.Length
        LengthFormatted       = Format-FileSize $Blob.Length
        LastModified          = $Blob.LastModified
        AccessTier            = $Blob.AccessTier
        ImmutabilityExpiresOn = $null
        ImmutabilityMode      = $null
        HasLegalHold          = $false
        Status                = "Unknown"
        DaysExpired           = 0
        Eligible              = $false
        Action                = "None"
    }

    try {
        $immutabilityPolicy = $Blob.BlobProperties.ImmutabilityPolicy

        if ($null -ne $immutabilityPolicy -and $null -ne $immutabilityPolicy.ExpiresOn) {
            $result.ImmutabilityExpiresOn = $immutabilityPolicy.ExpiresOn
            $result.ImmutabilityMode = $immutabilityPolicy.PolicyMode
            $expiresOn = [DateTimeOffset]$immutabilityPolicy.ExpiresOn

            if ($expiresOn -lt $cfg.Now) {
                $daysExpired = [math]::Floor(($cfg.Now - $expiresOn).TotalDays)
                $result.DaysExpired = $daysExpired
                $result.Status = "Expired"

                if ($cfg.MaxDaysExpired -gt 0 -and $daysExpired -lt $cfg.MaxDaysExpired) {
                    $result.Eligible = $false
                    $result.Action = "SkippedMinDays"
                }
                else {
                    $result.Eligible = $true
                    $stats.BlobsWithExpiredPolicy++
                    $stats.BytesEligible += $Blob.Length
                }
            }
            else {
                $result.Status = "Active"
                $stats.BlobsWithActivePolicy++
            }
        }
        else {
            $result.Status = "NoPolicy"
        }

        if ($Blob.BlobProperties.HasLegalHold) {
            $result.HasLegalHold = $true
            $result.Eligible = $false
            $result.Action = "LegalHoldActive"
            $stats.BlobsWithLegalHold++
        }
    }
    catch {
        $result.Status = "Error"
        $result.Action = "ErrorChecking: $($_.Exception.Message)"
        Add-ErrorDetail "Test-Immutability($($Blob.Name))" $_.Exception.Message
    }

    return $result
}

function Invoke-BlobAction {
    param(
        [PSCustomObject]$BlobInfo,
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.IStorageContext]$StorageContext
    )

    $cfg = $global:ImmAuditCfg
    $stats = $global:ImmAuditStats

    if (-not $BlobInfo.Eligible) { return }

    # Legal Hold: nunca remover automaticamente
    if ($BlobInfo.HasLegalHold) {
        $BlobInfo.Action = "SkippedLegalHold"
        Write-Log "    SKIP: '$($BlobInfo.BlobName)' - Legal Hold ativo" "WARN"
        return
    }

    # Helper: label curto do VersionId para logs
    $vLabel = ""
    if ($BlobInfo.VersionId) {
        $vShort = $BlobInfo.VersionId.Substring(0, [math]::Min(16, $BlobInfo.VersionId.Length))
        $vLabel = " [v:$vShort]"
    }

    # --- DryRun ---
    if ($cfg.DryRun) {
        $BlobInfo.Action = "DryRun"
        Write-Log "    DRYRUN: '$($BlobInfo.BlobName)'$vLabel - $($BlobInfo.DaysExpired)d expirado ($($BlobInfo.LengthFormatted)) [$($BlobInfo.ImmutabilityMode)]" "INFO"
        return
    }

    # Parâmetros base (SEM VersionId — Remove-AzStorageBlobImmutabilityPolicy não aceita)
    $policyParams = @{
        Container = $BlobInfo.Container
        Blob      = $BlobInfo.BlobName
        Context   = $StorageContext
    }

    # --- Remover APENAS a política ---
    if ($cfg.RemoveImmutabilityPolicyOnly) {
        try {
            Write-Log "    Removendo política: '$($BlobInfo.BlobName)'$vLabel [$($BlobInfo.ImmutabilityMode)]" "INFO"
            Remove-AzStorageBlobImmutabilityPolicy @policyParams
            $BlobInfo.Action = "PolicyRemoved"
            $stats.PoliciesRemoved++
            Write-Log "    POLICY REMOVED: '$($BlobInfo.BlobName)'$vLabel" "SUCCESS"
        }
        catch {
            $BlobInfo.Action = "ErrorRemovingPolicy: $($_.Exception.Message)"
            Add-ErrorDetail "RemovePolicy($($BlobInfo.BlobName))" $_.Exception.Message
        }
        return
    }

    # --- Remover BLOB completo ---
    if ($cfg.RemoveBlobs) {
        try {
            # PASSO 1: Remover política de imutabilidade (expirada)
            # Para version-level WORM, a política DEVE ser removida antes de deletar,
            # independente de ser Locked ou Unlocked (desde que expirada)
            if ($null -ne $BlobInfo.ImmutabilityMode) {
                try {
                    Remove-AzStorageBlobImmutabilityPolicy @policyParams -ErrorAction Stop
                    $stats.PoliciesRemoved++
                }
                catch {
                    $errMsg = $_.Exception.Message
                    # BlobNotFound (404) = versão antiga já removida ou não-current, OK continuar
                    if ($errMsg -match 'BlobNotFound|404|does not exist') {
                        Write-VerboseLog "    [1/2] Política não encontrada (versão já removida?), continuando..." "DEBUG"
                    }
                    else {
                        Write-Log "    [1/2] Aviso ao remover política (continuando): $errMsg" "WARN"
                    }
                }
            }

            # PASSO 2: Deletar o blob
            # CORREÇÃO CRÍTICA: -VersionId incluído para blobs versionados
            $deleteParams = @{
                Container = $BlobInfo.Container
                Blob      = $BlobInfo.BlobName
                Context   = $StorageContext
                Force     = $true
            }
            if ($BlobInfo.VersionId) {
                $deleteParams['VersionId'] = $BlobInfo.VersionId
            }

            Remove-AzStorageBlob @deleteParams -ErrorAction Stop

            $BlobInfo.Action = "BlobRemoved"
            $stats.BlobsRemoved++
            $stats.BytesRemoved += $BlobInfo.Length
            Write-Log "    REMOVED: '$($BlobInfo.BlobName)'$vLabel ($($BlobInfo.LengthFormatted))" "SUCCESS"
        }
        catch {
            $errMsg = $_.Exception.Message
            if ($errMsg -match 'BlobNotFound|404|does not exist') {
                # Blob já foi deletado (outra versão ou processo concorrente)
                $BlobInfo.Action = "AlreadyDeleted"
                Write-VerboseLog "    SKIP: Blob não encontrado (já removido?): '$($BlobInfo.BlobName)'$vLabel" "DEBUG"
            }
            else {
                $BlobInfo.Action = "ErrorRemoving: $errMsg"
                Add-ErrorDetail "RemoveBlob($($BlobInfo.BlobName))" $errMsg
            }
        }
    }
}

param(
    [string]$AccountName,
    [string]$AccountKey,
    [string]$BatchFile,
    [string]$ResultFile,
    [bool]$DoRemove,
    [bool]$DoPolicyOnly
)
$ErrorActionPreference = 'Continue'
Import-Module Az.Storage -ErrorAction Stop
$ctx = New-AzStorageContext -StorageAccountName $AccountName -StorageAccountKey $AccountKey
$items = Get-Content $BatchFile -Raw | ConvertFrom-Json
if ($items -isnot [array]) { $items = @($items) }
$removed = 0; $errors = 0; $polRemoved = 0; $bytesRemoved = [long]0; $errList = @()
foreach ($item in $items) {
    try {
        $polP = @{ Container = $item.Container; Blob = $item.Blob; Context = $ctx }
        if ($item.VersionId) { $polP['VersionId'] = $item.VersionId }
        if ($DoPolicyOnly) {
            $null = Remove-AzStorageBlobImmutabilityPolicy @polP -ErrorAction Stop
            $polRemoved++
        } elseif ($DoRemove) {
            if ($item.Mode) {
                try { $null = Remove-AzStorageBlobImmutabilityPolicy @polP -ErrorAction Stop; $polRemoved++ }
                catch { if ($_.Exception.Message -notmatch 'BlobNotFound|404|does not exist') {} }
            }
            $delP = @{ Container = $item.Container; Blob = $item.Blob; Context = $ctx; Force = $true }
            if ($item.VersionId) { $delP['VersionId'] = $item.VersionId }
            $null = Remove-AzStorageBlob @delP -ErrorAction Stop
            $removed++; $bytesRemoved += $item.Size
        }
    } catch {
        $e = $_.Exception.Message
        if ($e -match 'BlobNotFound|404|does not exist') { <# OK - already deleted #> }
        else { $errors++; if ($errList.Count -lt 10) { $errList += $e } }
    }
}
@{ Removed = $removed; Errors = $errors; PoliciesRemoved = $polRemoved; BytesRemoved = $bytesRemoved; ErrorList = $errList } |
    ConvertTo-Json -Depth 3 -Compress | Out-File -FilePath $ResultFile -Encoding utf8

# ============================================================================
# Reports.ps1 - Geração de relatórios HTML e CSV
# ============================================================================

function Export-HtmlReport {
    param([string]$Path)

    $cfg = $global:ImmAuditCfg
    $stats = $global:ImmAuditStats
    $results = $global:ImmAuditResults
    $containerResults = $global:ImmAuditContainerResults

    $duration = (Get-Date) - $cfg.StartTime
    $modeLabel = if ($cfg.RemoveBlobs) { "REMOÇÃO" }
                 elseif ($cfg.RemoveImmutabilityPolicyOnly) { "REMOÇÃO DE POLÍTICAS" }
                 else { "SIMULAÇÃO (DryRun)" }

    $expiredBlobs = $results | Where-Object { $_.Status -eq "Expired" }
    $legalHoldBlobs = $results | Where-Object { $_.HasLegalHold -eq $true }
    $removedSize = Format-FileSize $stats.BytesRemoved
    $modeBadgeClass = if ($cfg.RemoveBlobs -or $cfg.RemoveImmutabilityPolicyOnly) { 'mode-remove' } else { 'mode-dryrun' }

    # --- Montar seções dinâmicas ---
    $containerRowsHtml = ""
    foreach ($c in $containerResults) {
        $lhCell = if ($c.HasLegalHold) { "<span class='status-legalhold'>Sim ($($c.LegalHoldTags -join ', '))</span>" } else { 'Não' }
        $policyState = if ($c.ImmutabilityPolicyState) { $c.ImmutabilityPolicyState } else { '-' }
        $retDays = if ($c.RetentionDays) { $c.RetentionDays } else { '-' }
        $containerRowsHtml += "<tr><td>$($c.Name)</td><td>$(if($c.HasImmutabilityPolicy){'Sim'}else{'Não'})</td><td>$policyState</td><td>$retDays</td><td>$(if($c.VersionLevelWorm){'Sim'}else{'Não'})</td><td>$lhCell</td></tr>`n"
    }

    $expiredRowsHtml = ""
    foreach ($b in $expiredBlobs) {
        $actionClass = switch -Wildcard ($b.Action) {
            "DryRun"    { "action-dryrun" }
            "*Removed*" { "action-removed" }
            "Skipped*"  { "action-skipped" }
            default     { "" }
        }
        $shortName = if ($b.BlobName.Length -gt 60) { $b.BlobName.Substring(0,57) + '...' } else { $b.BlobName }
        $shortVer = if ($b.VersionId) { $b.VersionId.Substring(0,[math]::Min(16,$b.VersionId.Length)) + '...' } else { '-' }
        $expDate = if ($b.ImmutabilityExpiresOn) { $b.ImmutabilityExpiresOn.ToString('dd/MM/yyyy HH:mm') } else { '-' }
        $verTitle = if ($b.VersionId) { $b.VersionId } else { '' }
        $expiredRowsHtml += "<tr><td>$($b.StorageAccount)</td><td>$($b.Container)</td><td title='$($b.BlobName)'>$shortName</td><td class='version-id' title='$verTitle'>$shortVer</td><td>$($b.LengthFormatted)</td><td>$expDate</td><td class='status-expired'>$($b.DaysExpired)</td><td>$($b.ImmutabilityMode)</td><td class='$actionClass'>$($b.Action)</td></tr>`n"
    }

    $legalHoldRowsHtml = ""
    foreach ($b in $legalHoldBlobs) {
        $modDate = if ($b.LastModified) { $b.LastModified.ToString('dd/MM/yyyy HH:mm') } else { "-" }
        $legalHoldRowsHtml += "<tr><td>$($b.StorageAccount)</td><td>$($b.Container)</td><td>$($b.BlobName)</td><td>$($b.LengthFormatted)</td><td>$modDate</td></tr>`n"
    }

    $errorListHtml = ""
    if ($stats.ErrorDetails.Count -gt 0) {
        $errorItems = ($stats.ErrorDetails | ForEach-Object { "<li>$([System.Net.WebUtility]::HtmlEncode($_))</li>" }) -join "`n"
        $errorListHtml = @"
    <div class="section">
        <h2>Detalhes de Erros ($($stats.ErrorDetails.Count))</h2>
        <div class="error-list scrollable"><ul>$errorItems</ul></div>
    </div>
"@
    }

    $expiredSection = ""
    if ($expiredBlobs.Count -gt 0) {
        $expiredSection = @"
    <div class="section">
        <h2>Blobs com Imutabilidade Vencida ($($expiredBlobs.Count))</h2>
        <div class="scrollable"><table>
            <thead><tr><th>Storage Account</th><th>Container</th><th>Blob</th><th>VersionId</th><th>Tamanho</th><th>Expirou Em</th><th>Dias</th><th>Modo</th><th>Ação</th></tr></thead>
            <tbody>$expiredRowsHtml</tbody>
        </table></div>
    </div>
"@
    }

    $legalHoldSection = ""
    if ($legalHoldBlobs.Count -gt 0) {
        $legalHoldSection = @"
    <div class="section">
        <h2>Blobs com Legal Hold ($($legalHoldBlobs.Count))</h2>
        <div class="scrollable"><table>
            <thead><tr><th>Storage Account</th><th>Container</th><th>Blob</th><th>Tamanho</th><th>Última Modificação</th></tr></thead>
            <tbody>$legalHoldRowsHtml</tbody>
        </table></div>
    </div>
"@
    }

    $errCardClass = if ($stats.Errors -gt 0) { "warning" } else { "" }

    # --- HTML final ---
    $html = @"
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<title>Relatório - Immutability Audit v$($cfg.ScriptVersion)</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Segoe UI',Tahoma,sans-serif;background:#f5f5f5;color:#333;padding:20px}
.header{background:linear-gradient(135deg,#0078d4,#005a9e);color:#fff;padding:30px;border-radius:8px;margin-bottom:20px}
.header h1{font-size:24px;margin-bottom:8px} .header p{opacity:.9;font-size:14px}
.mode-badge{display:inline-block;padding:4px 12px;border-radius:12px;font-size:12px;font-weight:600;margin-top:8px}
.mode-dryrun{background:#fff3cd;color:#856404} .mode-remove{background:#f8d7da;color:#721c24}
.stats-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:16px;margin-bottom:20px}
.stat-card{background:#fff;padding:20px;border-radius:8px;box-shadow:0 2px 4px rgba(0,0,0,.1)}
.stat-card .value{font-size:28px;font-weight:700;color:#0078d4} .stat-card .label{font-size:13px;color:#666;margin-top:4px}
.stat-card.warning .value{color:#e74c3c} .stat-card.success .value{color:#27ae60}
.section{background:#fff;border-radius:8px;box-shadow:0 2px 4px rgba(0,0,0,.1);margin-bottom:20px;overflow:hidden}
.section h2{padding:16px 20px;background:#f8f9fa;border-bottom:1px solid #dee2e6;font-size:16px}
table{width:100%;border-collapse:collapse;font-size:13px}
th{background:#e9ecef;padding:10px 12px;text-align:left;font-weight:600;position:sticky;top:0}
td{padding:8px 12px;border-bottom:1px solid #f0f0f0} tr:hover{background:#f8f9fa}
.status-expired{color:#e74c3c;font-weight:600} .status-active{color:#27ae60;font-weight:600}
.status-legalhold{color:#f39c12;font-weight:600}
.action-removed{color:#e74c3c} .action-dryrun{color:#3498db} .action-skipped{color:#95a5a6}
.scrollable{max-height:600px;overflow-y:auto} .version-id{font-family:monospace;font-size:11px;color:#666}
.error-list{padding:16px 20px;font-size:13px} .error-list li{margin-bottom:4px;color:#721c24}
.footer{text-align:center;padding:20px;color:#999;font-size:12px}
</style>
</head>
<body>
    <div class="header">
        <h1>Relatório de Blobs com Imutabilidade Vencida</h1>
        <p>Gerado: $($cfg.StartTime.ToString("dd/MM/yyyy HH:mm:ss")) | Duração: $($duration.ToString("hh\:mm\:ss")) | v$($cfg.ScriptVersion)</p>
        <p>Páginas processadas: $($stats.PagesProcessed) | Page size: $($cfg.PageSize)</p>
        <span class="mode-badge $modeBadgeClass">$modeLabel</span>
    </div>
    <div class="stats-grid">
        <div class="stat-card"><div class="value">$($stats.StorageAccountsScanned)</div><div class="label">Storage Accounts</div></div>
        <div class="stat-card"><div class="value">$($stats.ContainersScanned)</div><div class="label">Containers</div></div>
        <div class="stat-card"><div class="value">$($stats.BlobsScanned.ToString("N0"))</div><div class="label">Blobs Analisados</div></div>
        <div class="stat-card warning"><div class="value">$($stats.BlobsWithExpiredPolicy.ToString("N0"))</div><div class="label">Imutab. Vencida</div></div>
        <div class="stat-card success"><div class="value">$($stats.BlobsWithActivePolicy.ToString("N0"))</div><div class="label">Imutab. Ativa</div></div>
        <div class="stat-card"><div class="value">$($stats.BlobsWithLegalHold)</div><div class="label">Legal Hold</div></div>
        <div class="stat-card warning"><div class="value">$(Format-FileSize $stats.BytesEligible)</div><div class="label">Elegível Remoção</div></div>
        <div class="stat-card success"><div class="value">$($stats.BlobsRemoved.ToString("N0"))</div><div class="label">Blobs Removidos</div></div>
        <div class="stat-card success"><div class="value">$removedSize</div><div class="label">Espaço Liberado</div></div>
        <div class="stat-card $errCardClass"><div class="value">$($stats.Errors)</div><div class="label">Erros</div></div>
    </div>
    <div class="section">
        <h2>Containers ($($containerResults.Count))</h2>
        <div class="scrollable"><table>
            <thead><tr><th>Container</th><th>Política</th><th>Estado</th><th>Retenção</th><th>Version WORM</th><th>Legal Hold</th></tr></thead>
            <tbody>$containerRowsHtml</tbody>
        </table></div>
    </div>
    $expiredSection
    $legalHoldSection
    $errorListHtml
    <div class="footer"><p>M365 Security Toolkit - Remove-ExpiredImmutableBlobs v$($cfg.ScriptVersion)</p></div>
</body>
</html>
"@

    $html | Out-File -FilePath $Path -Encoding utf8
    Write-Log "Relatório HTML salvo em: $Path" "SUCCESS"
}

function Export-CsvReport {
    param([string]$Path)
    $global:ImmAuditResults | Where-Object { $_.Status -ne "NoPolicy" } | Select-Object `
        StorageAccount, Container, BlobName, VersionId, IsCurrentVersion,
        BlobType, LengthFormatted,
        @{N='ImmutabilityExpiresOn'; E={ if ($_.ImmutabilityExpiresOn) { $_.ImmutabilityExpiresOn.ToString('yyyy-MM-dd HH:mm:ss') } else { '' } }},
        ImmutabilityMode, HasLegalHold, Status, DaysExpired, Eligible, Action |
        Export-Csv -Path $Path -NoTypeInformation -Encoding utf8
    Write-Log "Relatório CSV salvo em: $Path" "SUCCESS"
}

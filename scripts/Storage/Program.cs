// RemoveExpiredBlobs v2.0.0 — .NET version of Remove-ExpiredImmutableBlobs.ps1
// Uses Azure.Storage.Blobs SDK with batch delete for maximum performance.
// Features: streaming delete, HTML report, checkpoint/resume, CSV export.
//
// Location: scripts/Storage/RemoveExpiredBlobs/
// Build:    dotnet build
// Run:      dotnet run -- -StorageAccountName <name> -ContainerName <container> [-AccountKey <key>]

using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Azure.Identity;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Azure.Storage.Blobs.Specialized;
using Azure.ResourceManager;
using Azure.ResourceManager.Resources;
using Azure.ResourceManager.Storage;

namespace RemoveExpiredBlobs;

public static class Program
{
    const string Version = "2.0.0";
    const int StreamingBatchSize = 5000;

    static string? SubscriptionId;
    static string? ResourceGroupName;
    static string? StorageAccountName;
    static string? ContainerFilter;
    static string? BlobPrefix;
    static string OutputPath = "./Reports";
    static bool RemoveBlobs;
    static bool RemovePolicyOnly;
    static bool Force;
    static bool ExportCsv;
    static int MaxDaysExpired;
    static int MaxErrors;
    static int Concurrency = 50;
    static int BatchSize = 256;
    static string? AccountKey;
    static string? ResumeFrom;

    static long TotalBlobs;
    static long ExpiredBlobs;
    static long ActiveBlobs;
    static long LegalHoldBlobs;
    static long EligibleBlobs;
    static long EligibleBytes;
    static long RemovedBlobs;
    static long RemovedBytes;
    static long PoliciesRemoved;
    static long ErrorCount;
    static long SkippedByCheckpoint;
    static int Pages;
    static readonly ConcurrentBag<string> ErrorList = [];
    static readonly List<ContainerReport> ContainerReports = [];
    static string? _checkpointPath;
    static CheckpointData? _checkpoint;

    public static async Task<int> Main(string[] args)
    {
        ParseArgs(args);

        var sw = Stopwatch.StartNew();
        var ts = DateTime.Now.ToString("yyyyMMdd_HHmmss");
        var mode = RemoveBlobs ? "REMOVER" : RemovePolicyOnly ? "SOMENTE POLÍTICAS" : "DRY-RUN (auditoria)";

        Log($"Remove-ExpiredImmutableBlobs .NET v{Version}", "SECTION");
        Log($"Modo: {mode} | Concorrência: {Concurrency} | BatchDelete: {BatchSize}", "SECTION");

        if (!Force && (RemoveBlobs || RemovePolicyOnly))
        {
            Console.ForegroundColor = ConsoleColor.Yellow;
            Console.Write($"\n  Modo: {mode}\n  Digite 'CONFIRMAR' para prosseguir: ");
            Console.ResetColor();
            var confirmation = Console.ReadLine()?.Trim();
            if (!string.Equals(confirmation, "confirmar", StringComparison.OrdinalIgnoreCase))
            {
                Log("Operação cancelada pelo usuário.", "WARN");
                return 1;
            }
        }

        Log("Verificando conexão Azure...", "INFO");
        var credential = new DefaultAzureCredential(new DefaultAzureCredentialOptions
        {
            ExcludeVisualStudioCodeCredential = true,
            ExcludeVisualStudioCredential = true,
        });

        var accounts = await DiscoverStorageAccounts(credential);
        if (accounts.Count == 0) { Log("Nenhuma Storage Account encontrada.", "ERROR"); return 1; }
        Log($"Encontradas {accounts.Count} Storage Account(s)", "INFO");

        Directory.CreateDirectory(OutputPath);
        OutputPath = Path.GetFullPath(OutputPath);

        var csvPath = ExportCsv ? Path.Combine(OutputPath, $"ImmutabilityAudit_{ts}.csv") : null;
        StreamWriter? csvWriter = null;
        if (csvPath != null)
        {
            csvWriter = new StreamWriter(csvPath, false, Encoding.UTF8);
            await csvWriter.WriteLineAsync("Account,Container,Blob,VersionId,Size,SizeFmt,ExpiresOn,Mode,Status,DaysExp,Eligible,Action");
        }

        _checkpointPath = Path.Combine(OutputPath, $"checkpoint_{ts}.json");
        if (!string.IsNullOrEmpty(ResumeFrom) && File.Exists(ResumeFrom))
        {
            _checkpoint = JsonSerializer.Deserialize<CheckpointData>(File.ReadAllText(ResumeFrom));
            Log($"Retomando de checkpoint: {ResumeFrom} ({_checkpoint?.ProcessedBlobs ?? 0} blobs já processados)", "WARN");
        }

        var acctIdx = 0;
        foreach (var (acctName, acctKey) in accounts)
        {
            acctIdx++;
            Log($"Storage Account [{acctIdx}/{accounts.Count}]: {acctName}", "SECTION");

            var blobServiceClient = CreateBlobServiceClient(acctName, acctKey, credential);
            BlobBatchClient? batchClient = RemoveBlobs ? blobServiceClient.GetBlobBatchClient() : null;

            var containers = new List<string>();
            await foreach (var c in blobServiceClient.GetBlobContainersAsync())
            {
                if (ContainerFilter == null || c.Name == ContainerFilter)
                    containers.Add(c.Name);
            }

            var ctrIdx = 0;
            foreach (var containerName in containers)
            {
                ctrIdx++;
                var containerClient = blobServiceClient.GetBlobContainerClient(containerName);
                Log($"  Container [{ctrIdx}/{containers.Count}]: {containerName}", "INFO");

                var ctrReport = new ContainerReport { Account = acctName, Container = containerName };
                ContainerReports.Add(ctrReport);

                var pendingDelete = new List<BlobItemInfo>();
                var pendingRoots = new List<BlobItemInfo>();
                var blobCount = 0;
                var ctrEligible = 0L;
                var ctrEligibleBytes = 0L;
                var ctrRemoved = 0L;
                var ctrErrors = 0L;

                await foreach (var blob in containerClient.GetBlobsAsync(
                    traits: BlobTraits.ImmutabilityPolicy | BlobTraits.LegalHold,
                    states: BlobStates.Version,
                    prefix: BlobPrefix))
                {
                    blobCount++;
                    Interlocked.Increment(ref TotalBlobs);

                    if (_checkpoint != null && blobCount <= _checkpoint.ProcessedBlobs)
                    {
                        Interlocked.Increment(ref SkippedByCheckpoint);
                        continue;
                    }

                    var props = blob.Properties;
                    var expiresOn = props.ImmutabilityPolicy?.ExpiresOn;
                    var policyMode = props.ImmutabilityPolicy?.PolicyMode?.ToString();
                    var hasLegalHold = props.HasLegalHold == true;
                    var now = DateTimeOffset.UtcNow;

                    string status;
                    bool isEligible = false;

                    if (hasLegalHold)
                    {
                        status = "LegalHold";
                        Interlocked.Increment(ref LegalHoldBlobs);
                    }
                    else if (expiresOn == null)
                    {
                        status = "NoPolicy";
                        if (blob.VersionId != null) { isEligible = true; status = "Expired"; }
                    }
                    else if (expiresOn <= now)
                    {
                        var daysExp = (int)(now - expiresOn.Value).TotalDays;
                        if (MaxDaysExpired > 0 && daysExp < MaxDaysExpired)
                            status = "ExpiredBelowThreshold";
                        else
                        {
                            status = "Expired";
                            isEligible = true;
                            Interlocked.Increment(ref ExpiredBlobs);
                        }
                    }
                    else
                    {
                        status = "Active";
                        Interlocked.Increment(ref ActiveBlobs);
                    }

                    if (isEligible)
                    {
                        Interlocked.Increment(ref EligibleBlobs);
                        Interlocked.Add(ref EligibleBytes, props.ContentLength ?? 0);
                        ctrEligible++;
                        ctrEligibleBytes += props.ContentLength ?? 0;

                        var item = new BlobItemInfo
                        {
                            Container = containerName,
                            Name = blob.Name,
                            VersionId = blob.VersionId,
                            Size = props.ContentLength ?? 0,
                            Mode = policyMode,
                            ExpiresOn = expiresOn,
                            IsCurrentVersion = blob.IsLatestVersion == true
                        };

                        // Root/current blobs must be deleted AFTER their old versions
                        if (item.IsCurrentVersion)
                            pendingRoots.Add(item);
                        else
                            pendingDelete.Add(item);
                    }

                    if (csvWriter != null)
                    {
                        var sizeFmt = FormatSize(props.ContentLength ?? 0);
                        var daysExpStr = expiresOn != null && expiresOn <= now
                            ? ((int)(now - expiresOn.Value).TotalDays).ToString() : "";
                        await csvWriter.WriteLineAsync(
                            $"\"{acctName}\",\"{containerName}\",\"{EscapeCsv(blob.Name)}\",\"{blob.VersionId}\"," +
                            $"{props.ContentLength ?? 0},\"{sizeFmt}\",\"{expiresOn}\",\"{policyMode}\"," +
                            $"\"{status}\",\"{daysExpStr}\",\"{isEligible}\",\"\"");
                    }

                    if (pendingDelete.Count >= StreamingBatchSize && (RemoveBlobs || RemovePolicyOnly))
                    {
                        var (rem, err) = await ProcessDeleteBatch(containerClient, blobServiceClient, batchClient, containerName, pendingDelete);
                        ctrRemoved += rem; ctrErrors += err;
                        pendingDelete.Clear();
                        SaveCheckpoint(blobCount);
                    }

                    if (blobCount % 5000 == 0)
                    {
                        Pages++;
                        Log($"    Pág {Pages}: {blobCount:N0} blobs | Elig: {ctrEligible:N0} ({FormatSize(ctrEligibleBytes)}) | Rem: {ctrRemoved:N0} | Err: {ctrErrors:N0}", "INFO");
                    }

                    if (MaxErrors > 0 && ErrorCount >= MaxErrors) break;
                }

                // Flush remaining old versions
                if (pendingDelete.Count > 0 && (RemoveBlobs || RemovePolicyOnly))
                {
                    var (rem, err) = await ProcessDeleteBatch(containerClient, blobServiceClient, batchClient, containerName, pendingDelete);
                    ctrRemoved += rem; ctrErrors += err;
                    pendingDelete.Clear();
                    SaveCheckpoint(blobCount);
                }

                // Delete root/current blobs AFTER all old versions are gone
                if (pendingRoots.Count > 0 && (RemoveBlobs || RemovePolicyOnly))
                {
                    Log($"    ► Deletando {pendingRoots.Count:N0} root blobs ({FormatSize(pendingRoots.Sum(r => r.Size))})...", "WARN");
                    for (var ri = 0; ri < pendingRoots.Count; ri += StreamingBatchSize)
                    {
                        var rootBatch = pendingRoots.Skip(ri).Take(StreamingBatchSize).ToList();
                        var (rem, err) = await DeleteRootBlobsAsync(containerClient, rootBatch);
                        ctrRemoved += rem; ctrErrors += err;
                    }
                    pendingRoots.Clear();
                    SaveCheckpoint(blobCount);
                }

                if (blobCount % 5000 != 0)
                {
                    Pages++;
                    Log($"    Pág {Pages}: {blobCount:N0} blobs total | Elig: {ctrEligible:N0} ({FormatSize(ctrEligibleBytes)}) | Rem: {ctrRemoved:N0}", "INFO");
                }

                ctrReport.TotalBlobs = blobCount;
                ctrReport.Eligible = ctrEligible;
                ctrReport.EligibleBytes = ctrEligibleBytes;
                ctrReport.Removed = ctrRemoved;
                ctrReport.Errors = ctrErrors;

                if (MaxErrors > 0 && ErrorCount >= MaxErrors) { Log($"MaxErrors ({MaxErrors}) atingido, abortando.", "ERROR"); break; }
            }
        }

        csvWriter?.Dispose();
        sw.Stop();
        var duration = sw.Elapsed;

        Console.WriteLine();
        Log(new string('=', 60), "SECTION");
        Log($"RESUMO v{Version}", "SECTION");
        Log(new string('=', 60), "SECTION");
        Log($"Accounts: {accounts.Count} | Containers: {ContainerReports.Count}", "INFO");
        Log($"Blobs: {TotalBlobs:N0} | Expirados: {ExpiredBlobs:N0} | Ativos: {ActiveBlobs:N0} | LegalHold: {LegalHoldBlobs:N0}", "INFO");
        Log($"Elegível: {EligibleBlobs:N0} ({FormatSize(EligibleBytes)})", "WARN");
        if (SkippedByCheckpoint > 0) Log($"Checkpoint skip: {SkippedByCheckpoint:N0}", "INFO");
        Log($"REMOVIDOS: {RemovedBlobs:N0} | Espaço: {FormatSize(RemovedBytes)} | Políticas: {PoliciesRemoved:N0}", "SUCCESS");
        if (ErrorCount > 0)
        {
            Log($"Erros: {ErrorCount:N0}", "ERROR");
            foreach (var err in ErrorList.Take(10)) Log($"  {err}", "ERROR");
        }
        Log($"Duração: {duration:hh\\:mm\\:ss}", "INFO");

        var htmlPath = Path.Combine(OutputPath, $"ImmutabilityAudit_{ts}.html");
        GenerateHtmlReport(htmlPath, ts, mode, duration);
        Log($"Relatório HTML: {htmlPath}", "SUCCESS");

        if (ErrorCount == 0 && _checkpointPath != null && File.Exists(_checkpointPath))
        {
            File.Delete(_checkpointPath);
            Log("Checkpoint removido (execução completa).", "INFO");
        }
        else if (_checkpointPath != null && File.Exists(_checkpointPath))
            Log($"Checkpoint mantido: {_checkpointPath} (use -ResumeFrom para retomar)", "WARN");

        return ErrorCount > 0 ? 2 : 0;
    }

    static async Task<(long removed, long errors)> ProcessDeleteBatch(
        BlobContainerClient containerClient, BlobServiceClient serviceClient,
        BlobBatchClient? batchClient, string containerName, List<BlobItemInfo> items)
    {
        long removed = 0, errors = 0;
        Log($"    ► Deletando lote: {items.Count} blob(s) | {FormatSize(items.Sum(e => e.Size))}", "WARN");

        // Only remove policies for Unlocked mode — Locked policies can't be removed
        // but expired Locked blobs can be deleted directly
        var unlocked = items.Where(i => i.Mode != null && i.Mode.Equals("Unlocked", StringComparison.OrdinalIgnoreCase)).ToList();
        if (unlocked.Count > 0) await RemovePoliciesAsync(containerClient, unlocked);

        if (RemoveBlobs)
        {
            // BlobBatchClient doesn't support versioned blobs (versionId in URI fails)
            // Use concurrent individual deletes instead — still fast with async/await
            var (r, e) = await ConcurrentDeleteAsync(serviceClient, containerName, items);
            removed = r; errors = e;
        }
        else if (RemovePolicyOnly) removed = unlocked.Count;

        return (removed, errors);
    }

    static async Task RemovePoliciesAsync(BlobContainerClient containerClient, List<BlobItemInfo> items)
    {
        var semaphore = new SemaphoreSlim(Concurrency);
        var removed = 0; var errors = 0;
        var tasks = new List<Task>();

        foreach (var item in items)
        {
            await semaphore.WaitAsync();
            tasks.Add(Task.Run(async () =>
            {
                try
                {
                    var blobClient = containerClient.GetBlobClient(item.Name).WithVersion(item.VersionId!);
                    await blobClient.DeleteImmutabilityPolicyAsync();
                    Interlocked.Increment(ref removed);
                    Interlocked.Increment(ref PoliciesRemoved);
                }
                catch (Azure.RequestFailedException ex) when (ex.Status == 404) { }
                catch (Exception ex)
                {
                    Interlocked.Increment(ref errors);
                    Interlocked.Increment(ref ErrorCount);
                    if (ErrorList.Count < 200) ErrorList.Add($"RemovePolicy({item.Name}): {ex.Message}");
                }
                finally { semaphore.Release(); }
            }));
            if (MaxErrors > 0 && ErrorCount >= MaxErrors) break;
        }

        await Task.WhenAll(tasks);
        Log($"      Políticas removidas: {removed}, erros: {errors}", removed > 0 ? "SUCCESS" : "INFO");
    }

    static async Task<(long removed, long errors)> BatchDeleteAsync(
        BlobServiceClient serviceClient, BlobBatchClient batchClient,
        string containerName, List<BlobItemInfo> items)
    {
        long totalRemoved = 0, totalErrors = 0;

        for (var i = 0; i < items.Count; i += BatchSize)
        {
            var batch = items.Skip(i).Take(BatchSize).ToList();
            var batchNum = i / BatchSize + 1;
            var totalBatches = (items.Count + BatchSize - 1) / BatchSize;

            try
            {
                var uris = batch.Select(b =>
                    new Uri($"{serviceClient.Uri}{containerName}/{Uri.EscapeDataString(b.Name)}?versionid={Uri.EscapeDataString(b.VersionId!)}"))
                    .ToList();

                var responses = await batchClient.DeleteBlobsAsync(uris);

                var batchRemoved = 0; var batchErrors = 0;
                for (var r = 0; r < responses.Length; r++)
                {
                    var resp = responses[r];
                    if (resp.Status is >= 200 and < 300 or 404)
                    {
                        batchRemoved++;
                        Interlocked.Increment(ref RemovedBlobs);
                        Interlocked.Add(ref RemovedBytes, batch[r].Size);
                    }
                    else
                    {
                        batchErrors++;
                        Interlocked.Increment(ref ErrorCount);
                        if (ErrorList.Count < 200) ErrorList.Add($"BatchDelete({batch[r].Name}): HTTP {resp.Status} {resp.ReasonPhrase}");
                    }
                }

                totalRemoved += batchRemoved; totalErrors += batchErrors;
                Log($"      Batch {batchNum}/{totalBatches}: {batchRemoved} removidos, {batchErrors} erros ({FormatSize(batch.Sum(b => b.Size))})", batchErrors > 0 ? "WARN" : "SUCCESS");
            }
            catch (Exception ex)
            {
                Log($"      Batch {batchNum}/{totalBatches}: batch API falhou ({ex.Message}), fallback individual...", "WARN");
                var (fr, fe) = await ConcurrentDeleteAsync(serviceClient, containerName, batch);
                totalRemoved += fr; totalErrors += fe;
            }

            if (MaxErrors > 0 && ErrorCount >= MaxErrors) break;
        }

        return (totalRemoved, totalErrors);
    }

    static async Task<(long removed, long errors)> ConcurrentDeleteAsync(
        BlobServiceClient serviceClient, string containerName, List<BlobItemInfo> items)
    {
        var containerClient = serviceClient.GetBlobContainerClient(containerName);
        var semaphore = new SemaphoreSlim(Concurrency);
        long removed = 0, errors = 0;
        var tasks = new List<Task>();

        foreach (var item in items)
        {
            await semaphore.WaitAsync();
            tasks.Add(Task.Run(async () =>
            {
                try
                {
                    var blobClient = containerClient.GetBlobClient(item.Name).WithVersion(item.VersionId!);
                    await blobClient.DeleteAsync(DeleteSnapshotsOption.None);
                    Interlocked.Increment(ref removed);
                    Interlocked.Increment(ref RemovedBlobs);
                    Interlocked.Add(ref RemovedBytes, item.Size);
                }
                catch (Azure.RequestFailedException ex) when (ex.Status == 404)
                {
                    Interlocked.Increment(ref removed);
                    Interlocked.Increment(ref RemovedBlobs);
                }
                catch (Exception ex)
                {
                    Interlocked.Increment(ref errors);
                    Interlocked.Increment(ref ErrorCount);
                    if (ErrorList.Count < 200) ErrorList.Add($"Delete({item.Name}): {ex.Message}");
                }
                finally { semaphore.Release(); }
            }));
        }

        await Task.WhenAll(tasks);
        Log($"      Deletados: {removed}, erros: {errors}", removed > 0 ? "SUCCESS" : "INFO");
        return (removed, errors);
    }

    // Delete root/current blobs — must NOT use .WithVersion()
    static async Task<(long removed, long errors)> DeleteRootBlobsAsync(
        BlobContainerClient containerClient, List<BlobItemInfo> items)
    {
        var semaphore = new SemaphoreSlim(Concurrency);
        long removed = 0, errors = 0;
        var tasks = new List<Task>();

        foreach (var item in items)
        {
            await semaphore.WaitAsync();
            tasks.Add(Task.Run(async () =>
            {
                try
                {
                    var blobClient = containerClient.GetBlobClient(item.Name);
                    await blobClient.DeleteAsync(DeleteSnapshotsOption.IncludeSnapshots);
                    Interlocked.Increment(ref removed);
                    Interlocked.Increment(ref RemovedBlobs);
                    Interlocked.Add(ref RemovedBytes, item.Size);
                }
                catch (Azure.RequestFailedException ex) when (ex.Status == 404)
                {
                    Interlocked.Increment(ref removed);
                    Interlocked.Increment(ref RemovedBlobs);
                }
                catch (Exception ex)
                {
                    Interlocked.Increment(ref errors);
                    Interlocked.Increment(ref ErrorCount);
                    if (ErrorList.Count < 200) ErrorList.Add($"DeleteRoot({item.Name}): {ex.Message}");
                }
                finally { semaphore.Release(); }
            }));
        }

        await Task.WhenAll(tasks);
        Log($"      Root blobs deletados: {removed}, erros: {errors}", removed > 0 ? "SUCCESS" : "INFO");
        return (removed, errors);
    }

    static void SaveCheckpoint(long processedBlobs)
    {
        if (_checkpointPath == null) return;
        var data = new CheckpointData
        {
            ProcessedBlobs = processedBlobs, RemovedBlobs = RemovedBlobs,
            RemovedBytes = RemovedBytes, Errors = ErrorCount, Timestamp = DateTime.UtcNow
        };
        File.WriteAllText(_checkpointPath, JsonSerializer.Serialize(data, new JsonSerializerOptions { WriteIndented = true }));
    }

    static void GenerateHtmlReport(string path, string ts, string mode, TimeSpan duration)
    {
        var sb = new StringBuilder();
        sb.AppendLine("<!DOCTYPE html><html lang='pt-BR'><head><meta charset='utf-8'>");
        sb.AppendLine("<title>Immutability Audit Report</title>");
        sb.AppendLine("<style>");
        sb.AppendLine("body { font-family: 'Segoe UI', Arial, sans-serif; margin: 20px; background: #1a1a2e; color: #e0e0e0; }");
        sb.AppendLine("h1 { color: #00d4ff; border-bottom: 2px solid #00d4ff; padding-bottom: 10px; }");
        sb.AppendLine("h2 { color: #7dd3fc; margin-top: 30px; }");
        sb.AppendLine(".summary { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 15px; margin: 20px 0; }");
        sb.AppendLine(".card { background: #16213e; border-radius: 8px; padding: 20px; border-left: 4px solid #00d4ff; }");
        sb.AppendLine(".card.success { border-left-color: #00e676; } .card.warn { border-left-color: #ffc107; } .card.error { border-left-color: #ff5252; }");
        sb.AppendLine(".card .label { font-size: 0.85em; color: #94a3b8; text-transform: uppercase; }");
        sb.AppendLine(".card .value { font-size: 1.8em; font-weight: bold; margin-top: 5px; }");
        sb.AppendLine("table { border-collapse: collapse; width: 100%; margin: 15px 0; }");
        sb.AppendLine("th, td { padding: 10px 14px; text-align: left; border-bottom: 1px solid #334155; }");
        sb.AppendLine("th { background: #0f3460; color: #7dd3fc; font-weight: 600; }");
        sb.AppendLine("tr:hover { background: #1e3a5f; }");
        sb.AppendLine(".footer { margin-top: 40px; padding-top: 15px; border-top: 1px solid #334155; color: #64748b; font-size: 0.85em; }");
        sb.AppendLine(".tag { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 0.8em; }");
        sb.AppendLine(".tag-remove { background: #ff525233; color: #ff5252; } .tag-dry { background: #ffc10733; color: #ffc107; } .tag-policy { background: #00e67633; color: #00e676; }");
        sb.AppendLine("</style></head><body>");

        var modeTag = RemoveBlobs ? "<span class='tag tag-remove'>REMOVER</span>"
            : RemovePolicyOnly ? "<span class='tag tag-policy'>SOMENTE POLÍTICAS</span>"
            : "<span class='tag tag-dry'>DRY-RUN</span>";
        sb.AppendLine($"<h1>🔒 Immutability Audit Report {modeTag}</h1>");
        sb.AppendLine($"<p>{DateTime.Now:dd/MM/yyyy HH:mm:ss} | Duração: {duration:hh\\:mm\\:ss} | v{Version} (.NET)</p>");

        sb.AppendLine("<div class='summary'>");
        AppendCard(sb, "Blobs Analisados", $"{TotalBlobs:N0}", "");
        AppendCard(sb, "Expirados", $"{ExpiredBlobs:N0}", "warn");
        AppendCard(sb, "Ativos", $"{ActiveBlobs:N0}", "");
        AppendCard(sb, "Legal Hold", $"{LegalHoldBlobs:N0}", "");
        AppendCard(sb, "Elegíveis", $"{EligibleBlobs:N0} ({FormatSize(EligibleBytes)})", "warn");
        AppendCard(sb, "Removidos", $"{RemovedBlobs:N0} ({FormatSize(RemovedBytes)})", "success");
        AppendCard(sb, "Políticas Removidas", $"{PoliciesRemoved:N0}", "success");
        AppendCard(sb, "Erros", $"{ErrorCount:N0}", ErrorCount > 0 ? "error" : "");
        sb.AppendLine("</div>");

        sb.AppendLine("<h2>Containers</h2>");
        sb.AppendLine("<table><tr><th>Account</th><th>Container</th><th>Blobs</th><th>Elegíveis</th><th>Tamanho</th><th>Removidos</th><th>Erros</th></tr>");
        foreach (var c in ContainerReports)
            sb.AppendLine($"<tr><td>{c.Account}</td><td>{c.Container}</td><td>{c.TotalBlobs:N0}</td><td>{c.Eligible:N0}</td><td>{FormatSize(c.EligibleBytes)}</td><td>{c.Removed:N0}</td><td>{c.Errors:N0}</td></tr>");
        sb.AppendLine("</table>");

        if (ErrorCount > 0)
        {
            sb.AppendLine("<h2>Erros (primeiros 20)</h2><table><tr><th>#</th><th>Mensagem</th></tr>");
            var idx = 0;
            foreach (var err in ErrorList.Take(20)) { idx++; sb.AppendLine($"<tr><td>{idx}</td><td>{System.Net.WebUtility.HtmlEncode(err)}</td></tr>"); }
            sb.AppendLine("</table>");
        }

        sb.AppendLine($"<div class='footer'><p>Gerado por RemoveExpiredBlobs .NET v{Version} | Concorrência: {Concurrency} | BatchSize: {BatchSize}</p></div></body></html>");
        File.WriteAllText(path, sb.ToString(), Encoding.UTF8);
    }

    static void AppendCard(StringBuilder sb, string label, string value, string cssClass) =>
        sb.AppendLine($"<div class='card {cssClass}'><div class='label'>{label}</div><div class='value'>{value}</div></div>");

    static async Task<List<(string Name, string Key)>> DiscoverStorageAccounts(DefaultAzureCredential credential)
    {
        var result = new List<(string, string)>();

        if (!string.IsNullOrEmpty(StorageAccountName))
        {
            try
            {
                var client = CreateBlobServiceClient(StorageAccountName, AccountKey, credential);
                await client.GetPropertiesAsync();
                result.Add((StorageAccountName, AccountKey ?? ""));
                Log($"Conectado: {StorageAccountName} (via {(!string.IsNullOrEmpty(AccountKey) ? "AccountKey" : "DefaultAzureCredential")})", "SUCCESS");
            }
            catch (Exception ex) { Log($"Erro conectando a {StorageAccountName}: {ex.Message}", "ERROR"); }
            return result;
        }

        try
        {
            var armClient = new ArmClient(credential);
            var subscription = string.IsNullOrEmpty(SubscriptionId)
                ? await armClient.GetDefaultSubscriptionAsync()
                : armClient.GetSubscriptionResource(new Azure.Core.ResourceIdentifier($"/subscriptions/{SubscriptionId}"));
            Log($"Subscription: {subscription.Data.DisplayName}", "SUCCESS");

            await foreach (var account in subscription.GetStorageAccountsAsync())
            {
                if (!string.IsNullOrEmpty(ResourceGroupName) &&
                    !string.Equals(account.Id.ResourceGroupName, ResourceGroupName, StringComparison.OrdinalIgnoreCase))
                    continue;
                result.Add((account.Data.Name, ""));
            }
        }
        catch (Exception ex) { Log($"Erro descobrindo storage accounts: {ex.Message}", "ERROR"); }

        return result;
    }

    static BlobServiceClient CreateBlobServiceClient(string accountName, string? key, DefaultAzureCredential credential)
    {
        if (!string.IsNullOrEmpty(key))
            return new BlobServiceClient($"DefaultEndpointsProtocol=https;AccountName={accountName};AccountKey={key};EndpointSuffix=core.windows.net");
        return new BlobServiceClient(new Uri($"https://{accountName}.blob.core.windows.net"), credential);
    }

    static void ParseArgs(string[] args)
    {
        for (var i = 0; i < args.Length; i++)
        {
            var arg = args[i].ToLowerInvariant().TrimStart('-');
            switch (arg)
            {
                case "subscriptionid": SubscriptionId = args[++i]; break;
                case "resourcegroupname": ResourceGroupName = args[++i]; break;
                case "storageaccountname": StorageAccountName = args[++i]; break;
                case "containername": ContainerFilter = args[++i]; break;
                case "blobprefix": BlobPrefix = args[++i]; break;
                case "outputpath": OutputPath = args[++i]; break;
                case "removeblobs": RemoveBlobs = true; break;
                case "removepolicyonly": RemovePolicyOnly = true; break;
                case "force": Force = true; break;
                case "exportcsv": ExportCsv = true; break;
                case "maxdaysexpired": MaxDaysExpired = int.Parse(args[++i]); break;
                case "maxerrors": MaxErrors = int.Parse(args[++i]); break;
                case "concurrency": Concurrency = int.Parse(args[++i]); break;
                case "batchsize": BatchSize = Math.Min(int.Parse(args[++i]), 256); break;
                case "accountkey": AccountKey = args[++i]; break;
                case "resumefrom": ResumeFrom = args[++i]; break;
                case "help" or "h" or "?": PrintUsage(); Environment.Exit(0); break;
                default: Log($"Argumento desconhecido: {args[i]}", "WARN"); break;
            }
        }
    }

    static void PrintUsage() => Console.WriteLine($"""
        RemoveExpiredBlobs .NET v{Version}

        Uso:  dotnet run -- [opções]

        Opções:
          -StorageAccountName <n>   Storage account específica
          -ResourceGroupName <n>    Filtrar por resource group
          -SubscriptionId <id>      Azure subscription ID
          -ContainerName <n>        Filtrar por container
          -BlobPrefix <prefix>      Filtrar por prefixo de blob
          -AccountKey <key>         Storage account key (bypasses RBAC)
          -RemoveBlobs              Deletar blobs expirados
          -RemovePolicyOnly         Apenas remover políticas
          -Force                    Pular confirmação
          -ExportCsv                Exportar relatório CSV
          -OutputPath <path>        Diretório de saída (default: ./Reports)
          -Concurrency <n>          Operações async simultâneas (default: 50)
          -BatchSize <n>            Blobs por batch delete (max: 256, default: 256)
          -MaxDaysExpired <n>       Mínimo dias expirado
          -MaxErrors <n>            Parar após N erros
          -ResumeFrom <path>        Retomar de checkpoint
          -Help                     Mostrar ajuda
        """);

    static void Log(string message, string level = "INFO")
    {
        var time = DateTime.Now.ToString("HH:mm:ss");
        var (prefix, color) = level switch
        {
            "SUCCESS" => ("[+]", ConsoleColor.Green),
            "WARN" => ("[!]", ConsoleColor.Yellow),
            "ERROR" => ("[X]", ConsoleColor.Red),
            "SECTION" => ("[=]", ConsoleColor.Cyan),
            _ => ("[i]", ConsoleColor.Gray)
        };
        Console.ForegroundColor = color;
        Console.WriteLine($"{time} {prefix} {message}");
        Console.ResetColor();
    }

    static string FormatSize(long bytes) => bytes switch
    {
        < 1024 => $"{bytes} B",
        < 1024 * 1024 => $"{bytes / 1024.0:F2} KB",
        < 1024L * 1024 * 1024 => $"{bytes / (1024.0 * 1024):F2} MB",
        < 1024L * 1024 * 1024 * 1024 => $"{bytes / (1024.0 * 1024 * 1024):F2} GB",
        _ => $"{bytes / (1024.0 * 1024 * 1024 * 1024):F2} TB"
    };

    static string EscapeCsv(string s) => s.Replace("\"", "\"\"");
}

public class BlobItemInfo
{
    public required string Container { get; set; }
    public required string Name { get; set; }
    public string? VersionId { get; set; }
    public long Size { get; set; }
    public string? Mode { get; set; }
    public DateTimeOffset? ExpiresOn { get; set; }
    public bool IsCurrentVersion { get; set; }
}

public class ContainerReport
{
    public string Account { get; set; } = "";
    public string Container { get; set; } = "";
    public long TotalBlobs { get; set; }
    public long Eligible { get; set; }
    public long EligibleBytes { get; set; }
    public long Removed { get; set; }
    public long Errors { get; set; }
}

public class CheckpointData
{
    public long ProcessedBlobs { get; set; }
    public long RemovedBlobs { get; set; }
    public long RemovedBytes { get; set; }
    public long Errors { get; set; }
    public DateTime Timestamp { get; set; }
}

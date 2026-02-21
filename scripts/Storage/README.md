# Azure Storage Scripts

Ferramentas para gerenciamento de Azure Blob Storage.

## RemoveExpiredBlobs (.NET)

Deleta blobs com immutability policies (WORM) expiradas. Ideal para limpar backups Veeam com versioning habilitado.

- **256 blobs/request** via Batch Delete API
- **Streaming delete** — memória constante (~350MB)
- **Relatório HTML** com cards de resumo
- **Checkpoint/resume** para execuções longas

```bash
cd RemoveExpiredBlobs
dotnet build
dotnet run -- -StorageAccountName <account> -ContainerName <container> -AccountKey "<key>"
```

→ [Documentação completa](RemoveExpiredBlobs/README.md)

## Audit-AdminAccount

Script de auditoria de contas administrativas.

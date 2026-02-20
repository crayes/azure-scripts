# Remove-ExpiredImmutableBlobs — Histórico de Versões

## Backlog / Refinamentos para v2.1+

### Problemas Conhecidos (v2.0.0)
- **`Remove-AzStorageBlobImmutabilityPolicy` não aceita `-VersionId`**: O cmdlet opera na versão "current" do blob. Para versões não-current, retorna 404 (BlobNotFound). O script trata esse erro silenciosamente e continua a deleção, mas gera log `[D] [1/2] Política não encontrada`. Investigar se existe API alternativa para remover política de versão específica.
- **Paginação máxima do Azure = 5000**: O `Get-AzStorageBlob -MaxCount` tem teto de 5000 no SDK. Valores maiores são ignorados pelo servidor. Não há como aumentar além disso.

### Refinamentos Planejados
- [ ] Reduzir verbosidade: suprimir `[D] [1/2] Política não encontrada` quando é BlobNotFound esperado (versão não-current)
- [ ] Adicionar contadores por página no resumo: `Página X: Y removidos, Z erros`
- [ ] Paralelismo: usar `-AsJob` ou `ForEach-Object -Parallel` para deleções (cuidado com throttling Azure)
- [ ] Retry automático com backoff para erros 429 (throttling) e 503 (service busy)
- [ ] Progress bar percentual baseado em bytes (não blobs) para containers grandes
- [ ] Parâmetro `-MaxErrors` para abortar se muitos erros consecutivos
- [ ] Log para arquivo (transcript) além do console
- [ ] Filtro por AccessTier (ex: só Hot, só Archive)
- [ ] Filtro por prefixo de blob (ex: `Veeam/Archive/`)
- [ ] Suporte a múltiplas subscriptions em uma execução
- [ ] Estimativa de custo economizado baseado em tier + tamanho

---

## v2.0.0 (2026-02-20) — Refatoração Modular + Correções Críticas

### Estrutura
```
Storage/
├── Remove-ExpiredImmutableBlobs.ps1   # Script principal (orquestração)
├── README.md                          # Documentação e exemplos
├── CHANGELOG.md                       # Este arquivo
└── lib/
    ├── Helpers.ps1          # Write-Log, Write-VerboseLog, Format-FileSize, Show-Progress, Get-Throughput, Test-AzureConnection
    ├── AzureDiscovery.ps1   # Get-TargetStorageAccounts, Get-ContainerImmutabilityInfo
    ├── BlobPagination.ps1   # Get-BlobsPaginated (NÃO MAIS USADO - paginação inline no main)
    ├── BlobAnalysis.ps1     # Test-BlobImmutabilityExpired, Invoke-BlobAction
    └── Reports.ps1          # Export-HtmlReport, Export-CsvReport
```

### 🔴 Correções Críticas (herdadas da análise do script monolítico)
1. **Paginação quebrada**: `ContinuationToken` se perdia ao fazer `@($output)` — script processava só 1 página (5000 blobs). Corrigido: token capturado do output RAW antes de transformar em array.
2. **VersionId não propagado**: `Remove-AzStorageBlob` sem `-VersionId` falhava silenciosamente para blobs versionados. Corrigido: VersionId propagado no pipeline inteiro (coleta → análise → ação).
3. **Política Locked ignorada**: Script pulava `Remove-AzStorageBlobImmutabilityPolicy` para políticas "Locked" (mesmo expiradas). Corrigido: remoção para AMBOS modos (Locked/Unlocked) quando expirada.

### 🟡 Correções de Scoping e Sessão
4. **Variáveis `$script:` em módulos dot-sourced**: Funções definidas em `lib/*.ps1` não conseguiam acessar `$script:VerboseProgress` etc. Corrigido: migração para `$global:ImmAuditCfg` (hashtable), `$global:ImmAuditStats`, `$global:ImmAuditResults`, `$global:ImmAuditContainerResults`.
5. **`$ErrorActionPreference = "Stop"` matava o script**: Erros em cmdlets do Azure propagavam além do try/catch. Corrigido: `-ErrorAction Stop` explícito nos cmdlets + tratamento de BlobNotFound (404) como não-erro.
6. **Confirmação case-sensitive**: `Read-Host` exigia `CONFIRMAR` maiúsculo exato. Corrigido: `-ine` (case-insensitive comparison).

### 🟢 Melhorias de Arquitetura
7. **Processamento página a página**: Eliminado o pattern "lista tudo, processa depois". Agora cada página de 5000 blobs é processada e blobs elegíveis são deletados **imediatamente** — sem esperar a listagem completa do container. Isso é crítico para containers com 40.000+ blobs.
8. **Paginação inline no main**: `Get-BlobsPaginated` (em `lib/BlobPagination.ps1`) foi substituído por loop de paginação direto no script principal, evitando problemas de pipeline/collect do PowerShell.
9. **Logs de deleção sempre visíveis**: `Write-Log` (não `Write-VerboseLog`) para passos [1/2] e [2/2] e `REMOVED:` — admin sempre vê o que está sendo deletado.
10. **Resumo por página**: Após cada página: `Página X: Y blobs | Expired: Z | Elegíveis: W | Removidos: N`.
11. **`Remove-AzStorageBlobImmutabilityPolicy` sem VersionId**: Parâmetros separados — `$policyParams` (sem VersionId) para remoção de política, `$deleteParams` (com VersionId) para deleção de blob.
12. **BlobNotFound tratado como não-erro**: Blobs já deletados (404) marcados como `AlreadyDeleted` sem incrementar contador de erros.

### Parâmetros Disponíveis
| Parâmetro | Tipo | Padrão | Descrição |
|-----------|------|--------|-----------|
| `-SubscriptionId` | string | Atual | Subscription Azure |
| `-ResourceGroupName` | string | Todos | Filtro por RG |
| `-StorageAccountName` | string | Todos | Filtro por Storage Account |
| `-ContainerName` | string | Todos | Filtro por container |
| `-DryRun` | switch | ✅ | Simulação (padrão) |
| `-RemoveBlobs` | switch | - | Remove blobs elegíveis |
| `-RemoveImmutabilityPolicyOnly` | switch | - | Remove só a política |
| `-OutputPath` | string | `./Reports` | Pasta dos relatórios |
| `-ExportCsv` | switch | - | Gera CSV adicional |
| `-IncludeSoftDeleted` | switch | - | Incluir soft-deleted |
| `-VerboseProgress` | switch | - | Logs detalhados |
| `-MaxDaysExpired` | int | 0 | Mínimo de dias expirados |
| `-MinAccountSizeTB` | int | 0 | Threshold de tamanho |
| `-PageSize` | int | 5000 | Blobs por página (100-5000) |

---

## v1.x (pré-modularização) — Script Monolítico

### Problemas Identificados na Auditoria
- Script único de 700+ linhas
- Paginação quebrada (só processava 5000 blobs)
- VersionId não propagado para deleção
- Política Locked tratada como não-removível
- ShouldProcess aninhado causava prompts duplos
- Modo padrão inconsistente (algumas versões defaultavam para RemoveBlobs)

### Lições Aprendidas
- PowerShell `$script:` scope não funciona bem entre arquivos dot-sourced — usar `$global:` com namespace (ex: `$global:ImmAuditCfg`)
- `$ErrorActionPreference = "Stop"` + cmdlets Azure = erros propagam além de try/catch — sempre usar `-ErrorAction Stop` explícito
- `Get-AzStorageBlob` retorna máximo 5000 por chamada independente do `-MaxCount`
- `Remove-AzStorageBlobImmutabilityPolicy` NÃO aceita `-VersionId` — opera na versão current
- Pipeline do PowerShell pode "coletar tudo" antes de iterar quando resultado é atribuído a variável — processar inline para containers grandes
- Aspas duplas dentro de strings interpoladas com `??` ou `?.` causam ParserError — usar if/else explícito

# Remove-ExpiredImmutableBlobs — Changelog

## v3.3.0 (2026-02-20) — Controle de memória e estabilidade em Windows

### Correções de estabilidade
- Mitigação de crescimento de memória em varreduras longas: resultados detalhados agora são limitados por `-MaxDetailedResults` (padrão 1000)
- Novo memory guard adaptativo para reduzir `PageSize` automaticamente quando o uso de memória do processo passa do limite configurado
- Ajuste automático de `PageSize` para `1000` em Windows com baixa RAM quando `-PageSize` não é informado

### Novos parâmetros
| Parâmetro | Tipo | Padrão | Descrição |
|-----------|------|--------|-----------|
| `-MaxDetailedResults` | int | 1000 | Limita linhas detalhadas retidas para relatório/CSV |
| `-MemoryUsageHighWatermarkPercent` | int | 90 | Percentual para acionar redução adaptativa de `PageSize` |
| `-MinAdaptivePageSize` | int | 1000 | Valor mínimo para `PageSize` na redução automática |
| `-DisableMemoryGuard` | switch | | Desativa ajuste automático por memória |

### Observabilidade
- Relatório HTML agora exibe observação quando o detalhamento for truncado por proteção de memória

---

## v3.2.0 (2026-02-20) — Estabilidade e desempenho

### Segurança operacional
- Suporte nativo a `-WhatIf` e `-Confirm` via `SupportsShouldProcess` (PowerShell common parameters)
- Novo parâmetro `-Force` para execução destrutiva não interativa (CI/automação)
- Prompt textual de confirmação mantido por padrão para reduzir risco operacional

### Autenticação e compatibilidade
- Fluxo de autenticação reforçado com fallback para `Connect-AzAccount -UseDeviceAuthentication`
- Compatível com PowerShell 7 em macOS e Windows sem dependência de shell específico
- `Set-AzContext -Scope Process` para evitar impacto no contexto global da sessão

### Resiliência e performance
- Retry com backoff exponencial para falhas transitórias (429, timeout, 5xx)
- Retry aplicado em listagem de blobs e operações de remoção (policy/blob)
- Redução de overhead de log em lotes grandes (amostragem por item fora do modo verbose)
- DryRun otimizado para processar elegíveis por página sem varredura cumulativa global

### Novos parâmetros
| Parâmetro | Tipo | Padrão | Descrição |
|-----------|------|--------|-----------|
| `-ExecutionProfile` | string | `Manual` | Presets: `Manual`, `Conservative`, `Balanced`, `Aggressive` |
| `-MaxRetryAttempts` | int | 3 | Tentativas máximas para falhas transitórias |
| `-RetryDelaySeconds` | int | 2 | Delay base do backoff exponencial |
| `-Force` | switch | | Pula prompt textual destrutivo |

### Presets de execução
- `Conservative`: `PageSize=1000`, `MaxRetryAttempts=5`, `RetryDelaySeconds=3`
- `Balanced`: `PageSize=2500`, `MaxRetryAttempts=4`, `RetryDelaySeconds=2`
- `Aggressive`: `PageSize=5000`, `MaxRetryAttempts=3`, `RetryDelaySeconds=1`

---

## v3.1.0 (2026-02-20) — UX Overhaul

### Melhorias de UX
- **Inline progress counter**: Fase de análise agora mostra uma única linha atualizando em tempo real em vez de imprimir uma linha `[EXPIRED]` por blob
  ```
  [ANALISANDO] Pág 1: 2847/5000 | Expirados: 1923 | Elegíveis: 1923 | Ativos: 0 | 142.3/s
  ```
- **Transição clara**: Mensagem explícita quando análise termina e remoção começa
  ```
  ► INICIANDO REMOÇÃO: 4800 blob(s) | 2.31 GB | Pág 1
  ```
- **Numeração de ações**: Cada remoção mostra `[N/total]` para acompanhamento
  ```
  [1/4800] REMOVED: 'backup/file.vbk' [v:2025-12-21T15:16] (143.89 KB)
  ```
- **Resumo por página**: Tempo de análise e contadores ao final de cada página

### Correções
- **Fix: ParserError `$pageNum:`**: PowerShell interpretava `$pageNum:` como namespace de variável. Corrigido para `${pageNum}:`
- **PageSize mínimo**: Reduzido de 100 para 10 (`[ValidateRange(10, 5000)]`) para facilitar testes
- **StackTrace em exceções**: Exceções a nível de conta agora mostram `$_.ScriptStackTrace` em vermelho
- **BlobNotFound silencioso**: Remoção de política para versões não-current não gera mais log `[D] [1/2]` verbose

### Removido
- Arquivo `Remove-ExpiredImmutableBlobs-debug.ps1` — funcionalidade de debug integrada na versão principal

---

## v3.0.0 (2026-02-20) — Refatoração completa (script único)

### Arquitetura
- Script monolítico sem dependências externas (eliminado `lib/` com módulos separados)
- Todas as funções inline — zero problemas de scoping `$script:` vs `$global:`

### Correções críticas
1. **Paginação**: `ContinuationToken` capturado do output RAW antes de transformar em array
2. **VersionId propagado**: `Remove-AzStorageBlob -VersionId` funciona corretamente para blobs versionados
3. **Política Locked/Unlocked**: Remoção para ambos modos quando expirada
4. **Processamento por página**: Cada página analisada + ações executadas imediatamente (não acumula entre páginas)
5. **BlobNotFound como não-erro**: 404 na deleção marcado como `AlreadyDeleted`
6. **Confirmação case-insensitive**: `-ine` para comparação

### Parâmetros
| Parâmetro | Tipo | Padrão | Descrição |
|-----------|------|--------|-----------|
| `-SubscriptionId` | string | Atual | Subscription Azure |
| `-ResourceGroupName` | string | Todos | Filtro por RG |
| `-StorageAccountName` | string | Todos | Filtro por SA |
| `-ContainerName` | string | Todos | Filtro por container |
| `-DryRun` | switch | ✅ | Simulação (padrão) |
| `-RemoveBlobs` | switch | | Remove blobs elegíveis |
| `-RemoveImmutabilityPolicyOnly` | switch | | Remove só a política |
| `-OutputPath` | string | `./Reports` | Pasta dos relatórios |
| `-ExportCsv` | switch | | Gera CSV adicional |
| `-VerboseProgress` | switch | | Logs detalhados |
| `-MaxDaysExpired` | int | 0 | Mínimo de dias expirados |
| `-MinAccountSizeTB` | int | 0 | Threshold de tamanho |
| `-PageSize` | int | 5000 | Blobs por página (10–5000) |

---

## v2.0.0 (2026-02-20) — Refatoração modular

- Estrutura `lib/` com módulos separados (Helpers, AzureDiscovery, BlobAnalysis, Reports)
- Problemas de scoping com `$script:` entre arquivos dot-sourced
- Migração para `$global:` com namespace
- Posteriormente abandonada em favor do script monolítico (v3.0)

---

## v1.x — Script original

- Script monolítico de 700+ linhas
- Problemas: paginação quebrada, VersionId não propagado, modo padrão inconsistente

---

## Problemas conhecidos

- `Remove-AzStorageBlobImmutabilityPolicy` não aceita `-VersionId` (limitação do SDK)
- `Get-AzStorageBlob -MaxCount` limitado a 5000 pelo servidor Azure
- Sem paralelismo na deleção (futuro: `-AsJob` ou `ForEach-Object -Parallel`)

## Backlog

- [ ] Paralelismo com throttle control para deleções
- [ ] Retry com backoff para 429/503
- [ ] Parâmetro `-MaxErrors` para abort
- [ ] Filtro por AccessTier e prefixo de blob
- [ ] Estimativa de custo economizado
- [ ] Log para arquivo (transcript)

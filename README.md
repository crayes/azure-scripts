# 🛡️ M365 Security Toolkit

**Conjunto de scripts PowerShell para auditoria, remediação e otimização de segurança em tenants Microsoft 365.**

[![PowerShell](https://img.shields.io/badge/PowerShell-7.0+-blue.svg)](https://github.com/PowerShell/PowerShell)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![M365](https://img.shields.io/badge/Microsoft%20365-Compatible-orange.svg)](https://www.microsoft.com/microsoft-365)

---

## 📋 Índice

- [Visão Geral](#-visão-geral)
- [Pré-requisitos](#-pré-requisitos)
- [Instalação](#-instalação)
- [Scripts Disponíveis](#-scripts-disponíveis)
- [Guia de Uso Rápido](#-guia-de-uso-rápido)
- [Workflow Recomendado](#-workflow-recomendado)
- [Licenças Necessárias](#-licenças-necessárias)
- [Suporte](#-suporte)

---

## 🎯 Visão Geral

Este toolkit foi desenvolvido para administradores de TI que gerenciam múltiplos tenants Microsoft 365 e precisam:

- **Auditar** configurações de segurança existentes
- **Identificar** vulnerabilidades e gaps de compliance
- **Remediar** problemas de forma automatizada
- **Documentar** o estado de segurança do ambiente

### 🖥️ Azure Scripts UI (Electron)

> Interface gráfica para executar scripts, configurar parâmetros e rodar fluxos multi‑tenant.

Principais recursos:
- Parâmetros dinâmicos e perfis por script
- Fluxos guiados (inclui multi‑tenant)
- Fila de execução e cancelamento
- Histórico com logs persistentes
- Organização automática de relatórios por tenant/data

Veja [azure-scripts-ui/README.md](azure-scripts-ui/README.md) para instalação e uso.

### ✨ Novidades v4.2

- **M365-Remediation.ps1 v4.2** - DLP Workload Coverage Repair: repara automaticamente políticas DLP com workloads faltantes
- **Purview-Audit-PS7.ps1 v4.1** - Análise granular de cobertura DLP por workload (Exchange, SharePoint, OneDrive, Teams)
- **Função `Repair-DLPWorkloadCoverage`** - Detecta e corrige políticas DLP com localizações faltantes
- **Parâmetros novos (v4.1.1):** `-TenantName`, `-SkipPurviewEvidence`, `-DryRun` (substituiu `-WhatIf`)
- **Fix (v4.1.1):** Funções renomeadas para verbos aprovados pelo PowerShell (zero warnings no PSScriptAnalyzer)
- **Fix (v4.1.1):** `-WarningAction SilentlyContinue` substituído por `3>$null` (imune a `$WarningPreference` corrompida)
- **Audit-ImplementedPolicies.ps1** - Audita o que JÁ está implementado e gera evidências prontas para o Purview Compliance Manager
- **Purview-Audit-PA-PS7.ps1** - Auditoria Purview + Power Platform DLP (macOS/Linux compatível)
- **PURVIEW-COMPLIANCE-GUIDE.md** - Guia completo para aumentar o Compliance Score
- **Detecção automática de licenças** - Scripts identificam E5/E3/Business Premium automaticamente
- **Score inteligente** - Calculado apenas com recursos disponíveis na licença
- **Zero erros de licença** - Pula automaticamente recursos não licenciados
- **Alertas adaptativos** - Usa alertas básicos ou avançados conforme licença

### Cenários de Uso

| Cenário | Scripts Recomendados |
|---------|---------------------|
| Novo tenant M365 | `Exchange-Audit.ps1` → `Purview-Audit-PS7.ps1` → `OneDrive-Complete-Audit.ps1` |
| Auditoria periódica | `Exchange-Audit.ps1` + `Purview-Audit-PS7.ps1` + `OneDrive-Complete-Audit.ps1` |
| Auditoria OneDrive/SharePoint | `OneDrive-Complete-Audit.ps1` + `REMEDIATION-CHECKLIST.md` |
| Pós-incidente de segurança | `Clean-InboxRules.ps1` + `Exchange-Audit.ps1` |
| Limpeza de dispositivos | `Remove-InactiveDevices.ps1` |
| Ambiente VDI | `Remove-InactiveDevices-AzureAutomation.ps1` |
| Manutenção Hybrid Identity | `Rotate-KerberosKey-SSO.ps1` |
| **Análise de Conditional Access** | `Analyze-CA-Policies.ps1` |
| **Troubleshooting erro 53003** | `Analyze-CA-Policies.ps1` |
| **Verificar capacidades do tenant** | `Get-TenantCapabilities.ps1` |
| **Aumentar Compliance Score** | `M365-Remediation.ps1 -TenantName "X"` (gera evidências automaticamente) |
| **Auditoria Purview + Power Platform** | `Purview-Audit-PA-PS7.ps1` |

---

## 📦 Pré-requisitos

### Software

```powershell
# PowerShell 7+ (recomendado)
winget install Microsoft.PowerShell

# Ou para Mac/Linux
brew install powershell/tap/powershell
```

### Módulos PowerShell

Os scripts Exchange v2.1+ **instalam módulos automaticamente** se necessário. Para instalação manual:

```powershell
# Exchange Online Management
Install-Module -Name ExchangeOnlineManagement -Force -AllowClobber

# Microsoft Graph (para scripts de dispositivos e Conditional Access)
Install-Module -Name Microsoft.Graph -Force -AllowClobber

# Verificar instalação
Get-InstalledModule ExchangeOnlineManagement, Microsoft.Graph
```

> **⚠️ Nota macOS/Linux:** Carregar EXO **antes** do Graph para evitar conflito MSAL. Use `pwsh -NoProfile` se necessário.

> **💡 Nota:** O script `OneDrive-Complete-Audit.ps1` usa REST API pura e **não requer módulos adicionais**.

### Permissões Necessárias

| Script | Permissões Azure AD/Entra ID |
|--------|-----------------------------|
| Exchange-Audit.ps1 | Global Reader, Exchange Administrator |
| Purview-Audit-PS7.ps1 | Compliance Administrator |
| Audit-ImplementedPolicies.ps1 | Compliance Admin + Policy.Read.All + Directory.Read.All |
| M365-Remediation.ps1 | Exchange Admin, Compliance Admin (+ Policy.Read.All para evidências CA) |
| Clean-InboxRules.ps1 | Exchange Administrator |
| Remove-InactiveDevices.ps1 | Cloud Device Administrator |
| Rotate-KerberosKey-SSO.ps1 | Global Admin ou Hybrid Identity Admin + Domain Admin local |
| OneDrive-Complete-Audit.ps1 | SharePoint Administrator ou Global Admin |
| **Analyze-CA-Policies.ps1** | **Policy.Read.All, Directory.Read.All** |

---

## 💾 Instalação

### Opção 1: Clone do Repositório

```bash
git clone https://github.com/crayes/azure-scripts.git
cd azure-scripts
```

### Opção 2: Download Direto

```powershell
# Download de um script específico
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/crayes/azure-scripts/main/scripts/Exchange/Exchange-Audit.ps1" -OutFile "Exchange-Audit.ps1"
```

---

## 📂 Scripts Disponíveis

### 🔍 Módulo de Detecção de Capacidades (v4.0)

> 📖 **Documentação completa:** [scripts/Modules/README.md](scripts/Modules/README.md)

#### `Get-TenantCapabilities.ps1` ⭐ NOVO
Detecta automaticamente as capacidades e licenças disponíveis no tenant:

- Identifica licença (E5, E3, Business Premium, Basic)
- Testa disponibilidade de cada recurso de compliance
- Retorna lista de itens auditáveis e remediáveis
- Usado automaticamente pelos scripts v4.0+

```powershell
# Uso standalone
./scripts/Modules/Get-TenantCapabilities.ps1

# Modo silencioso (retorna objeto)
$Caps = ./scripts/Modules/Get-TenantCapabilities.ps1 -Silent

# Verificar recurso específico
if ($Caps.Capabilities.DLP.Available) {
    Write-Host "DLP disponível!"
}

# Ver licença detectada
$Caps.License.Probable  # "Microsoft 365 E5 ou equivalente"
```

**Output visual:**
```
╔══════════════════════════════════════════════════════════════════╗
║  🔍 DETECTANDO CAPACIDADES DO TENANT                             ║
╚══════════════════════════════════════════════════════════════════╝

  Tenant: Rayes Fagundes Advogados Associados
  Domínio: rfaa.onmicrosoft.com
  Licença: Microsoft 365 E5 ou equivalente (Confiança: Alta)

  ┌────────────────────────────────┬────────────┬─────────────────────┐
  │ Recurso                        │ Status     │ Detalhes            │
  ├────────────────────────────────┼────────────┼─────────────────────┤
  │ DLP                            │ ✅ Disponível│ 3 políticas        │
  │ Sensitivity Labels             │ ✅ Disponível│ 5 labels           │
  │ Alert Policies (Advanced)      │ ✅ Disponível│                    │
  │ Insider Risk                   │ ✅ Disponível│ 0 políticas        │
  └────────────────────────────────┴────────────┴─────────────────────┘

  📋 PODE AUDITAR: DLP, SensitivityLabels, Retention, AlertPolicies
  🔧 PODE REMEDIAR: DLP, Retention, AlertPolicies, AuditLog
```

---

### ☁️ OneDrive / SharePoint Online

#### `OneDrive-Complete-Audit.ps1`
Auditoria completa de segurança do OneDrive for Business e SharePoint Online usando **REST API pura** (compatível com macOS, Windows e Linux):

- Configurações de compartilhamento externo
- Tipos e permissões de links padrão
- Expiração de links e usuários externos
- Restrições de sincronização
- Autenticação legacy
- Security Defaults e Conditional Access
- Proteção de dados (AIP/Sensitivity Labels)
- Relatório HTML interativo com priorização por risco

```powershell
# Execução básica
./scripts/OneDrive/OneDrive-Complete-Audit.ps1 -TenantName "contoso"

# Com pasta de saída customizada
./scripts/OneDrive/OneDrive-Complete-Audit.ps1 -TenantName "contoso" -OutputPath "./Relatorios"
```

**Saída:**
- `OneDrive-Audit-Findings_<timestamp>.csv` - Findings priorizados
- `OneDrive-Audit-AllSettings_<timestamp>.csv` - Todas configurações coletadas
- `OneDrive-Complete-Audit-Report_<timestamp>.html` - Relatório visual

**⚠️ Importante:** A remediação deve ser feita **manualmente** no SharePoint Admin Center. Consulte o arquivo `REMEDIATION-CHECKLIST.md` para instruções detalhadas.

#### `REMEDIATION-CHECKLIST.md`
Checklist completo para aplicar correções de segurança no SharePoint Admin Center:
- 🔴 Itens críticos (corrigir imediatamente)
- 🟠 Itens altos (corrigir em 1-2 semanas)
- 🟡 Itens médios (avaliar em 1 mês)
- 🔵 Itens baixos (melhorias recomendadas)

---

### 📧 Exchange Online

> 📖 **Documentação completa:** [scripts/Exchange/README.md](scripts/Exchange/README.md)

#### `Exchange-Audit.ps1` (v2.1)
Auditoria completa do Exchange Online incluindo:
- Verificação SPF, DKIM, DMARC
- Análise de regras de transporte
- Detecção de forwarding externo
- Políticas anti-spam e anti-malware
- Conectores e configurações de segurança

**Novidades v2.1:**
- ✅ Verificação automática de módulos (instala/atualiza automaticamente)
- ✅ Limpeza de módulos duplicados (conflitos MSAL)
- ✅ Mantém conexão ativa ao finalizar

```powershell
# Execução básica (instala módulos automaticamente se necessário)
./scripts/Exchange/Exchange-Audit.ps1

# Apenas relatório
./scripts/Exchange/Exchange-Audit.ps1 -ReportOnly

# Especificar caminho do relatório
./scripts/Exchange/Exchange-Audit.ps1 -ExportPath "C:\Reports\audit.csv"
```

#### `Clean-InboxRules.ps1` (v2.1)
Identifica e remove regras de inbox problemáticas:
- Regras com pastas deletadas
- Regras com destinatários inexistentes
- Regras potencialmente maliciosas

**Novidades v2.1:**
- ✅ Verificação automática de módulos (instala/atualiza automaticamente)
- ✅ Limpeza de módulos duplicados (conflitos MSAL)
- ✅ Mantém conexão ativa ao finalizar

```powershell
# Apenas relatório (não remove nada)
./scripts/Exchange/Clean-InboxRules.ps1 -ReportOnly

# Remoção interativa
./scripts/Exchange/Clean-InboxRules.ps1

# Remoção automática de todas
./scripts/Exchange/Clean-InboxRules.ps1 -RemoveAll
```

**💡 Dica:** Os scripts v2.1 mantêm a conexão ativa. Para desconectar manualmente:
```powershell
Disconnect-ExchangeOnline -Confirm:$false
```

---

### 🛡️ Microsoft Purview

#### `Audit-ImplementedPolicies.ps1` (v1.0)
Audita todas as políticas JÁ implementadas no tenant e gera evidências prontas para copiar/colar no **Purview Compliance Manager**:

- Conditional Access (MFA, Legacy Auth Block, Geo-Block, Compliant Device)
- DLP Policies
- Sensitivity Labels e Label Policies
- Retention Policies
- Safe Links / Safe Attachments / Anti-Phishing
- Audit Log & Mailbox Audit
- Transport Rules (Mail Flow)
- DKIM Signing

> **💡 Nota:** A funcionalidade de geração de evidências agora também está integrada no `M365-Remediation.ps1` v4.1.1 (via `Export-PurviewEvidence`). Use o `Audit-ImplementedPolicies.ps1` para auditoria standalone, ou rode `M365-Remediation.ps1 -TenantName "X"` para remediar + gerar evidências em um único passo.

```powershell
# Auditoria completa
pwsh ./scripts/Purview/Audit-ImplementedPolicies.ps1 -TenantName "MeuCliente"

# Se já estiver conectado
pwsh ./scripts/Purview/Audit-ImplementedPolicies.ps1 -TenantName "MeuCliente" -SkipConnection

# Multi-tenant
foreach ($cliente in @("RFAA", "ClienteB", "ClienteC")) {
    ./scripts/Purview/Audit-ImplementedPolicies.ps1 -TenantName $cliente
}
```

**Saída:**
- `purview-evidence.csv` - Evidências prontas para o Purview
- `purview-evidence.json` - Dados estruturados
- `EVIDENCE-REPORT.md` - Relatório markdown

Veja o [PURVIEW-COMPLIANCE-GUIDE.md](scripts/Purview/PURVIEW-COMPLIANCE-GUIDE.md) para o workflow completo.

---

#### `Purview-Audit-PA-PS7.ps1` (v4.1)
Versão estendida do Purview-Audit com **auditoria de DLP do Power Platform** (Power Automate/Power Apps):

- Tudo do Purview-Audit-PS7.ps1 +
- Ambientes Power Platform
- Políticas DLP do Power Platform
- Conectores de alto risco
- Compatível com macOS/Linux via PAC CLI

```powershell
# Execução padrão
pwsh ./scripts/Purview/Purview-Audit-PA-PS7.ps1

# macOS/Linux (requer PAC CLI)
dotnet tool install -g Microsoft.PowerApps.CLI.Tool
pwsh ./scripts/Purview/Purview-Audit-PA-PS7.ps1
```

---

#### `Purview-Audit-PS7.ps1` (v4.1)
Auditoria abrangente do Microsoft Purview com **detecção automática de capacidades**:

- Políticas DLP
- Configurações de Audit Log
- Políticas de retenção
- Labels de sensibilidade
- Alertas de segurança
- Insider Risk Management
- eDiscovery
- Communication Compliance

**Novidades v4.1:**
- ✅ **Análise granular de DLP por workload** - Distingue políticas custom vs default/sistema
- ✅ **Verificação de cobertura completa** - Identifica políticas DLP faltando Exchange/SharePoint/OneDrive/Teams
- ✅ **Score DLP inteligente** - Não penaliza quando políticas custom cobrem todos os workloads
- ✅ **Recomendações direcionadas** - Aponta para `M365-Remediation.ps1 -OnlyDLP` quando há gaps

**Novidades v4.0:**
- ✅ **Detecção automática de licença** - Identifica E5/E3/Business automaticamente
- ✅ **Score inteligente** - Calculado apenas com recursos DISPONÍVEIS
- ✅ **Sem erros de licença** - Pula seções não licenciadas automaticamente
- ✅ **Relatório claro** - Mostra o que foi auditado vs pulado
- ✅ Integração com `Get-TenantCapabilities.ps1`

```powershell
# Execução padrão (detecta capacidades automaticamente)
./scripts/Purview/Purview-Audit-PS7.ps1

# Se já estiver conectado
./scripts/Purview/Purview-Audit-PS7.ps1 -SkipConnection

# Pular detecção de capacidades (tenta auditar tudo)
./scripts/Purview/Purview-Audit-PS7.ps1 -SkipCapabilityCheck

# Com pasta de saída customizada
./scripts/Purview/Purview-Audit-PS7.ps1 -OutputPath "./MeuRelatorio"
```

**Output v4.0:**
```
  📊 SCORES POR CATEGORIA
  ─────────────────────────────────────────────
  Data Loss Prevention          [████████████████████] 95%
  Unified Audit Log             [████████████████████] 100%
  Políticas de Retenção         [████████████░░░░░░░░] 60%
  Labels de Sensibilidade       [████████████████████] 100%
  Insider Risk                  [░░░░░░░░░░░░░░░░░░░░] N/A (não licenciado)
  ─────────────────────────────────────────────
  SCORE GERAL (licenciados)     [████████████████░░░░] 89%

  ⏭️  CATEGORIAS PULADAS (não licenciadas):
     InsiderRisk, CommunicationCompliance
```

**Saída:**
- `audit-results.json` - Dados estruturados com info de licença
- `recommendations.csv` - Lista de recomendações priorizadas
- `SUMMARY.md` - Relatório markdown

---

### 🔧 Remediação

#### `M365-Remediation.ps1` (v4.2) ⭐ ATUALIZADO
Aplica configurações de segurança recomendadas com **detecção automática de capacidades** e **geração de evidências para o Purview Compliance Manager**:

- ✅ Ativa Unified Audit Log
- ✅ Configura Mailbox Audit
- ✅ Cria políticas de Retenção (se licenciado)
- ✅ Cria políticas DLP para dados brasileiros (CPF, CNPJ) (se licenciado)
- ✅ **Repara políticas DLP existentes** - Adiciona workloads faltantes (Exchange/SharePoint/OneDrive/Teams)
- ✅ Desabilita provedores externos no OWA (opcional)
- ✅ Configura alertas de segurança (básicos ou avançados conforme licença)
- ✅ **Gera evidências Purview** (DLP, Labels, Retention, Audit, ATP, Transport Rules, DKIM, CA)

**Novidades v4.2:**
- ✅ **DLP Workload Coverage Repair** - Verifica e corrige automaticamente políticas DLP com cobertura incompleta
- ✅ **Função `Repair-DLPWorkloadCoverage`** - Adiciona locations faltantes usando `Set-DlpCompliancePolicy`
- ✅ **Análise granular** - Identifica quais workloads estão faltando em cada política
- ✅ **Compatível com `-DryRun`** - Simula correções sem aplicar

**Novidades v4.1.1:**
- ✅ **Purview Evidence integrado** - Coleta evidências de todas as políticas implementadas e gera CSV/JSON/Markdown
- ✅ **Parâmetro `-TenantName`** - Identificação nos relatórios de evidência
- ✅ **Parâmetro `-DryRun`** - Modo simulação (substituiu `-WhatIf`)
- ✅ **Parâmetro `-SkipPurviewEvidence`** - Pula geração de evidências
- ✅ **Verbos aprovados** - Zero warnings no PSScriptAnalyzer
- ✅ **Resiliente a `$WarningPreference`** - Usa `3>$null` em vez de `-WarningAction`

**Novidades v4.0:**
- ✅ **Detecção automática de licença** - Não tenta criar DLP em tenant sem licença
- ✅ **Alertas adaptativos** - Usa `AggregationType=None` (básico) ou `SimpleAggregation` (E5)
- ✅ **Relatório HTML** - Gera relatório final em HTML

```powershell
# Execução padrão (remediação + evidências Purview)
./scripts/Remediation/M365-Remediation.ps1 -TenantName "RFAA"

# Se já estiver conectado
./scripts/Remediation/M365-Remediation.ps1 -SkipConnection -TenantName "RFAA"

# DLP em modo auditoria (não bloqueia, só reporta)
./scripts/Remediation/M365-Remediation.ps1 -DLPAuditOnly -TenantName "RFAA"

# Pular alerta de forwarding (pode gerar falsos positivos)
./scripts/Remediation/M365-Remediation.ps1 -SkipForwardingAlert

# Não bloquear Dropbox/Google Drive no OWA
./scripts/Remediation/M365-Remediation.ps1 -SkipOWABlock

# Modo simulação (não faz alterações)
./scripts/Remediation/M365-Remediation.ps1 -DryRun -TenantName "RFAA"

# Pular geração de evidências Purview
./scripts/Remediation/M365-Remediation.ps1 -SkipPurviewEvidence

# Combinado
./scripts/Remediation/M365-Remediation.ps1 -SkipConnection -DLPAuditOnly -SkipForwardingAlert -TenantName "RFAA"
```

**Saída:**
- `M365-Remediation-Backup_<timestamp>.json` - Backup das configurações alteradas
- `M365-Remediation-Report_<timestamp>.html` - Relatório visual com status, itens pulados e alterações
- `Purview-Evidence_<TenantName>_<timestamp>/purview-evidence.csv` - Evidências para Purview
- `Purview-Evidence_<TenantName>_<timestamp>/purview-evidence.json` - Dados estruturados
- `Purview-Evidence_<TenantName>_<timestamp>/EVIDENCE-REPORT.md` - Relatório markdown

**⚠️ Importante:** Execute sempre a auditoria antes da remediação!

> **💡 Dica macOS/Linux:** Use `pwsh -NoProfile` para evitar conflito MSAL entre EXO e Graph. Carregue EXO antes do Graph.

---

### 💻 Entra ID / Dispositivos / Conditional Access

#### `Analyze-CA-Policies.ps1`
Análise detalhada de todas as políticas de Conditional Access do tenant:

- Lista todas as políticas com estado (Ativo/Desativado/Report-Only)
- Mostra ações de cada política (Block, MFA, Compliant Device, etc.)
- Exibe apps e usuários incluídos/excluídos
- Lista Named Locations (países e IP ranges)
- Identifica condições de risco (Sign-in Risk, User Risk)
- Mostra Client App Types e Session Controls

**Ideal para:**
- 🔍 Troubleshooting de erro **53003 (BlockedByConditionalAccess)**
- 📋 Documentação de políticas existentes
- 🧹 Identificação de políticas duplicadas ou conflitantes
- ✅ Auditoria de segurança do tenant

```powershell
# Execução básica
./scripts/EntraID/Analyze-CA-Policies.ps1 -TenantId "contoso.onmicrosoft.com"

# Usando Tenant ID (GUID)
./scripts/EntraID/Analyze-CA-Policies.ps1 -TenantId "12345678-1234-1234-1234-123456789012"
```

**Permissões necessárias:**
- `Policy.Read.All`
- `Directory.Read.All`

#### `Remove-InactiveDevices.ps1`
Gerenciamento de dispositivos inativos no Entra ID:
- Lista dispositivos sem atividade
- Gera relatórios CSV e HTML
- Remove dispositivos com confirmação

```powershell
# Listar dispositivos inativos (6 meses padrão)
./scripts/EntraID/Remove-InactiveDevices.ps1 -TenantId "contoso.com"

# Customizar período (3 meses)
./scripts/EntraID/Remove-InactiveDevices.ps1 -TenantId "contoso.com" -MonthsInactive 3

# Apenas exportar relatório
./scripts/EntraID/Remove-InactiveDevices.ps1 -TenantId "contoso.com" -ExportOnly

# Remover dispositivos (requer confirmação)
./scripts/EntraID/Remove-InactiveDevices.ps1 -TenantId "contoso.com" -Delete
```

#### `Remove-InactiveDevices-AzureAutomation.ps1`
Versão para Azure Automation com Managed Identity:
- Ideal para execução agendada
- Perfeito para ambientes VDI
- Suporte a notificações por email

---

### 🔐 Hybrid Identity / Entra Connect

#### `Rotate-KerberosKey-SSO.ps1`
Rotação da chave Kerberos para Seamless SSO do Azure AD Connect:
- Verifica status da conta AZUREADSSOACC
- Mostra dias desde última rotação
- Executa rotação com confirmação
- Gera log de todas operações

**⚠️ Executar no servidor Azure AD Connect como Administrador!**

```powershell
# Apenas verificar status (não altera nada)
./scripts/HybridIdentity/Rotate-KerberosKey-SSO.ps1 -CheckOnly

# Executar rotação com confirmação
./scripts/HybridIdentity/Rotate-KerberosKey-SSO.ps1

# Executar rotação sem confirmação (automação)
./scripts/HybridIdentity/Rotate-KerberosKey-SSO.ps1 -SkipConfirmation
```

**Recomendação Microsoft:** Rotacionar a cada 30 dias.

---

### 🌐 DNS

#### `check-dns.sh`
Verificação de registros DNS para autenticação de email:
- SPF
- DKIM (selectores Microsoft)
- DMARC
- MX Records

```bash
# Editar domínios no script
DOMAINS=("seudominio.com.br" "outrodominio.com")

# Executar
chmod +x ./scripts/DNS/check-dns.sh
./scripts/DNS/check-dns.sh
```

---

## 🚀 Guia de Uso Rápido

### Primeira Execução em Novo Tenant

```powershell
# 1. Conectar aos serviços (carregar EXO ANTES do Graph em macOS)
Connect-ExchangeOnline
Connect-IPPSSession

# 2. Verificar capacidades do tenant (opcional, v4.0+ faz automaticamente)
./scripts/Modules/Get-TenantCapabilities.ps1

# 3. Analisar políticas de Conditional Access
Connect-MgGraph -Scopes "Policy.Read.All"
./scripts/EntraID/Analyze-CA-Policies.ps1 -TenantId "contoso.onmicrosoft.com"

# 4. Auditoria OneDrive/SharePoint
./scripts/OneDrive/OneDrive-Complete-Audit.ps1 -TenantName "contoso"

# 5. Auditoria Exchange
./scripts/Exchange/Exchange-Audit.ps1

# 6. Auditoria Purview (v4.0 - detecta licença automaticamente)
./scripts/Purview/Purview-Audit-PS7.ps1 -SkipConnection

# 7. Revisar relatórios gerados

# 8. Aplicar remediações + gerar evidências Purview
./scripts/Remediation/M365-Remediation.ps1 -SkipConnection -TenantName "contoso"

# 9. Aplicar remediações do OneDrive (manual)
# Seguir REMEDIATION-CHECKLIST.md no SharePoint Admin Center

# 10. Ativar auto-testing no Purview Compliance Manager
# https://compliance.microsoft.com → Settings → Compliance Manager → Testing source

# 11. Desconectar
Disconnect-ExchangeOnline -Confirm:$false
Disconnect-MgGraph
```

### Tenant com Licença Limitada (E3/Business)

```powershell
# Os scripts v4.0+ detectam automaticamente e pulam recursos não licenciados
./scripts/Purview/Purview-Audit-PS7.ps1 -SkipConnection
# Output: InsiderRisk → "N/A (não licenciado)"
# Score calculado apenas com recursos disponíveis

./scripts/Remediation/M365-Remediation.ps1 -SkipConnection -TenantName "MeuTenant"
# Output: Cria recursos disponíveis + gera evidências Purview
```

### Troubleshooting Erro 53003 (BlockedByConditionalAccess)

```powershell
# 1. Analisar todas as políticas do tenant
./scripts/EntraID/Analyze-CA-Policies.ps1 -TenantId "contoso.onmicrosoft.com"

# 2. Identificar políticas que podem estar bloqueando:
#    - Políticas com AÇÃO: BLOQUEIA acesso
#    - Políticas de geo-fencing (Named Locations com países)
#    - Políticas que bloqueiam legacy auth (Exchange ActiveSync)
#    - Políticas que exigem dispositivo gerenciado

# 3. Causas comuns do erro 53003:
#    - VPN roteando por país não permitido
#    - Apple Mail usando Exchange ActiveSync (legacy auth)
#    - Dispositivo não registrado no Intune
#    - iCloud Private Relay ativo
```

---

## 📊 Workflow Recomendado

```
┌─────────────────────────────────────────────────────────────────┐
│                    WORKFLOW DE SEGURANÇA M365                    │
└─────────────────────────────────────────────────────────────────┘

    ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
    │   AUDITORIA  │────▶│   ANÁLISE    │────▶│  REMEDIAÇÃO  │
    └──────────────┘     └──────────────┘     └──────────────┘
           │                    │                    │
           ▼                    ▼                    ▼
    Exchange-Audit      Revisar JSON/CSV     M365-Remediation
    Purview-Audit v4.0  Priorizar issues     + Purview Evidence
    OneDrive-Audit      Documentar gaps      SPO Admin Center
    CA-Policies-Audit   Analyze-CA output    Remove-Devices
    TenantCapabilities                       
           │                    │                    │
           └────────────────────┼────────────────────┘
                               ▼
                    ┌──────────────────┐
                    │    MONITORAR     │
                    │   (Mensal/Trim)  │
                    └──────────────────┘
```

---

## 📜 Licenças Microsoft Necessárias

### Compatibilidade dos Scripts v4.0+

| Recurso | E5 | E3 | Business Premium | Basic |
|---------|:--:|:--:|:----------------:|:-----:|
| Unified Audit Log | ✅ | ✅ | ✅ | ❌ |
| Mailbox Audit | ✅ | ✅ | ✅ | ✅ |
| DLP Policies | ✅ | ❌ | ❌ | ❌ |
| Retention Policies | ✅ | ✅ | ✅ | ❌ |
| Sensitivity Labels | ✅ | ✅ | ✅ | ❌ |
| Alertas Avançados | ✅ | ❌ | ❌ | ❌ |
| Alertas Básicos | ✅ | ✅ | ✅ | ✅ |
| Insider Risk | ✅ | ❌ | ❌ | ❌ |
| Communication Compliance | ✅ | ❌ | ❌ | ❌ |
| eDiscovery Premium | ✅ | ❌ | ❌ | ❌ |
| eDiscovery Standard | ✅ | ✅ | ❌ | ❌ |
| **Purview Evidence (M365-Remediation)** | ✅ | ✅ | ✅ | ⚠️ |

> **💡 Nota:** Os scripts v4.0+ detectam automaticamente a licença e pulam recursos não disponíveis.

### Permissões por Script

| Script | Permissões Necessárias |
|--------|-----------------------|
| Purview-Audit-PS7.ps1 | Compliance Administrator |
| M365-Remediation.ps1 | Exchange Admin + Compliance Admin (+ Policy.Read.All para CA evidence) |
| Get-TenantCapabilities.ps1 | Compliance Reader ou superior |
| Exchange-Audit.ps1 | Global Reader, Exchange Administrator |
| OneDrive-Complete-Audit.ps1 | SharePoint Administrator |
| Analyze-CA-Policies.ps1 | Policy.Read.All, Directory.Read.All |

---

## 🤝 Contribuições

Contribuições são bem-vindas! Por favor:

1. Fork o repositório
2. Crie uma branch (`git checkout -b feature/NovoScript`)
3. Commit suas mudanças (`git commit -am 'Add: novo script'`)
4. Push para a branch (`git push origin feature/NovoScript`)
5. Abra um Pull Request

---

## 📝 Changelog

### v4.2 - Fevereiro 2026 ⭐ ATUAL
- ✨ **M365-Remediation.ps1 v4.2** - DLP Workload Coverage Repair
  - Nova função `Repair-DLPWorkloadCoverage` que verifica e corrige automaticamente políticas DLP com workloads faltantes
  - Análise granular de cobertura por workload (Exchange, SharePoint, OneDrive, Teams)
  - Usa `Set-DlpCompliancePolicy` para adicionar locations faltantes
  - Compatível com modo `-DryRun` para simulação
- ✨ **Purview-Audit-PS7.ps1 v4.1** - Análise granular de cobertura DLP
  - Distingue políticas custom vs default/sistema
  - Verifica ExchangeLocation/SharePointLocation/OneDriveLocation/TeamsLocation
  - Score DLP não penaliza quando políticas custom cobrem todos os workloads
  - Detalhe por workload mostrando quais políticas cobrem cada um
  - Recomendação aponta para `M365-Remediation.ps1 -OnlyDLP`

### v4.1.1 - Fevereiro 2026
- 🔧 **Fix:** Funções renomeadas para verbos aprovados (Remediate-* → Repair-*, Generate-HTMLReport → New-HTMLReport)
- 🔧 **Fix:** `-WarningAction SilentlyContinue` → `3>$null` (previne crash de ActionPreference)
- 🔧 **Fix:** `-WhatIf` renomeado para `-DryRun` (evita conflito com SupportsShouldProcess)
- 📋 Zero warnings no PSScriptAnalyzer

### v4.1 - Fevereiro 2026
- ✨ **Novo:** `Export-PurviewEvidence` integrado no `M365-Remediation.ps1` - Gera evidências CSV/JSON/MD após remediação
- ✨ **Novo:** Parâmetros `-TenantName`, `-SkipPurviewEvidence`, `-DryRun`
- ✨ **Novo:** `Audit-ImplementedPolicies.ps1` - Audita políticas já implementadas para Purview Compliance Manager
- ✨ **Novo:** `Purview-Audit-PA-PS7.ps1` - Auditoria Purview + Power Platform DLP
- ✨ **Novo:** `PURVIEW-COMPLIANCE-GUIDE.md` - Guia para aumentar Compliance Score
- 🗑️ **Removido:** `Update-PurviewComplianceActions.ps1` (funcionalidade integrada no M365-Remediation + auto-testing Purview)
- 🔧 Todos os scripts agora multi-tenant (sem branding hardcoded)
- 📋 README completamente atualizado

### v4.0 - Janeiro 2026
- ✨ **Novo:** `Get-TenantCapabilities.ps1` - Detecta licenças e capacidades automaticamente
- ✨ **Novo:** `M365-TenantCapabilities.psm1` - Módulo importável
- 🔧 **Atualizado:** `Purview-Audit-PS7.ps1` v4.0 - Integração com detecção de capacidades
- 🔧 **Atualizado:** `M365-Remediation.ps1` v4.0 - Adapta remediações à licença
- 📊 Score calculado apenas com recursos licenciados
- ⏭️ Pula automaticamente recursos não disponíveis
- 🔔 Alertas adaptativos (básicos vs avançados)
- 📋 Relatórios claros do que foi auditado/remediado vs pulado

### v2.3 - Janeiro 2026
- ✨ **Novo:** `Analyze-CA-Policies.ps1` - Análise detalhada de Conditional Access
- 🔍 Ferramenta para troubleshooting de erro 53003
- 📋 Lista políticas, Named Locations, Grant Controls e Session Controls
- 🎨 Output colorido com estados (Ativo/Desativado/Report-Only)
- 📖 Documentação atualizada com guia de troubleshooting

### v2.2 - Janeiro 2026
- ✨ Novo: `OneDrive-Complete-Audit.ps1` - Auditoria de segurança do OneDrive/SharePoint
- ✨ Novo: `REMEDIATION-CHECKLIST.md` - Checklist de remediação manual
- 📁 Nova pasta: OneDrive
- 🔧 REST API pura - Compatível com macOS/Windows/Linux sem módulos adicionais

### v2.1 - Janeiro 2026
- 🔧 `Exchange-Audit.ps1` - Verificação automática de módulos, mantém conexão ativa
- 🔧 `Clean-InboxRules.ps1` - Verificação automática de módulos, mantém conexão ativa
- 🧹 Limpeza automática de módulos duplicados (conflitos MSAL)
- ✨ Novo: Script de rotação Kerberos para Seamless SSO
- 📁 Nova pasta: HybridIdentity
- 📖 Nova documentação: `scripts/Exchange/README.md`

### v2.0 - Janeiro 2026
- ✨ Compatibilidade com PowerShell 7 (Mac/Linux)
- 🔧 Novos scripts de remediação
- 📊 Relatórios HTML aprimorados
- 🛡️ Scripts de gestão de dispositivos

---

## 📄 Licença

Este projeto está licenciado sob a MIT License - veja o arquivo [LICENSE](LICENSE) para detalhes.

---

## 👨‍💻 Autor

**Celso N Rayes** // **Atsi Informatica**

Desenvolvido para administração de múltiplos tenants Microsoft 365.

**Contato:** Abra uma issue para dúvidas ou sugestões.

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

### ✨ Novidades v4.0

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

> **💡 Nota:** O script `OneDrive-Complete-Audit.ps1` usa REST API pura e **não requer módulos adicionais**.

### Permissões Necessárias

| Script | Permissões Azure AD/Entra ID |
|--------|-----------------------------|
| Exchange-Audit.ps1 | Global Reader, Exchange Administrator |
| Purview-Audit-PS7.ps1 | Compliance Administrator |
| M365-Remediation.ps1 | Exchange Administrator, Compliance Administrator |
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
- Usado automaticamente pelos scripts v4.0

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

#### `Purview-Audit-PS7.ps1` (v4.0) ⭐ ATUALIZADO
Auditoria abrangente do Microsoft Purview com **detecção automática de capacidades**:

- Políticas DLP
- Configurações de Audit Log
- Políticas de retenção
- Labels de sensibilidade
- Alertas de segurança
- Insider Risk Management
- eDiscovery
- Communication Compliance

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

#### `M365-Remediation.ps1` (v4.0) ⭐ ATUALIZADO
Aplica configurações de segurança recomendadas com **detecção automática de capacidades**:

- ✅ Ativa Unified Audit Log
- ✅ Configura Mailbox Audit
- ✅ Cria políticas de Retenção (se licenciado)
- ✅ Cria políticas DLP para dados brasileiros (CPF, CNPJ) (se licenciado)
- ✅ Desabilita provedores externos no OWA (opcional)
- ✅ Configura alertas de segurança (básicos ou avançados conforme licença)

**Novidades v4.0:**
- ✅ **Detecção automática de licença** - Não tenta criar DLP em tenant sem licença
- ✅ **Alertas adaptativos** - Usa `AggregationType=None` (básico) ou `SimpleAggregation` (E5)
- ✅ **Sem erros de licença** - Pula remediações não disponíveis
- ✅ **Relatório claro** - Mostra o que foi remediado vs pulado
- ✅ Integração com `Get-TenantCapabilities.ps1`

```powershell
# Execução padrão (detecta capacidades automaticamente)
./scripts/Remediation/M365-Remediation.ps1

# Se já estiver conectado
./scripts/Remediation/M365-Remediation.ps1 -SkipConnection

# DLP em modo auditoria (não bloqueia, só reporta)
./scripts/Remediation/M365-Remediation.ps1 -DLPAuditOnly

# Pular alerta de forwarding (pode gerar falsos positivos)
./scripts/Remediation/M365-Remediation.ps1 -SkipForwardingAlert

# Não bloquear Dropbox/Google Drive no OWA
./scripts/Remediation/M365-Remediation.ps1 -SkipOWABlock

# Modo simulação (não faz alterações)
./scripts/Remediation/M365-Remediation.ps1 -WhatIf

# Combinado
./scripts/Remediation/M365-Remediation.ps1 -SkipConnection -DLPAuditOnly -SkipForwardingAlert
```

**Output v4.0 em tenant sem E5:**
```
═══════════════════════════════════════════════════════════════════
  🔍  DETECTANDO CAPACIDADES DO TENANT
═══════════════════════════════════════════════════════════════════
  ✅ Tenant: ATSI Tecnologia
  📋 Licença: Microsoft 365 Business Premium
  📋 Pode remediar: AuditLog, Retention, AlertPolicies (básicos)

═══════════════════════════════════════════════════════════════════
  3️⃣  POLÍTICAS DLP
═══════════════════════════════════════════════════════════════════
  ⏭️  DLP não disponível neste tenant (licença não inclui)
```

**⚠️ Importante:** Execute sempre a auditoria antes da remediação!

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
# 1. Conectar aos serviços
Connect-ExchangeOnline
Connect-IPPSSession

# 2. Verificar capacidades do tenant (opcional, v4.0 faz automaticamente)
./scripts/Modules/Get-TenantCapabilities.ps1

# 3. Analisar políticas de Conditional Access
./scripts/EntraID/Analyze-CA-Policies.ps1 -TenantId "contoso.onmicrosoft.com"

# 4. Auditoria OneDrive/SharePoint
./scripts/OneDrive/OneDrive-Complete-Audit.ps1 -TenantName "contoso"

# 5. Auditoria Exchange
./scripts/Exchange/Exchange-Audit.ps1

# 6. Auditoria Purview (v4.0 - detecta licença automaticamente)
./scripts/Purview/Purview-Audit-PS7.ps1 -SkipConnection

# 7. Revisar relatórios gerados

# 8. Aplicar remediações (v4.0 - adapta à licença)
./scripts/Remediation/M365-Remediation.ps1 -SkipConnection

# 9. Aplicar remediações do OneDrive (manual)
# Seguir REMEDIATION-CHECKLIST.md no SharePoint Admin Center

# 10. Desconectar
Disconnect-ExchangeOnline -Confirm:$false
```

### Tenant com Licença Limitada (E3/Business)

```powershell
# Os scripts v4.0 detectam automaticamente e pulam recursos não licenciados
./scripts/Purview/Purview-Audit-PS7.ps1 -SkipConnection
# Output: DLP, InsiderRisk → "N/A (não licenciado)"
# Score calculado apenas com recursos disponíveis

./scripts/Remediation/M365-Remediation.ps1 -SkipConnection
# Output: "⏭️ DLP não disponível neste tenant (licença não inclui)"
# Cria apenas recursos disponíveis (Retention, Alertas básicos)
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
    Purview-Audit v4.0  Priorizar issues     (adapta à licença)
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

### Compatibilidade dos Scripts v4.0

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

> **💡 Nota:** Os scripts v4.0 detectam automaticamente a licença e pulam recursos não disponíveis.

### Permissões por Script

| Script | Permissões Necessárias |
|--------|-----------------------|
| Purview-Audit-PS7.ps1 | Compliance Administrator |
| M365-Remediation.ps1 | Exchange Admin + Compliance Admin |
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

### v4.0 - Janeiro 2026 ⭐ ATUAL
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

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

# Microsoft Graph (para scripts de dispositivos)
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

#### `Purview-Audit-PS7.ps1`
Auditoria abrangente do Microsoft Purview:
- Políticas DLP
- Configurações de Audit Log
- Políticas de retenção
- Labels de sensibilidade
- Alertas de segurança
- Safe Links e Safe Attachments

```powershell
# Execução padrão
./scripts/Purview/Purview-Audit-PS7.ps1

# Com pasta de saída customizada
./scripts/Purview/Purview-Audit-PS7.ps1 -OutputPath "./MeuRelatorio"
```

**Saída:**
- `audit-results.json` - Dados estruturados
- `recommendations.csv` - Lista de recomendações priorizadas

---

### 🔧 Remediação

#### `M365-Remediation.ps1`
Aplica configurações de segurança recomendadas:
- ✅ Ativa Unified Audit Log
- ✅ Desabilita provedores externos no OWA
- ✅ Cria políticas DLP para dados brasileiros (CPF, CNPJ, RG)
- ✅ Configura alertas de segurança

```powershell
# Execução com backup automático
./scripts/Remediation/M365-Remediation.ps1

# O script cria backup antes de cada alteração
# Backup salvo em: ./M365-Backup_YYYYMMDD_HHMMSS.json
```

**⚠️ Importante:** Execute sempre a auditoria antes da remediação!

---

### 💻 Entra ID / Dispositivos

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

```powershell
# Configurar no Azure Automation:
# 1. Criar Automation Account
# 2. Habilitar System Managed Identity
# 3. Atribuir permissão Device.ReadWrite.All no Graph
# 4. Importar runbook
# 5. Agendar execução semanal/mensal
```

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

**Pré-requisitos:**
- Executar no servidor Azure AD Connect
- Conta Global Admin ou Hybrid Identity Admin no Entra ID
- Conta Domain Admin no AD local
- Módulo ActiveDirectory instalado

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
# 1. Auditoria OneDrive/SharePoint (não requer módulos)
./scripts/OneDrive/OneDrive-Complete-Audit.ps1 -TenantName "contoso"

# 2. Executar auditoria do Exchange (módulos instalados automaticamente)
./scripts/Exchange/Exchange-Audit.ps1

# 3. Conectar ao Purview
Connect-IPPSSession

# 4. Executar auditoria do Purview
./scripts/Purview/Purview-Audit-PS7.ps1

# 5. Revisar relatórios gerados

# 6. Aplicar remediações do Exchange
./scripts/Remediation/M365-Remediation.ps1

# 7. Aplicar remediações do OneDrive (manual)
# Seguir REMEDIATION-CHECKLIST.md no SharePoint Admin Center

# 8. Desconectar
Disconnect-ExchangeOnline -Confirm:$false
```

### Auditoria Completa de OneDrive

```powershell
# 1. Executar auditoria
./scripts/OneDrive/OneDrive-Complete-Audit.ps1 -TenantName "contoso"

# 2. Revisar relatório HTML gerado

# 3. Aplicar correções no SharePoint Admin Center
# https://contoso-admin.sharepoint.com

# 4. Seguir o checklist em REMEDIATION-CHECKLIST.md

# 5. Re-executar auditoria para validar
./scripts/OneDrive/OneDrive-Complete-Audit.ps1 -TenantName "contoso"
```

### Pós-Incidente de Segurança

```powershell
# 1. Verificar regras de inbox suspeitas
./scripts/Exchange/Clean-InboxRules.ps1 -ReportOnly

# 2. Revisar o relatório CSV gerado

# 3. Remover regras maliciosas
./scripts/Exchange/Clean-InboxRules.ps1

# 4. Executar auditoria completa
./scripts/Exchange/Exchange-Audit.ps1
```

### Manutenção Mensal Hybrid Identity

```powershell
# No servidor Azure AD Connect (como Admin)

# 1. Verificar status atual
./scripts/HybridIdentity/Rotate-KerberosKey-SSO.ps1 -CheckOnly

# 2. Se > 30 dias, rotacionar
./scripts/HybridIdentity/Rotate-KerberosKey-SSO.ps1

# 3. Aguardar 10-15 min para propagação
# 4. Testar SSO com usuário em máquina corporativa
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
    Purview-Audit       Priorizar issues     Clean-InboxRules
    OneDrive-Audit      Documentar gaps      SPO Admin Center
    check-dns.sh                             Remove-Devices
           │                    │                    │
           └────────────────────┼────────────────────┘
                               ▼
                    ┌──────────────────┐
                    │    MONITORAR     │
                    │   (Mensal/Trim)  │
                    └──────────────────┘
                               │
                               ▼
                    ┌──────────────────┐
                    │  HYBRID IDENTITY │
                    │ Kerberos Rotation│
                    │   (Mensal)       │
                    └──────────────────┘
```

---

## 📜 Licenças Microsoft Necessárias

| Recurso | Licença Mínima |
|---------|---------------|
| Unified Audit Log | Microsoft 365 E3/E5, Business Premium |
| DLP Policies | Microsoft 365 E3/E5, Compliance Add-on |
| Safe Links/Attachments | Microsoft Defender for Office 365 |
| Sensitivity Labels | Microsoft 365 E3/E5, AIP P1/P2 |
| Alertas Customizados | Microsoft 365 E5, Compliance Add-on |
| Seamless SSO | Azure AD Free (com AD Connect) |
| OneDrive for Business | Microsoft 365 Business Basic+ |
| SharePoint Admin | Microsoft 365 Business Basic+ |

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

Desenvolvido para administração de múltiplos tenants Microsoft 365.

**Contato:** Abra uma issue para dúvidas ou sugestões.

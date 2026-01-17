# 📧 Scripts Exchange Online

Scripts PowerShell para auditoria de segurança e manutenção do Exchange Online.

## 📋 Scripts Disponíveis

| Script | Versão | Descrição |
|--------|--------|-----------|
| [Exchange-Audit.ps1](Exchange-Audit.ps1) | 2.1 | Auditoria completa de segurança do Exchange Online |
| [Clean-InboxRules.ps1](Clean-InboxRules.ps1) | 2.1 | Limpeza de regras de inbox com erros |

---

## 🔍 Exchange-Audit.ps1

Realiza uma auditoria completa de segurança do Exchange Online, identificando configurações de risco.

### Verificações Realizadas

- **Forwarding Externo**: Identifica mailboxes com redirecionamento para fora da organização
- **Regras de Inbox Suspeitas**: Detecta regras que movem/deletam emails automaticamente
- **Delegações de Mailbox**: Lista permissões FullAccess, SendAs e SendOnBehalf
- **Protocolos Legados**: Verifica POP3, IMAP e SMTP Auth habilitados
- **Mailboxes sem MFA**: Identifica contas vulneráveis (requer conexão com Microsoft Graph)

### Uso

```powershell
# Auditoria completa
./Exchange-Audit.ps1

# Apenas relatório (não exporta CSV)
./Exchange-Audit.ps1 -ReportOnly

# Especificar caminho do relatório
./Exchange-Audit.ps1 -ExportPath "C:\Reports\audit.csv"
```

### Saída

- Relatório visual no console com indicadores de severidade
- Arquivo CSV com todos os achados (padrão: `Exchange-Audit_YYYYMMDD_HHmmss.csv`)

---

## 🧹 Clean-InboxRules.ps1

Identifica e remove regras de inbox com erros (pastas deletadas, destinatários inexistentes, etc.).

### Funcionalidades

- Varre todas as mailboxes do tenant
- Detecta regras com referências inválidas
- Permite remoção em lote ou individual
- Gera relatório CSV das regras problemáticas

### Uso

```powershell
# Modo interativo (pergunta antes de remover)
./Clean-InboxRules.ps1

# Apenas gera relatório, não remove nada
./Clean-InboxRules.ps1 -ReportOnly

# Remove todas automaticamente (sem confirmação)
./Clean-InboxRules.ps1 -RemoveAll

# Especificar caminho do relatório
./Clean-InboxRules.ps1 -ExportPath "C:\Reports\broken-rules.csv"
```

---

## 🔧 Recursos Comuns (v2.1)

Ambos os scripts incluem:

### Verificação Automática de Módulos

- ✅ Instala `ExchangeOnlineManagement` se não existir
- ✅ Remove versões duplicadas automaticamente
- ✅ Limpa módulos `Microsoft.Graph*` duplicados (conflito MSAL)
- ✅ Limpa módulos `Az.Accounts` duplicados
- ✅ Verifica e aplica atualizações disponíveis

### Conexão Inteligente

- Reutiliza conexão existente se disponível
- **Mantém a conexão ativa** ao finalizar (não desconecta)
- Comando para desconectar manualmente:
  ```powershell
  Disconnect-ExchangeOnline -Confirm:$false
  ```

---

## 📦 Requisitos

- PowerShell 5.1 ou superior
- Módulo `ExchangeOnlineManagement` (instalado automaticamente)
- Permissões de administrador no Exchange Online
- Para verificação de MFA: módulo `Microsoft.Graph` e permissões adequadas

## 🚀 Instalação

```powershell
# Clonar o repositório
git clone https://github.com/crayes/azure-scripts.git

# Navegar até a pasta
cd azure-scripts/scripts/Exchange

# Executar (o script instala dependências automaticamente)
./Exchange-Audit.ps1
```

## 📝 Changelog

### v2.1 (Janeiro 2026)
- Adicionada verificação e correção automática de módulos
- Removida desconexão automática (mantém sessão ativa)
- Limpeza de módulos duplicados (Graph, Az.Accounts)

### v2.0 (Janeiro 2026)
- Versão inicial com auditoria completa
- Suporte a múltiplos tipos de verificação
- Exportação para CSV

---

## 📄 Licença

Uso interno - M365 Security Toolkit

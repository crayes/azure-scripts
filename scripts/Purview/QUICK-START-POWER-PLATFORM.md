# ⚡ Quick Start - Power Platform DLP Audit

## 🚀 Setup Rápido (5 minutos)

### 1️⃣ Instalar Power Platform CLI (macOS)

```bash
# Instalar via .NET SDK
dotnet tool install --global Microsoft.PowerApps.CLI.Tool

# Verificar instalação
pac --version
```

### 2️⃣ Executar Script

```powershell
# Navegar até o diretório
cd /Users/crayes/Documents/GitHub/azure-scripts/scripts/Purview

# Executar
pwsh ./Purview-Audit-PS7.ps1
```

### 3️⃣ Autenticação

O script irá:
1. Conectar ao **Exchange Online** (prompt de login)
2. Conectar ao **Security & Compliance** (automático)
3. Conectar ao **Power Platform** (device code)

#### Para Power Platform:
```
  🔍 Conectando ao Power Platform...
  📋 Autenticando Power Platform CLI (device code)...
  
  To sign in, use a web browser to open the page https://microsoft.com/devicelogin
  and enter the code ABC123DEF to authenticate.
```

Abra o navegador, cole o código, e autentique.

---

## 📊 O que Esperar

### Saída no Terminal:

```
══════════════════════════════════════════════════════════════════════
  AUDITORIA DE DLP DO POWER PLATFORM (POWER AUTOMATE)
══════════════════════════════════════════════════════════════════════

  🔍 Detectado macOS - usando Power Platform CLI
  ✅ PAC CLI já autenticado
  📋 Total de ambientes: 5
  📋 Total de políticas DLP: 2

  ✅ Contoso Corporate DLP - 3 ambientes
  ✅ Production Security Policy - 2 ambientes
  
  ⚠️  Ambientes sem política DLP: 1
     ⚠️  Developer Sandbox (Developer)

  ✅ Conectores bloqueados: Gmail, Dropbox, GoogleDrive
  ⚠️  Conectores de alto risco permitidos: SQL, AzureBlobStorage
```

### Score:

```
  📊 SCORES POR CATEGORIA
  ─────────────────────────────────────────────
  Data Loss Prevention          [████████████████░░░░] 82%
  Power Platform DLP            [████████████░░░░░░░░] 65%
  Unified Audit Log             [████████████████████] 100%
  ...
```

---

## 📁 Arquivos Gerados

Todos os relatórios são salvos em:
```
./Purview-Audit-Report_2026-01-31_14-30/
├── results.json          # Dados completos em JSON
├── report.html           # Relatório visual HTML
└── summary.txt           # Sumário em texto
```

---

## 🎯 Interpretação Rápida

### ✅ Score 80-100% (Verde)
**Situação:** Excelente governança  
**Ação:** Manter auditoria periódica

### ⚠️ Score 50-79% (Amarelo)
**Situação:** Governança básica  
**Ação:** Implementar recomendações do relatório

### ❌ Score 0-49% (Vermelho)
**Situação:** Governança crítica  
**Ação:** Ação imediata necessária!

---

## 🔧 Troubleshooting Rápido

### "pac: command not found"

```bash
# Adicionar ao PATH
export PATH="$PATH:$HOME/.dotnet/tools"

# Tornar permanente (adicionar ao ~/.zshrc)
echo 'export PATH="$PATH:$HOME/.dotnet/tools"' >> ~/.zshrc
source ~/.zshrc
```

### "Cannot connect to Power Platform"

```bash
# Limpar credenciais
pac auth clear

# Autenticar novamente
pac auth create --deviceCode
```

### Script pula Power Platform

Verifique se você tem uma das permissões:
- Power Platform Administrator
- Dynamics 365 Administrator
- Global Administrator

---

## 📋 Checklist Pré-Execução

- [ ] PowerShell 7 instalado (`pwsh --version`)
- [ ] .NET SDK instalado (`dotnet --version`)
- [ ] PAC CLI instalado (`pac --version`)
- [ ] Conta com permissões de admin
- [ ] Módulos instalados:
  - `ExchangeOnlineManagement`
  - (PAC CLI já instalado)

---

## ⚡ One-Liner (tudo de uma vez)

```bash
# Instalar dependências e executar (macOS)
dotnet tool install --global Microsoft.PowerApps.CLI.Tool && \
pwsh -Command "Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force" && \
pwsh ./Purview-Audit-PS7.ps1
```

---

## 📚 Próximos Passos

1. ✅ Executar auditoria inicial
2. 📊 Revisar relatório HTML
3. 🛠️ Implementar recomendações críticas
4. 📅 Agendar auditoria mensal
5. 📈 Comparar scores ao longo do tempo

---

**Dúvidas?** Consulte o [guia completo](./POWER-PLATFORM-DLP.md)

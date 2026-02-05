# 🔐 Power Platform DLP - Guia de Auditoria

## 📋 Visão Geral

A versão 4.1 do script `Purview-Audit-PS7.ps1` agora inclui auditoria de **DLP do Power Platform**, cobrindo:

- ✅ **Power Automate** (Flows)
- ✅ **Power Apps** (Canvas & Model-driven)
- ✅ **Conectores e integrações externas**
- ✅ **Políticas DLP por ambiente**

---

## 🎯 Por que Power Platform DLP é importante?

### Diferenças entre Purview DLP vs Power Platform DLP:

| Aspecto | Purview DLP | Power Platform DLP |
|---------|-------------|-------------------|
| **Escopo** | Documentos, emails, conteúdo | Fluxos de dados entre apps |
| **Controla** | Informações sensíveis (CPF, cartão) | Conectores que podem ser usados juntos |
| **Exemplo** | Bloqueia email com 10 CPFs | Impede que Flow conecte SharePoint com Gmail |
| **Risco** | Vazamento de dados via conteúdo | Vazamento de dados via integração |

### Cenários de Risco:

1. **Flow não governado** pode:
   - Copiar arquivos do SharePoint para Dropbox pessoal
   - Enviar dados do Dynamics para planilha Google
   - Conectar SQL Server corporativo com Twitter

2. **Sem política DLP**, usuários podem criar Flows com **900+ conectores**, incluindo:
   - Serviços pessoais (Gmail, Google Drive, Dropbox)
   - Redes sociais (Twitter, Facebook, LinkedIn)
   - Bancos de dados externos

---

## 🖥️ Compatibilidade macOS/Linux

### Autenticação Inteligente:

O script **detecta automaticamente** o sistema operacional:

#### **macOS/Linux:**
- Usa **Power Platform CLI** (`pac`)
- Autenticação moderna via **Device Code Flow**
- Totalmente compatível com PowerShell 7

#### **Windows:**
- Tenta **PowerShell Module** primeiro
- Fallback para **PAC CLI** se módulo não disponível
- Máxima compatibilidade

---

## 🚀 Instalação do Power Platform CLI

### macOS/Linux:

```bash
# Via .NET SDK (recomendado)
dotnet tool install --global Microsoft.PowerApps.CLI.Tool

# Verificar instalação
pac --version

# Atualizar para última versão
dotnet tool update --global Microsoft.PowerApps.CLI.Tool
```

### Windows:

```powershell
# Opção 1: Via .NET SDK
dotnet tool install --global Microsoft.PowerApps.CLI.Tool

# Opção 2: Via PowerShell Module
Install-Module -Name Microsoft.PowerApps.Administration.PowerShell -Scope CurrentUser

# Opção 3: Via Winget
winget install Microsoft.PowerPlatformCLI
```

---

## 📊 O que é Auditado

### 1. **Ambientes Power Platform**
- Total de ambientes (Production, Sandbox, Developer, Teams)
- Ambientes de produção vs desenvolvimento
- Ambientes sem política DLP

### 2. **Políticas DLP**
- Total de políticas configuradas
- Cobertura por ambiente
- Conectores classificados (Business/Blocked/Non-Business)

### 3. **Análise de Conectores**
Verifica conectores de **alto risco**:
- `AzureBlobStorage` - Armazenamento externo
- `SQL` - Bancos de dados
- `Dropbox` / `GoogleDrive` - Armazenamento pessoal
- `Gmail` / `Outlook` - Email externo
- `OneDrive` / `SharePoint` - Dados corporativos

### 4. **Recomendações Geradas**

#### **Critical:**
- Nenhuma política DLP configurada
- Ambientes de produção sem DLP

#### **High:**
- Ambientes sem cobertura de política
- Múltiplos ambientes desprotegidos

#### **Medium:**
- Conectores de alto risco não classificados
- Políticas muito permissivas

---

## 🎯 Sistema de Score

O score de Power Platform DLP é calculado com base em:

| Fator | Peso | Critério |
|-------|------|----------|
| **Políticas existem** | 40% | Pelo menos 1 política DLP configurada |
| **Cobertura de ambientes** | 30% | % de ambientes cobertos por política |
| **Ambientes de produção** | 20% | % de prod protegidos |
| **Conectores bloqueados** | 10% | Conectores de alto risco bloqueados |

### Interpretação:

- **80-100**: Excelente governança
- **50-79**: Governança básica, melhorias recomendadas
- **0-49**: Governança crítica, ação imediata necessária

---

## 🔍 Exemplo de Uso

### Executar auditoria completa:

```powershell
# Auditoria completa (Purview + Power Platform)
./Purview-Audit-PS7.ps1

# Especificar caminho do relatório
./Purview-Audit-PS7.ps1 -OutputPath "./Relatorios/Janeiro2026"

# Incluir detalhes adicionais
./Purview-Audit-PS7.ps1 -IncludeDetails

# Pular conexão (se já autenticado)
./Purview-Audit-PS7.ps1 -SkipConnection
```

### Saída esperada:

```
══════════════════════════════════════════════════════════════════════
  AUDITORIA DE DLP DO POWER PLATFORM (POWER AUTOMATE)
══════════════════════════════════════════════════════════════════════
  🔍 Detectado macOS - usando Power Platform CLI
  ✅ PAC CLI já autenticado
  📋 Total de ambientes: 5
  📋 Total de políticas DLP: 2
  ✅ Contoso DLP Policy - 3 ambientes
  ✅ Production Strict Policy - 2 ambientes
  ⚠️  Ambientes sem política DLP: 1
     ⚠️  Dev Team Environment (Developer)
```

---

## 📄 Relatórios Gerados

O script gera os seguintes arquivos:

### 1. **JSON Completo** (`results.json`)
```json
{
  "PowerPlatformDLP": {
    "Score": 75,
    "Details": {
      "TotalEnvironments": 5,
      "TotalPolicies": 2,
      "EnvironmentsWithoutPolicy": 1,
      "ProductionEnvironments": 2,
      "ProductionWithoutDLP": 0,
      "MethodUsed": "PAC CLI"
    },
    "Recommendations": [...]
  }
}
```

### 2. **HTML Report** (`report.html`)
- Tabela visual com todos os scores
- Categorias puladas destacadas
- Recomendações prioritizadas

---

## 🛠️ Troubleshooting

### Erro: "Power Platform CLI não encontrado"

```bash
# Instalar PAC CLI
dotnet tool install --global Microsoft.PowerApps.CLI.Tool

# Verificar PATH
echo $PATH | grep ".dotnet/tools"

# Se necessário, adicionar ao PATH
export PATH="$PATH:$HOME/.dotnet/tools"
```

### Erro: "Falha na autenticação PAC"

```bash
# Limpar autenticações antigas
pac auth clear

# Autenticar novamente
pac auth create --deviceCode

# Verificar autenticação
pac auth list
```

### Erro: "No environments found"

Isso pode significar:
1. Conta sem acesso ao Power Platform
2. Tenant sem ambientes Power Platform
3. Permissões insuficientes

**Solução:** Verifique se você tem **Power Platform Administrator** ou **Dynamics 365 Administrator**.

### Script pula Power Platform (macOS)

```bash
# Verificar se PAC está funcionando
pac --version

# Testar listagem de ambientes
pac admin list

# Se falhar, reinstalar
dotnet tool uninstall --global Microsoft.PowerApps.CLI.Tool
dotnet tool install --global Microsoft.PowerApps.CLI.Tool
```

---

## 🎓 Best Practices

### 1. **Política Global de Tenant**
Crie uma política DLP que cubra **todos os ambientes**:
- Bloqueia conectores pessoais (Gmail, Dropbox)
- Permite apenas conectores corporativos

### 2. **Políticas Específicas de Produção**
Para ambientes de produção:
- Políticas mais restritivas
- Lista branca de conectores
- Auditoria de alterações

### 3. **Classificação de Conectores**
- **Business**: Microsoft 365, Dynamics, Azure
- **Non-Business**: Serviços externos aprovados
- **Blocked**: Serviços pessoais, não confiáveis

### 4. **Revisão Periódica**
Execute auditoria mensalmente para:
- Novos ambientes sem política
- Novos conectores não classificados
- Mudanças em políticas

---

## 📚 Referências

- [Power Platform DLP Documentation](https://learn.microsoft.com/power-platform/admin/wp-data-loss-prevention)
- [Power Platform CLI Reference](https://learn.microsoft.com/power-platform/developer/cli/introduction)
- [Connector Reference](https://learn.microsoft.com/connectors/connector-reference/)
- [DLP Best Practices](https://learn.microsoft.com/power-platform/guidance/adoption/dlp-strategy)

---

## 🆘 Suporte

Para problemas específicos:

1. **Erros de autenticação**: Verifique permissões de admin
2. **PAC CLI issues**: Consulte [GitHub Issues](https://github.com/microsoft/powerplatform-build-tools/issues)
3. **Script errors**: Abra issue no repositório do script

---

**Versão:** 4.1  
**Última atualização:** Janeiro 2026  
**Autor:** M365 Security Toolkit - RFAA

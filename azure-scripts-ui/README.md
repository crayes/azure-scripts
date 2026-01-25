# Azure Scripts UI

Interface desktop multiplataforma para gerenciamento e execução de scripts de administração Microsoft 365 e Azure.

![Azure Scripts UI](https://img.shields.io/badge/Electron-33.x-47848F?logo=electron) ![PowerShell](https://img.shields.io/badge/PowerShell-Core-5391FE?logo=powershell) ![Platform](https://img.shields.io/badge/Platform-Windows%20|%20macOS%20|%20Linux-lightgrey)

## 🚀 Funcionalidades

- **Lista de Scripts**: Visualize todos os scripts PowerShell organizados por categoria
- **Execução Integrada**: Execute scripts diretamente da UI com output em tempo real
- **Visualização de Código**: Veja o código fonte dos scripts antes de executar
- **Multiplataforma**: Windows, macOS e Linux
- **Seguro**: Implementa contextIsolation e preload script (best practices do Electron)

## 📦 Requisitos

- **Node.js** 18 ou superior
- **PowerShell Core** (pwsh) - [Instalar](https://github.com/PowerShell/PowerShell#get-powershell)
  - macOS: `brew install powershell/tap/powershell`
  - Windows: Já incluído ou via Microsoft Store
  - Linux: [Instruções por distro](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux)

## 🛠️ Instalação

```bash
# Clonar o repositório
git clone https://github.com/crayes/azure-scripts.git
cd azure-scripts/azure-scripts-ui

# Instalar dependências
npm install

# Executar em modo desenvolvimento
npm run dev

# Ou executar normalmente
npm start
```

## 📁 Estrutura do Projeto

```
azure-scripts-ui/
├── main.js          # Processo principal do Electron (IPC handlers, segurança)
├── preload.js       # Ponte segura entre main e renderer (contextBridge)
├── renderer.js      # Lógica da interface (usa window.electronAPI)
├── index.html       # Layout da interface
├── styles.css       # Estilos CSS
├── package.json     # Dependências e scripts
└── assets/          # Ícones e recursos
```

## 🔒 Arquitetura de Segurança

O projeto segue as melhores práticas de segurança do Electron:

```
┌─────────────────────────────────────────────────────────────┐
│                     MAIN PROCESS                            │
│  - Acesso total ao Node.js                                  │
│  - IPC handlers para operações sensíveis                    │
│  - Validação de caminhos de scripts                         │
│  - Spawn de processos PowerShell                            │
└────────────────────────┬────────────────────────────────────┘
                         │ IPC (invoke/handle)
┌────────────────────────▼────────────────────────────────────┐
│                    PRELOAD SCRIPT                           │
│  - contextBridge.exposeInMainWorld()                        │
│  - API controlada: window.electronAPI                       │
│  - Único ponto de comunicação                               │
└────────────────────────┬────────────────────────────────────┘
                         │ window.electronAPI
┌────────────────────────▼────────────────────────────────────┐
│                   RENDERER PROCESS                          │
│  - SEM acesso direto ao Node.js                             │
│  - Usa apenas window.electronAPI                            │
│  - contextIsolation: true                                   │
│  - nodeIntegration: false                                   │
└─────────────────────────────────────────────────────────────┘
```

## 🎮 Uso

1. **Selecionar Script**: Clique em um script na sidebar esquerda
2. **Visualizar**: Clique em "👁️ Visualizar" para ver o código
3. **Executar**: Clique em "▶️ Executar" para rodar o script
4. **Output**: Acompanhe a saída em tempo real no console

## 📋 API Disponível (preload.js)

```javascript
// Obter lista de scripts
const scripts = await window.electronAPI.getScripts();

// Executar script
const result = await window.electronAPI.runScript(scriptPath, args);

// Verificar PowerShell
const psInfo = await window.electronAPI.checkPowerShell();

// Listener de output em tempo real
const cleanup = window.electronAPI.onScriptOutput((data) => {
  console.log(data.type, data.data);
});

// Informações do sistema
const sysInfo = await window.electronAPI.getSystemInfo();
```

## 🏗️ Build para Distribuição

```bash
# Build para a plataforma atual
npm run build

# Build específico por plataforma
npm run build:mac    # macOS (DMG + ZIP)
npm run build:win    # Windows (NSIS + Portable)
npm run build:linux  # Linux (AppImage + DEB)

# Gerar apenas o diretório (sem empacotamento)
npm run pack
```

Os arquivos de distribuição serão gerados em `dist/`.

## 🔧 Desenvolvimento

```bash
# Modo desenvolvimento (abre DevTools automaticamente)
npm run dev

# Windows
npm run dev:win
```

## 📝 Scripts PowerShell Suportados

O app detecta automaticamente scripts `.ps1` nas seguintes pastas:

- `scripts/Exchange/` - Auditoria e gestão do Exchange Online
- `scripts/EntraID/` - Azure AD / Entra ID
- `scripts/Purview/` - Compliance e DLP
- `scripts/OneDrive/` - OneDrive for Business
- `scripts/SharePoint/` - SharePoint Online
- `scripts/DNS/` - Configurações DNS
- `scripts/HybridIdentity/` - Identidade híbrida
- `scripts/Remediation/` - Scripts de remediação

## 🤝 Contribuindo

1. Fork o repositório
2. Crie uma branch: `git checkout -b feature/nova-funcionalidade`
3. Commit: `git commit -m 'feat: adiciona nova funcionalidade'`
4. Push: `git push origin feature/nova-funcionalidade`
5. Abra um Pull Request

## 📄 Licença

MIT License - veja [LICENSE](../LICENSE) para detalhes.

---

**Azure Scripts UI** - Simplificando a administração Microsoft 365 🚀

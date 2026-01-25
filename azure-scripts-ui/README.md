# Azure Scripts UI

Interface desktop multiplataforma (Windows, macOS, Linux) para gerenciamento e execução de scripts de administração Microsoft 365 e Azure.

## 📋 Visão Geral

Esta aplicação Electron fornece uma camada de UI amigável sobre o conjunto de scripts PowerShell disponíveis no repositório `crayes/azure-scripts`, facilitando a execução e monitoramento de tarefas administrativas.

## 🚀 Requisitos

- **Node.js** 18.x ou superior
- **npm** 9.x ou superior

## 📦 Instalação

1. Navegue até a pasta do projeto:
```bash
cd azure-scripts-ui
```

2. Instale as dependências:
```bash
npm install
```

## 🏃 Executar em Modo Desenvolvimento

Para iniciar a aplicação em modo desenvolvimento:

```bash
npm run dev
```

Ou simplesmente:

```bash
npm start
```

### Diferença entre `dev` e `start`:
- **`npm run dev`**: Abre a aplicação com DevTools aberto automaticamente (útil para debugging)
- **`npm start`**: Abre a aplicação em modo normal

## 📦 Empacotar a Aplicação

### Configuração Futura

O empacotamento da aplicação será implementado usando `electron-builder` ou `electron-forge`. Para preparar:

1. Instalar electron-builder:
```bash
npm install --save-dev electron-builder
```

2. Adicionar configuração ao `package.json`:
```json
"build": {
  "appId": "com.azurescripts.ui",
  "productName": "Azure Scripts UI",
  "directories": {
    "output": "dist"
  },
  "files": [
    "main.js",
    "index.html",
    "renderer.js",
    "styles.css",
    "package.json"
  ],
  "win": {
    "target": ["nsis"],
    "icon": "assets/icon.ico"
  },
  "mac": {
    "target": ["dmg"],
    "icon": "assets/icon.icns"
  },
  "linux": {
    "target": ["AppImage"],
    "icon": "assets/icon.png"
  }
}
```

3. Atualizar script de build:
```json
"scripts": {
  "build": "electron-builder",
  "build:win": "electron-builder --win",
  "build:mac": "electron-builder --mac",
  "build:linux": "electron-builder --linux"
}
```

4. Executar build:
```bash
npm run build
```

## 🏗️ Estrutura do Projeto

```
azure-scripts-ui/
├── main.js           # Processo principal do Electron
├── index.html        # Interface HTML principal
├── renderer.js       # Script do processo renderer
├── styles.css        # Estilos CSS da aplicação
├── package.json      # Configuração do projeto Node.js
└── README.md         # Este arquivo
```

## 🎯 Recursos Atuais

### Interface Inicial
- ✅ Estrutura funcional Electron (main + renderer)
- ✅ Interface responsiva com design moderno
- ✅ Exibição de informações sobre os scripts Azure
- ✅ Cards de recursos planejados para futuras funcionalidades

### Recursos Planejados
- 📊 **Auditoria Exchange**: Interface para executar e visualizar auditorias do Exchange Online
- 🛡️ **Purview & Compliance**: Gerenciamento de políticas DLP
- ☁️ **OneDrive & SharePoint**: Auditoria de segurança
- 🔐 **Conditional Access**: Análise de políticas e troubleshooting
- 💻 **Gestão de Dispositivos**: Remoção de dispositivos inativos
- 🔄 **Hybrid Identity**: Rotação de chaves Kerberos

## 🔧 Scripts Disponíveis

| Script | Descrição |
|--------|-----------|
| `npm start` | Inicia a aplicação Electron |
| `npm run dev` | Inicia em modo desenvolvimento com DevTools |
| `npm run build` | Empacota a aplicação (a ser implementado) |

## 🌐 Plataformas Suportadas

- **Windows** 10/11 (x64)
- **macOS** 10.13+ (Intel e Apple Silicon)
- **Linux** (Ubuntu, Fedora, Debian e derivados)

## 🛠️ Desenvolvimento

### Adicionar Novas Funcionalidades

1. **Editar a interface**: Modifique `index.html` e `styles.css`
2. **Adicionar lógica do renderer**: Edite `renderer.js`
3. **Modificar comportamento do app**: Ajuste `main.js`

### Debugging

O modo desenvolvimento (`npm run dev`) abre automaticamente as DevTools do Chrome. Use para:
- Inspecionar elementos HTML/CSS
- Debugar JavaScript
- Monitorar console logs
- Analisar performance

### Integração com Scripts PowerShell

Para integrar os scripts PowerShell existentes, você pode:

1. Usar `child_process` do Node.js:
```javascript
const { exec } = require('child_process');

exec('pwsh -File ../scripts/Exchange/Exchange-Audit.ps1', (error, stdout, stderr) => {
  if (error) {
    console.error(`Erro: ${error}`);
    return;
  }
  console.log(`Saída: ${stdout}`);
});
```

2. Ou usar bibliotecas como `node-powershell`:
```bash
npm install node-powershell
```

## 📝 Notas Importantes

1. **Node Integration**: Esta aplicação usa `nodeIntegration: true` para facilitar o desenvolvimento inicial. Para produção, considere usar `contextBridge` para maior segurança.

2. **Content Security Policy**: Já configurado no HTML para proteger contra XSS.

3. **Dependências**: O `package.json` usa Electron como `devDependency`. Para produção, considere movê-lo para `dependencies`.

## 🤝 Contribuindo

Para adicionar novos recursos ou melhorias:

1. Crie uma branch para sua feature
2. Faça suas alterações
3. Teste localmente com `npm start`
4. Submeta um Pull Request

## 📄 Licença

MIT - Veja o arquivo LICENSE na raiz do repositório.

## 🔗 Links Úteis

- [Documentação Electron](https://www.electronjs.org/docs)
- [Electron Builder](https://www.electron.build/)
- [Repositório Principal](https://github.com/crayes/azure-scripts)
- [Scripts PowerShell M365](../README.md)

## 💡 Suporte

Para dúvidas ou problemas, abra uma issue no repositório do GitHub.

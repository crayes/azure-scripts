const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const path = require('path');
const { spawn } = require('child_process');
const fs = require('fs');

let mainWindow;

// Detectar o executável do PowerShell (pwsh para PowerShell Core, powershell para Windows PowerShell)
function getPowerShellExecutable() {
  if (process.platform === 'win32') {
    // Tentar pwsh primeiro (PowerShell Core), fallback para powershell (Windows PowerShell)
    return 'pwsh';
  }
  // macOS e Linux usam pwsh
  return 'pwsh';
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1400,
    height: 900,
    minWidth: 1000,
    minHeight: 700,
    webPreferences: {
      nodeIntegration: false,        // ✅ Desabilitado para segurança
      contextIsolation: true,        // ✅ Habilitado para segurança
      preload: path.join(__dirname, 'preload.js'),  // ✅ Usar preload script
      sandbox: false,                // Necessário para preload funcionar com Node APIs
    },
    titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'default',
    icon: path.join(__dirname, 'assets', 'icon.png'),
  });

  mainWindow.loadFile('index.html');

  // DevTools em desenvolvimento
  if (process.env.NODE_ENV === 'development') {
    mainWindow.webContents.openDevTools();
  }

  mainWindow.on('closed', () => {
    mainWindow = null;
  });
}

// ==================== IPC Handlers ====================

// Executar script PowerShell
ipcMain.handle('execute-script', async (event, scriptPath, args = []) => {
  return new Promise((resolve, reject) => {
    const psExecutable = getPowerShellExecutable();
    const fullScriptPath = path.resolve(__dirname, '..', scriptPath);
    
    // Verificar se o script existe
    if (!fs.existsSync(fullScriptPath)) {
      reject(new Error(`Script não encontrado: ${fullScriptPath}`));
      return;
    }

    const psArgs = [
      '-NoProfile',
      '-ExecutionPolicy', 'Bypass',
      '-File', fullScriptPath,
      ...args
    ];

    console.log(`Executando: ${psExecutable} ${psArgs.join(' ')}`);

    const child = spawn(psExecutable, psArgs, {
      cwd: path.dirname(fullScriptPath),
      env: { ...process.env, TERM: 'xterm-256color' }
    });

    let stdout = '';
    let stderr = '';

    child.stdout.on('data', (data) => {
      const text = data.toString();
      stdout += text;
      // Enviar output em tempo real para o renderer
      mainWindow?.webContents.send('script-output', { type: 'stdout', data: text });
    });

    child.stderr.on('data', (data) => {
      const text = data.toString();
      stderr += text;
      mainWindow?.webContents.send('script-output', { type: 'stderr', data: text });
    });

    child.on('error', (error) => {
      reject(new Error(`Falha ao executar PowerShell: ${error.message}. Verifique se pwsh está instalado.`));
    });

    child.on('close', (code) => {
      if (code === 0) {
        resolve({ success: true, stdout, stderr, code });
      } else {
        resolve({ success: false, stdout, stderr, code });
      }
    });
  });
});

// Verificar se PowerShell está disponível
ipcMain.handle('check-powershell', async () => {
  return new Promise((resolve) => {
    const psExecutable = getPowerShellExecutable();
    const child = spawn(psExecutable, ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()']);
    
    let version = '';
    
    child.stdout.on('data', (data) => {
      version += data.toString().trim();
    });

    child.on('error', () => {
      resolve({ available: false, version: null, executable: psExecutable });
    });

    child.on('close', (code) => {
      resolve({ 
        available: code === 0, 
        version: version || null,
        executable: psExecutable 
      });
    });
  });
});

// Listar scripts disponíveis
ipcMain.handle('list-scripts', async () => {
  const scriptsDir = path.resolve(__dirname, '..', 'scripts');
  const scripts = [];

  const scanDirectory = (dir, category = '') => {
    if (!fs.existsSync(dir)) return;
    
    const items = fs.readdirSync(dir, { withFileTypes: true });
    
    for (const item of items) {
      if (item.isDirectory() && !item.name.startsWith('.')) {
        scanDirectory(path.join(dir, item.name), item.name);
      } else if (item.isFile() && item.name.endsWith('.ps1')) {
        scripts.push({
          name: item.name,
          category: category || 'Root',
          path: path.relative(path.join(__dirname, '..'), path.join(dir, item.name)),
          fullPath: path.join(dir, item.name)
        });
      }
    }
  };

  scanDirectory(scriptsDir);
  
  // Incluir scripts na raiz
  const rootScript = path.resolve(__dirname, '..', 'OneDrive-Complete-Audit.ps1');
  if (fs.existsSync(rootScript)) {
    scripts.push({
      name: 'OneDrive-Complete-Audit.ps1',
      category: 'OneDrive',
      path: 'OneDrive-Complete-Audit.ps1',
      fullPath: rootScript
    });
  }

  return scripts;
});

// Abrir diálogo para selecionar pasta de output
ipcMain.handle('select-output-folder', async () => {
  const result = await dialog.showOpenDialog(mainWindow, {
    properties: ['openDirectory', 'createDirectory'],
    title: 'Selecionar pasta para relatórios'
  });
  
  return result.canceled ? null : result.filePaths[0];
});

// Obter informações do sistema
ipcMain.handle('get-system-info', async () => {
  return {
    platform: process.platform,
    arch: process.arch,
    nodeVersion: process.versions.node,
    electronVersion: process.versions.electron,
    appVersion: app.getVersion(),
    appPath: app.getAppPath()
  };
});

// Abrir arquivo/pasta no explorador
ipcMain.handle('open-path', async (event, filePath) => {
  const { shell } = require('electron');
  if (fs.existsSync(filePath)) {
    shell.showItemInFolder(filePath);
    return true;
  }
  return false;
});

// ==================== App Lifecycle ====================

app.whenReady().then(() => {
  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});

// Prevenir navegação para URLs externas (segurança)
app.on('web-contents-created', (event, contents) => {
  contents.on('will-navigate', (event, navigationUrl) => {
    const parsedUrl = new URL(navigationUrl);
    if (parsedUrl.protocol !== 'file:') {
      event.preventDefault();
    }
  });
});

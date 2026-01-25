const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const path = require('path');
const { spawn } = require('child_process');
const os = require('os');
const fs = require('fs');

let mainWindow;

// Detectar shell PowerShell disponível
function getPowerShellExecutable() {
  // Preferir pwsh (PowerShell Core) se disponível
  const pwshPaths = process.platform === 'win32'
    ? ['pwsh.exe', 'powershell.exe']
    : ['pwsh', '/usr/local/bin/pwsh', '/opt/homebrew/bin/pwsh'];
  
  for (const shell of pwshPaths) {
    try {
      const { execSync } = require('child_process');
      execSync(`${shell} -Version`, { stdio: 'ignore' });
      return shell;
    } catch {
      continue;
    }
  }
  return process.platform === 'win32' ? 'powershell.exe' : 'pwsh';
}

const POWERSHELL = getPowerShellExecutable();

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1400,
    height: 900,
    minWidth: 1000,
    minHeight: 700,
    webPreferences: {
      nodeIntegration: false,        // ✅ Desabilitado por segurança
      contextIsolation: true,        // ✅ Habilitado por segurança
      preload: path.join(__dirname, 'preload.js'),  // ✅ Usando preload seguro
      sandbox: false,                // Necessário para child_process no preload
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

// Obter lista de scripts disponíveis
ipcMain.handle('get-scripts', async () => {
  const scriptsPath = path.join(__dirname, '..', 'scripts');
  const scripts = [];
  
  try {
    const categories = fs.readdirSync(scriptsPath, { withFileTypes: true })
      .filter(dirent => dirent.isDirectory() && !dirent.name.startsWith('.'));
    
    for (const category of categories) {
      const categoryPath = path.join(scriptsPath, category.name);
      const files = fs.readdirSync(categoryPath)
        .filter(file => file.endsWith('.ps1'));
      
      for (const file of files) {
        scripts.push({
          name: file,
          category: category.name,
          path: path.join(categoryPath, file),
          relativePath: path.join('scripts', category.name, file),
        });
      }
    }
    
    // Adicionar scripts na raiz
    const rootScripts = fs.readdirSync(path.join(__dirname, '..'))
      .filter(file => file.endsWith('.ps1'));
    
    for (const file of rootScripts) {
      scripts.push({
        name: file,
        category: 'Root',
        path: path.join(__dirname, '..', file),
        relativePath: file,
      });
    }
  } catch (error) {
    console.error('Erro ao listar scripts:', error);
  }
  
  return scripts;
});

// Executar script PowerShell
ipcMain.handle('run-script', async (event, scriptPath, args = []) => {
  return new Promise((resolve, reject) => {
    const outputLines = [];
    const errorLines = [];
    
    // Validar que o script existe e está dentro do diretório permitido
    const allowedBasePath = path.join(__dirname, '..');
    const resolvedPath = path.resolve(scriptPath);
    
    if (!resolvedPath.startsWith(allowedBasePath)) {
      reject(new Error('Acesso negado: script fora do diretório permitido'));
      return;
    }
    
    if (!fs.existsSync(resolvedPath)) {
      reject(new Error(`Script não encontrado: ${scriptPath}`));
      return;
    }

    // Notificar início
    mainWindow.webContents.send('script-output', {
      type: 'info',
      data: `Executando: ${path.basename(scriptPath)}\nUsando: ${POWERSHELL}\n${'─'.repeat(50)}\n`
    });

    const psArgs = [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy', 'Bypass',
      '-File', resolvedPath,
      ...args
    ];

    const child = spawn(POWERSHELL, psArgs, {
      cwd: path.dirname(resolvedPath),
      env: { ...process.env, TERM: 'xterm-256color' },
    });

    child.stdout.on('data', (data) => {
      const text = data.toString();
      outputLines.push(text);
      mainWindow.webContents.send('script-output', { type: 'stdout', data: text });
    });

    child.stderr.on('data', (data) => {
      const text = data.toString();
      errorLines.push(text);
      mainWindow.webContents.send('script-output', { type: 'stderr', data: text });
    });

    child.on('error', (error) => {
      mainWindow.webContents.send('script-output', { 
        type: 'error', 
        data: `Erro ao executar: ${error.message}` 
      });
      reject(error);
    });

    child.on('close', (code) => {
      const result = {
        exitCode: code,
        stdout: outputLines.join(''),
        stderr: errorLines.join(''),
        success: code === 0,
      };
      
      mainWindow.webContents.send('script-output', { 
        type: 'complete', 
        data: `\n${'─'.repeat(50)}\nFinalizado com código: ${code}\n`,
        exitCode: code
      });
      
      resolve(result);
    });
  });
});

// Selecionar arquivo
ipcMain.handle('select-file', async (event, options = {}) => {
  const result = await dialog.showOpenDialog(mainWindow, {
    properties: ['openFile'],
    filters: options.filters || [
      { name: 'PowerShell Scripts', extensions: ['ps1'] },
      { name: 'All Files', extensions: ['*'] }
    ],
    ...options
  });
  return result.filePaths[0] || null;
});

// Selecionar diretório
ipcMain.handle('select-directory', async () => {
  const result = await dialog.showOpenDialog(mainWindow, {
    properties: ['openDirectory', 'createDirectory']
  });
  return result.filePaths[0] || null;
});

// Obter informações do sistema
ipcMain.handle('get-system-info', async () => {
  return {
    platform: process.platform,
    arch: process.arch,
    nodeVersion: process.versions.node,
    electronVersion: process.versions.electron,
    powershell: POWERSHELL,
    homeDir: os.homedir(),
    hostname: os.hostname(),
  };
});

// Verificar se PowerShell está disponível
ipcMain.handle('check-powershell', async () => {
  return new Promise((resolve) => {
    const child = spawn(POWERSHELL, ['-Version']);
    let version = '';
    
    child.stdout.on('data', (data) => {
      version += data.toString();
    });
    
    child.on('close', (code) => {
      resolve({
        available: code === 0,
        executable: POWERSHELL,
        version: version.trim(),
      });
    });
    
    child.on('error', () => {
      resolve({
        available: false,
        executable: POWERSHELL,
        version: null,
      });
    });
  });
});

// Ler conteúdo de script
ipcMain.handle('read-script', async (event, scriptPath) => {
  try {
    const allowedBasePath = path.join(__dirname, '..');
    const resolvedPath = path.resolve(scriptPath);
    
    if (!resolvedPath.startsWith(allowedBasePath)) {
      throw new Error('Acesso negado');
    }
    
    return fs.readFileSync(resolvedPath, 'utf8');
  } catch (error) {
    throw new Error(`Erro ao ler script: ${error.message}`);
  }
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

// Segurança: prevenir navegação para URLs externas
app.on('web-contents-created', (event, contents) => {
  contents.on('will-navigate', (event, navigationUrl) => {
    const parsedUrl = new URL(navigationUrl);
    if (parsedUrl.protocol !== 'file:') {
      event.preventDefault();
    }
  });
});

const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const path = require('path');
const { spawn } = require('child_process');
const os = require('os');
const fs = require('fs');

let mainWindow;
let currentProcess = null;
let currentRunId = null;

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
const USER_DATA_DIR = app.getPath('userData');
const SETTINGS_PATH = path.join(USER_DATA_DIR, 'settings.json');
const PROFILES_PATH = path.join(USER_DATA_DIR, 'profiles.json');
const HISTORY_PATH = path.join(USER_DATA_DIR, 'history.json');
const LOGS_DIR = path.join(USER_DATA_DIR, 'logs');
const REPORTS_DIR = path.join(USER_DATA_DIR, 'reports');

// Detectar shell Bash disponível (para scripts .sh)
function getBashExecutable() {
  const bashPaths = process.platform === 'win32'
    ? ['bash.exe']
    : ['bash', '/bin/bash', '/usr/bin/bash', '/usr/local/bin/bash', '/opt/homebrew/bin/bash'];

  for (const shell of bashPaths) {
    try {
      const { execSync } = require('child_process');
      execSync(`${shell} --version`, { stdio: 'ignore' });
      return shell;
    } catch {
      continue;
    }
  }
  return process.platform === 'win32' ? 'bash.exe' : 'bash';
}

const BASH = getBashExecutable();

function getScriptRunner(scriptPath) {
  const ext = path.extname(scriptPath).toLowerCase();
  if (ext === '.ps1') {
    return { command: POWERSHELL, args: ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File'] };
  }
  if (ext === '.sh') {
    return { command: BASH, args: [] };
  }
  return null;
}

function ensureDirSync(dirPath) {
  if (!fs.existsSync(dirPath)) {
    fs.mkdirSync(dirPath, { recursive: true });
  }
}

function readJsonSafe(filePath, fallback) {
  try {
    if (!fs.existsSync(filePath)) return fallback;
    const content = fs.readFileSync(filePath, 'utf8');
    return JSON.parse(content);
  } catch {
    return fallback;
  }
}

function writeJsonSafe(filePath, data) {
  try {
    ensureDirSync(path.dirname(filePath));
    fs.writeFileSync(filePath, JSON.stringify(data, null, 2), 'utf8');
  } catch (error) {
    console.error('Erro ao salvar JSON:', error);
  }
}

function getDefaultSettings() {
  return {
    organizeReports: true,
    reportBaseDir: REPORTS_DIR,
    historyLimit: 200
  };
}

function getSettings() {
  const settings = readJsonSafe(SETTINGS_PATH, getDefaultSettings());
  return { ...getDefaultSettings(), ...settings };
}

function getProfiles() {
  return readJsonSafe(PROFILES_PATH, { profiles: {} });
}

function getHistory() {
  return readJsonSafe(HISTORY_PATH, { runs: [] });
}

function saveHistoryRun(run) {
  const settings = getSettings();
  const history = getHistory();
  history.runs.unshift(run);
  history.runs = history.runs.slice(0, settings.historyLimit || 200);
  writeJsonSafe(HISTORY_PATH, history);
}

function parseCommentHelp(content) {
  const blockMatch = content.match(/<#([\s\S]*?)#>/);
  if (!blockMatch) return { synopsis: '', description: '', parameters: {} };
  const block = blockMatch[1];

  const synopsisMatch = block.match(/\.SYNOPSIS([\s\S]*?)(?=\n\.|$)/i);
  const descriptionMatch = block.match(/\.DESCRIPTION([\s\S]*?)(?=\n\.|$)/i);
  const synopsis = synopsisMatch ? synopsisMatch[1].trim() : '';
  const description = descriptionMatch ? descriptionMatch[1].trim() : '';

  const params = {};
  const paramRegex = /\.PARAMETER\s+([\w-]+)([\s\S]*?)(?=\n\.|$)/gi;
  let match;
  while ((match = paramRegex.exec(block))) {
    params[match[1]] = match[2].trim();
  }

  return { synopsis, description, parameters: params };
}

function extractParamBlock(content) {
  const idx = content.toLowerCase().indexOf('param(');
  if (idx === -1) return '';
  let depth = 0;
  let end = -1;
  for (let i = idx; i < content.length; i += 1) {
    const char = content[i];
    if (char === '(') depth += 1;
    if (char === ')') depth -= 1;
    if (depth === 0) {
      end = i;
      break;
    }
  }
  if (end === -1) return '';
  return content.slice(idx + 6, end);
}

function parsePowerShellParams(content) {
  const help = parseCommentHelp(content);
  const block = extractParamBlock(content);
  if (!block) return { args: [], help };

  const lines = block.split(/\r?\n/).map(l => l.trim()).filter(Boolean);
  const args = [];

  lines.forEach((line) => {
    if (line.startsWith('[') && line.endsWith(']')) return;
    const match = line.match(/\[(?<type>[^\]]+)\]\s*\$(?<name>[A-Za-z0-9_]+)/);
    if (!match) return;
    const typeRaw = match.groups.type.toLowerCase();
    const name = match.groups.name;
    const description = help.parameters[name] || '';
    const isSwitch = typeRaw.includes('switch');
    const type = isSwitch ? 'switch' : (typeRaw.includes('int') || typeRaw.includes('double') ? 'number' : 'string');

    args.push({
      key: name,
      label: name,
      type,
      flag: `-${name}`,
      description
    });
  });

  return { args, help };
}

function parseRequires(content) {
  const requires = { version: null, modules: [] };
  const versionMatch = content.match(/#requires\s+-version\s+([\d\.]+)/i);
  if (versionMatch) requires.version = versionMatch[1];
  const moduleMatch = content.match(/#requires\s+-modules\s+([\w\.,\s-]+)/i);
  if (moduleMatch) {
    requires.modules = moduleMatch[1].split(',').map(s => s.trim()).filter(Boolean);
  }
  return requires;
}

async function getPowerShellVersion() {
  return new Promise((resolve) => {
    const child = spawn(POWERSHELL, ['-NoProfile', '-NonInteractive', '-Command', '$PSVersionTable.PSVersion.ToString()']);
    let version = '';
    child.stdout.on('data', (data) => { version += data.toString(); });
    child.on('close', (code) => {
      resolve(code === 0 ? version.trim() : null);
    });
    child.on('error', () => resolve(null));
  });
}

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
        .filter(file => file.endsWith('.ps1') || file.endsWith('.sh'));
      
      for (const file of files) {
        const ext = path.extname(file).replace('.', '').toLowerCase();
        scripts.push({
          name: file,
          category: category.name,
          path: path.join(categoryPath, file),
          relativePath: path.join('scripts', category.name, file),
          type: ext,
        });
      }
    }
    
    // Adicionar scripts na raiz
    const rootScripts = fs.readdirSync(path.join(__dirname, '..'))
      .filter(file => file.endsWith('.ps1') || file.endsWith('.sh'));
    
    for (const file of rootScripts) {
      const ext = path.extname(file).replace('.', '').toLowerCase();
      scripts.push({
        name: file,
        category: 'Root',
        path: path.join(__dirname, '..', file),
        relativePath: file,
        type: ext,
      });
    }
  } catch (error) {
    console.error('Erro ao listar scripts:', error);
  }
  
  return scripts;
});

// Ler manifesto de scripts (metadados e workflows)
ipcMain.handle('get-manifest', async () => {
  try {
    const manifestPath = path.join(__dirname, 'scripts-manifest.json');
    if (!fs.existsSync(manifestPath)) {
      return { scripts: {}, workflows: [] };
    }
    const content = fs.readFileSync(manifestPath, 'utf8');
    return JSON.parse(content);
  } catch (error) {
    console.error('Erro ao ler manifesto:', error);
    return { scripts: {}, workflows: [] };
  }
});

// Obter metadados automaticamente de scripts
ipcMain.handle('get-script-metadata', async (event, scriptPath) => {
  try {
    const resolvedPath = path.resolve(scriptPath);
    const allowedBasePath = path.join(__dirname, '..');
    if (!resolvedPath.startsWith(allowedBasePath)) {
      return { args: [], description: '', requires: { version: null, modules: [] } };
    }
    const content = fs.readFileSync(resolvedPath, 'utf8');
    const ext = path.extname(resolvedPath).toLowerCase();
    const requires = ext === '.ps1' ? parseRequires(content) : { version: null, modules: [] };
    const psMeta = ext === '.ps1' ? parsePowerShellParams(content) : { args: [], help: {} };
    const description = psMeta.help?.synopsis || psMeta.help?.description || '';
    return { args: psMeta.args, description, requires };
  } catch (error) {
    console.error('Erro ao analisar metadados:', error);
    return { args: [], description: '', requires: { version: null, modules: [] } };
  }
});

// Executar script
ipcMain.handle('run-script', async (event, scriptPath, args = []) => {
  return new Promise(async (resolve, reject) => {
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

    const runner = getScriptRunner(resolvedPath);
    if (!runner) {
      reject(new Error('Tipo de script não suportado'));
      return;
    }

    // Pré-requisitos (PowerShell)
    if (path.extname(resolvedPath).toLowerCase() === '.ps1') {
      const content = fs.readFileSync(resolvedPath, 'utf8');
      const requires = parseRequires(content);
      if (requires.version) {
        const psVersion = await getPowerShellVersion();
        if (psVersion && psVersion.localeCompare(requires.version, undefined, { numeric: true }) < 0) {
          reject(new Error(`PowerShell ${requires.version}+ requerido. Versão atual: ${psVersion}`));
          return;
        }
      }

      if (requires.modules?.length) {
        mainWindow.webContents.send('script-output', {
          type: 'info',
          data: `Pré-requisitos: módulos necessários - ${requires.modules.join(', ')}\n`
        });
      }
    }

    const runnerArgs = [...runner.args, resolvedPath, ...args];

    ensureDirSync(LOGS_DIR);
    const runId = `run_${Date.now()}_${Math.floor(Math.random() * 10000)}`;
    currentRunId = runId;
    const logFile = path.join(LOGS_DIR, `${runId}.log`);
    const logStream = fs.createWriteStream(logFile, { flags: 'a' });
    const startedAt = new Date().toISOString();

    // Notificar início
    mainWindow.webContents.send('script-output', {
      type: 'info',
      data: `Executando: ${path.basename(scriptPath)}\nUsando: ${runner.command}\n${'─'.repeat(50)}\n`
    });

    const child = spawn(runner.command, runnerArgs, {
      cwd: path.dirname(resolvedPath),
      env: { ...process.env, TERM: 'xterm-256color' },
    });

    currentProcess = child;

    child.stdout.on('data', (data) => {
      const text = data.toString();
      outputLines.push(text);
      logStream.write(text);
      mainWindow.webContents.send('script-output', { type: 'stdout', data: text });
    });

    child.stderr.on('data', (data) => {
      const text = data.toString();
      errorLines.push(text);
      logStream.write(text);
      mainWindow.webContents.send('script-output', { type: 'stderr', data: text });
    });

    child.on('error', (error) => {
      mainWindow.webContents.send('script-output', {
        type: 'error',
        data: `Erro ao executar: ${error.message}`
      });
      logStream.write(`\nErro ao executar: ${error.message}\n`);
      logStream.end();
      reject(error);
    });

    child.on('close', (code) => {
      const endedAt = new Date().toISOString();
      const result = {
        exitCode: code,
        stdout: outputLines.join(''),
        stderr: errorLines.join(''),
        success: code === 0,
        runId,
        logFile,
      };

      logStream.write(`\n${'─'.repeat(50)}\nFinalizado com código: ${code}\n`);
      logStream.end();

      saveHistoryRun({
        runId,
        scriptPath: resolvedPath,
        args,
        startedAt,
        endedAt,
        exitCode: code,
        success: code === 0,
        logFile,
      });

      mainWindow.webContents.send('script-output', {
        type: 'complete',
        data: `\n${'─'.repeat(50)}\nFinalizado com código: ${code}\n`,
        exitCode: code
      });

      currentProcess = null;
      currentRunId = null;

      resolve(result);
    });
  });
});

// Selecionar arquivo
ipcMain.handle('select-file', async (event, options = {}) => {
  const result = await dialog.showOpenDialog(mainWindow, {
    properties: ['openFile'],
    filters: options.filters || [
      { name: 'Scripts', extensions: ['ps1', 'sh'] },
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

ipcMain.handle('cancel-current', async () => {
  if (currentProcess) {
    currentProcess.kill();
    currentProcess = null;
    currentRunId = null;
    return { cancelled: true };
  }
  return { cancelled: false };
});

ipcMain.handle('get-settings', async () => {
  return getSettings();
});

ipcMain.handle('save-settings', async (event, settings) => {
  const merged = { ...getSettings(), ...settings };
  writeJsonSafe(SETTINGS_PATH, merged);
  return merged;
});

ipcMain.handle('get-profiles', async () => {
  return getProfiles();
});

ipcMain.handle('save-profiles', async (event, profiles) => {
  writeJsonSafe(PROFILES_PATH, profiles);
  return profiles;
});

ipcMain.handle('get-history', async () => {
  return getHistory();
});

ipcMain.handle('clear-history', async () => {
  writeJsonSafe(HISTORY_PATH, { runs: [] });
  return { cleared: true };
});

ipcMain.handle('resolve-report-path', async (event, tenantName) => {
  const date = new Date().toISOString().slice(0, 10);
  const safeTenant = (tenantName || 'default').replace(/[^a-zA-Z0-9-_]/g, '_');
  const base = getSettings().reportBaseDir || REPORTS_DIR;
  const fullPath = path.join(base, safeTenant, date);
  ensureDirSync(fullPath);
  return fullPath;
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

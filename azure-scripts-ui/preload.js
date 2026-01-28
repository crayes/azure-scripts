/**
 * Preload Script - Ponte segura entre Main e Renderer
 * 
 * Este arquivo expõe uma API controlada para o renderer process
 * usando contextBridge. O renderer NÃO tem acesso direto ao Node.js.
 */

const { contextBridge, ipcRenderer } = require('electron');

// API exposta para o renderer (window.electronAPI)
contextBridge.exposeInMainWorld('electronAPI', {
  
  // ==================== Scripts ====================
  
  /**
   * Obter lista de scripts disponíveis
  * @returns {Promise<Array<{name, category, path, relativePath, type}>>}
   */
  getScripts: () => ipcRenderer.invoke('get-scripts'),
  
  /**
   * Executar um script PowerShell
   * @param {string} scriptPath - Caminho completo do script
   * @param {string[]} args - Argumentos opcionais
   * @returns {Promise<{exitCode, stdout, stderr, success}>}
   */
  runScript: (scriptPath, args = []) => ipcRenderer.invoke('run-script', scriptPath, args),

  /**
   * Cancelar execução atual
   * @returns {Promise<{cancelled: boolean}>}
   */
  cancelCurrent: () => ipcRenderer.invoke('cancel-current'),
  
  /**
   * Ler conteúdo de um script
   * @param {string} scriptPath - Caminho do script
   * @returns {Promise<string>}
   */
  readScript: (scriptPath) => ipcRenderer.invoke('read-script', scriptPath),

  /**
   * Obter metadados de um script
   * @param {string} scriptPath
   * @returns {Promise<{args: Array, description: string, requires: {version: string|null, modules: string[]}}>} 
   */
  getScriptMetadata: (scriptPath) => ipcRenderer.invoke('get-script-metadata', scriptPath),

  /**
   * Obter manifesto de scripts (metadados e workflows)
   * @returns {Promise<{scripts: Object, workflows: Array}>}
   */
  getManifest: () => ipcRenderer.invoke('get-manifest'),
  
  /**
   * Registrar callback para output em tempo real
   * @param {Function} callback - Função chamada com {type, data}
   * @returns {Function} - Função para remover listener
   */
  onScriptOutput: (callback) => {
    const handler = (event, data) => callback(data);
    ipcRenderer.on('script-output', handler);
    return () => ipcRenderer.removeListener('script-output', handler);
  },
  
  // ==================== Sistema ====================
  
  /**
   * Obter informações do sistema
   * @returns {Promise<{platform, arch, nodeVersion, electronVersion, powershell, homeDir, hostname}>}
   */
  getSystemInfo: () => ipcRenderer.invoke('get-system-info'),
  
  /**
   * Verificar se PowerShell está disponível
   * @returns {Promise<{available, executable, version}>}
   */
  checkPowerShell: () => ipcRenderer.invoke('check-powershell'),

  /**
   * Configurações e perfis
   */
  getSettings: () => ipcRenderer.invoke('get-settings'),
  saveSettings: (settings) => ipcRenderer.invoke('save-settings', settings),
  getProfiles: () => ipcRenderer.invoke('get-profiles'),
  saveProfiles: (profiles) => ipcRenderer.invoke('save-profiles', profiles),
  getHistory: () => ipcRenderer.invoke('get-history'),
  clearHistory: () => ipcRenderer.invoke('clear-history'),
  resolveReportPath: (tenantName) => ipcRenderer.invoke('resolve-report-path', tenantName),
  
  // ==================== Diálogos ====================
  
  /**
   * Abrir diálogo para selecionar arquivo
   * @param {Object} options - Opções do diálogo
   * @returns {Promise<string|null>}
   */
  selectFile: (options) => ipcRenderer.invoke('select-file', options),
  
  /**
   * Abrir diálogo para selecionar diretório
   * @returns {Promise<string|null>}
   */
  selectDirectory: () => ipcRenderer.invoke('select-directory'),
  
  // ==================== Versões (acesso síncrono) ====================
  
  versions: {
    node: process.versions.node,
    electron: process.versions.electron,
    chrome: process.versions.chrome,
  }
});

console.log('✅ Preload carregado - electronAPI disponível no renderer');

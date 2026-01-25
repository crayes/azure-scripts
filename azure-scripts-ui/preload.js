/**
 * Preload Script - Ponte segura entre main e renderer
 * 
 * Este script expõe APIs seguras para o renderer process usando contextBridge.
 * O renderer NÃO tem acesso direto ao Node.js, apenas às funções expostas aqui.
 */

const { contextBridge, ipcRenderer } = require('electron');

// Expor API segura para o renderer
contextBridge.exposeInMainWorld('electronAPI', {
  // ==================== Scripts PowerShell ====================
  
  /**
   * Executar um script PowerShell
   * @param {string} scriptPath - Caminho relativo do script (ex: 'scripts/Exchange/Exchange-Audit.ps1')
   * @param {string[]} args - Argumentos para o script
   * @returns {Promise<{success: boolean, stdout: string, stderr: string, code: number}>}
   */
  executeScript: (scriptPath, args = []) => {
    return ipcRenderer.invoke('execute-script', scriptPath, args);
  },

  /**
   * Verificar se PowerShell está disponível
   * @returns {Promise<{available: boolean, version: string|null, executable: string}>}
   */
  checkPowerShell: () => {
    return ipcRenderer.invoke('check-powershell');
  },

  /**
   * Listar scripts disponíveis no repositório
   * @returns {Promise<Array<{name: string, category: string, path: string, fullPath: string}>>}
   */
  listScripts: () => {
    return ipcRenderer.invoke('list-scripts');
  },

  // ==================== Sistema de Arquivos ====================

  /**
   * Abrir diálogo para selecionar pasta de output
   * @returns {Promise<string|null>}
   */
  selectOutputFolder: () => {
    return ipcRenderer.invoke('select-output-folder');
  },

  /**
   * Abrir arquivo ou pasta no explorador do sistema
   * @param {string} filePath - Caminho do arquivo/pasta
   * @returns {Promise<boolean>}
   */
  openPath: (filePath) => {
    return ipcRenderer.invoke('open-path', filePath);
  },

  // ==================== Informações do Sistema ====================

  /**
   * Obter informações do sistema
   * @returns {Promise<{platform: string, arch: string, nodeVersion: string, electronVersion: string, appVersion: string, appPath: string}>}
   */
  getSystemInfo: () => {
    return ipcRenderer.invoke('get-system-info');
  },

  // ==================== Eventos em Tempo Real ====================

  /**
   * Registrar callback para output de scripts em tempo real
   * @param {function} callback - Função chamada com {type: 'stdout'|'stderr', data: string}
   * @returns {function} - Função para remover o listener
   */
  onScriptOutput: (callback) => {
    const handler = (event, data) => callback(data);
    ipcRenderer.on('script-output', handler);
    // Retornar função para cleanup
    return () => ipcRenderer.removeListener('script-output', handler);
  },

  // ==================== Versões ====================
  
  versions: {
    node: process.versions.node,
    electron: process.versions.electron,
    chrome: process.versions.chrome
  }
});

console.log('Preload script loaded - electronAPI exposed to renderer');

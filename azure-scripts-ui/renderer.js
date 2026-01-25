/**
 * Renderer Script - Interface do usuário
 * 
 * Este script roda no processo renderer e usa a API segura
 * exposta pelo preload.js (window.electronAPI)
 */

// Estado da aplicação
const state = {
  scripts: [],
  selectedScript: null,
  isRunning: false,
  outputCleanup: null,
  powerShellInfo: null
};

// ==================== Inicialização ====================

document.addEventListener('DOMContentLoaded', async () => {
  console.log('Azure Scripts UI initialized');
  
  // Exibir versões
  displayVersions();
  
  // Verificar PowerShell
  await checkPowerShellStatus();
  
  // Carregar lista de scripts
  await loadScripts();
  
  // Configurar event listeners
  setupEventListeners();
  
  // Registrar listener de output em tempo real
  state.outputCleanup = window.electronAPI.onScriptOutput(handleScriptOutput);
});

// Cleanup ao fechar
window.addEventListener('beforeunload', () => {
  if (state.outputCleanup) {
    state.outputCleanup();
  }
});

// ==================== Funções de UI ====================

function displayVersions() {
  const versions = window.electronAPI.versions;
  document.getElementById('electron-version').textContent = versions.electron;
  document.getElementById('node-version').textContent = versions.node;
}

async function checkPowerShellStatus() {
  const statusEl = document.getElementById('powershell-status');
  
  try {
    state.powerShellInfo = await window.electronAPI.checkPowerShell();
    
    if (state.powerShellInfo.available) {
      statusEl.innerHTML = `
        <span class="status-ok">✅ PowerShell ${state.powerShellInfo.version}</span>
        <small>(${state.powerShellInfo.executable})</small>
      `;
      statusEl.className = 'status-badge status-ok';
    } else {
      statusEl.innerHTML = `
        <span class="status-error">❌ PowerShell não encontrado</span>
        <small>Instale o <a href="https://github.com/PowerShell/PowerShell" target="_blank">PowerShell Core</a></small>
      `;
      statusEl.className = 'status-badge status-error';
    }
  } catch (error) {
    statusEl.innerHTML = `<span class="status-error">❌ Erro ao verificar PowerShell</span>`;
    statusEl.className = 'status-badge status-error';
    console.error('Erro ao verificar PowerShell:', error);
  }
}

async function loadScripts() {
  const scriptsContainer = document.getElementById('scripts-list');
  
  try {
    state.scripts = await window.electronAPI.listScripts();
    
    if (state.scripts.length === 0) {
      scriptsContainer.innerHTML = '<p class="no-scripts">Nenhum script encontrado</p>';
      return;
    }

    // Agrupar por categoria
    const grouped = state.scripts.reduce((acc, script) => {
      if (!acc[script.category]) acc[script.category] = [];
      acc[script.category].push(script);
      return acc;
    }, {});

    // Renderizar
    scriptsContainer.innerHTML = Object.entries(grouped)
      .map(([category, scripts]) => `
        <div class="script-category">
          <h4 class="category-title">${getCategoryIcon(category)} ${category}</h4>
          <div class="scripts-in-category">
            ${scripts.map(script => `
              <div class="script-item" data-path="${script.path}" title="${script.path}">
                <span class="script-icon">📜</span>
                <span class="script-name">${script.name}</span>
              </div>
            `).join('')}
          </div>
        </div>
      `).join('');

    // Adicionar event listeners aos scripts
    document.querySelectorAll('.script-item').forEach(item => {
      item.addEventListener('click', () => selectScript(item.dataset.path));
    });

  } catch (error) {
    scriptsContainer.innerHTML = `<p class="error">Erro ao carregar scripts: ${error.message}</p>`;
    console.error('Erro ao carregar scripts:', error);
  }
}

function getCategoryIcon(category) {
  const icons = {
    'Exchange': '📧',
    'EntraID': '🔐',
    'OneDrive': '☁️',
    'SharePoint': '📁',
    'Purview': '🛡️',
    'DNS': '🌐',
    'HybridIdentity': '🔄',
    'Remediation': '🔧',
    'Root': '📂'
  };
  return icons[category] || '📁';
}

function selectScript(scriptPath) {
  // Remover seleção anterior
  document.querySelectorAll('.script-item').forEach(item => {
    item.classList.remove('selected');
  });

  // Selecionar novo
  const item = document.querySelector(`.script-item[data-path="${scriptPath}"]`);
  if (item) {
    item.classList.add('selected');
  }

  state.selectedScript = state.scripts.find(s => s.path === scriptPath);
  
  // Atualizar UI
  document.getElementById('selected-script-name').textContent = state.selectedScript?.name || 'Nenhum';
  document.getElementById('run-script-btn').disabled = !state.selectedScript || !state.powerShellInfo?.available;
  
  // Limpar output anterior
  clearOutput();
}

function setupEventListeners() {
  // Botão executar
  document.getElementById('run-script-btn').addEventListener('click', executeSelectedScript);
  
  // Botão limpar output
  document.getElementById('clear-output-btn').addEventListener('click', clearOutput);
  
  // Botão selecionar pasta
  document.getElementById('select-folder-btn')?.addEventListener('click', selectOutputFolder);
  
  // Feature cards (placeholder para futuras implementações)
  document.querySelectorAll('.feature-card').forEach(card => {
    card.addEventListener('click', () => {
      const feature = card.querySelector('h4').textContent;
      showNotification(`Recurso "${feature}" será implementado em breve!`, 'info');
    });
  });
}

// ==================== Execução de Scripts ====================

async function executeSelectedScript() {
  if (!state.selectedScript || state.isRunning) return;

  const outputEl = document.getElementById('script-output');
  const runBtn = document.getElementById('run-script-btn');
  
  state.isRunning = true;
  runBtn.disabled = true;
  runBtn.innerHTML = '<span class="spinner"></span> Executando...';
  
  // Limpar e preparar output
  outputEl.innerHTML = '';
  appendOutput(`[${new Date().toLocaleTimeString()}] Iniciando: ${state.selectedScript.name}\n`, 'info');
  appendOutput(`Caminho: ${state.selectedScript.path}\n`, 'info');
  appendOutput('─'.repeat(60) + '\n', 'separator');

  try {
    const result = await window.electronAPI.executeScript(state.selectedScript.path);
    
    appendOutput('\n' + '─'.repeat(60) + '\n', 'separator');
    
    if (result.success) {
      appendOutput(`[${new Date().toLocaleTimeString()}] ✅ Script finalizado com sucesso (código: ${result.code})\n`, 'success');
    } else {
      appendOutput(`[${new Date().toLocaleTimeString()}] ⚠️ Script finalizado com código: ${result.code}\n`, 'warning');
    }
    
  } catch (error) {
    appendOutput(`\n❌ ERRO: ${error.message}\n`, 'error');
    showNotification(`Erro ao executar script: ${error.message}`, 'error');
  } finally {
    state.isRunning = false;
    runBtn.disabled = !state.selectedScript;
    runBtn.innerHTML = '▶️ Executar Script';
  }
}

function handleScriptOutput(data) {
  const type = data.type === 'stderr' ? 'error' : 'stdout';
  appendOutput(data.data, type);
}

function appendOutput(text, type = 'stdout') {
  const outputEl = document.getElementById('script-output');
  const span = document.createElement('span');
  span.className = `output-${type}`;
  span.textContent = text;
  outputEl.appendChild(span);
  
  // Auto-scroll
  outputEl.scrollTop = outputEl.scrollHeight;
}

function clearOutput() {
  const outputEl = document.getElementById('script-output');
  outputEl.innerHTML = '<span class="output-info">Output do script aparecerá aqui...</span>';
}

// ==================== Outras Funções ====================

async function selectOutputFolder() {
  try {
    const folder = await window.electronAPI.selectOutputFolder();
    if (folder) {
      document.getElementById('output-folder-path').textContent = folder;
      showNotification(`Pasta selecionada: ${folder}`, 'success');
    }
  } catch (error) {
    showNotification(`Erro ao selecionar pasta: ${error.message}`, 'error');
  }
}

function showNotification(message, type = 'info') {
  const container = document.getElementById('notifications') || createNotificationContainer();
  
  const notification = document.createElement('div');
  notification.className = `notification notification-${type}`;
  notification.innerHTML = `
    <span class="notification-icon">${type === 'error' ? '❌' : type === 'success' ? '✅' : 'ℹ️'}</span>
    <span class="notification-message">${message}</span>
  `;
  
  container.appendChild(notification);
  
  // Auto-remove após 5 segundos
  setTimeout(() => {
    notification.classList.add('fade-out');
    setTimeout(() => notification.remove(), 300);
  }, 5000);
}

function createNotificationContainer() {
  const container = document.createElement('div');
  container.id = 'notifications';
  document.body.appendChild(container);
  return container;
}

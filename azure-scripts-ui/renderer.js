/**
 * Renderer Script - Interface do Usuário
 * 
 * Usa window.electronAPI exposta pelo preload.js
 * NÃO tem acesso direto ao Node.js (segurança)
 */

// ==================== Estado da Aplicação ====================

const state = {
  scripts: [],
  selectedScript: null,
  isRunning: false,
  systemInfo: null,
  psInfo: null,
  outputCleanup: null,
};

// ==================== Inicialização ====================

document.addEventListener('DOMContentLoaded', async () => {
  console.log('🚀 Azure Scripts UI inicializando...');
  
  // Configurar versões
  displayVersions();
  
  // Carregar informações do sistema
  await loadSystemInfo();
  
  // Verificar PowerShell
  await checkPowerShell();
  
  // Carregar scripts
  await loadScripts();
  
  // Configurar listeners
  setupEventListeners();
  
  // Registrar listener de output
  state.outputCleanup = window.electronAPI.onScriptOutput(handleScriptOutput);
  
  console.log('✅ Inicialização completa');
});

// Cleanup
window.addEventListener('beforeunload', () => {
  if (state.outputCleanup) state.outputCleanup();
});

// ==================== Funções de Carregamento ====================

function displayVersions() {
  const v = window.electronAPI.versions;
  document.getElementById('electron-version').textContent = v.electron;
  document.getElementById('node-version').textContent = v.node;
}

async function loadSystemInfo() {
  try {
    state.systemInfo = await window.electronAPI.getSystemInfo();
    console.log('Sistema:', state.systemInfo);
  } catch (error) {
    console.error('Erro ao carregar info do sistema:', error);
  }
}

async function checkPowerShell() {
  const statusEl = document.getElementById('ps-status');
  
  try {
    state.psInfo = await window.electronAPI.checkPowerShell();
    
    if (state.psInfo.available) {
      statusEl.innerHTML = `<span class="status-ok">✅ ${state.psInfo.executable}</span>`;
      statusEl.title = state.psInfo.version;
    } else {
      statusEl.innerHTML = `<span class="status-error">❌ PowerShell não encontrado</span>`;
      showNotification('PowerShell não encontrado. Instale o PowerShell Core.', 'error');
    }
  } catch (error) {
    statusEl.innerHTML = `<span class="status-error">❌ Erro</span>`;
    console.error('Erro ao verificar PowerShell:', error);
  }
}

async function loadScripts() {
  const container = document.getElementById('scripts-list');
  
  try {
    state.scripts = await window.electronAPI.getScripts();
    
    if (state.scripts.length === 0) {
      container.innerHTML = '<p class="empty-state">Nenhum script encontrado</p>';
      return;
    }
    
    // Agrupar por categoria
    const grouped = state.scripts.reduce((acc, script) => {
      if (!acc[script.category]) acc[script.category] = [];
      acc[script.category].push(script);
      return acc;
    }, {});
    
    // Renderizar
    container.innerHTML = Object.entries(grouped)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([category, scripts]) => `
        <div class="script-category">
          <h4 class="category-header">${getCategoryIcon(category)} ${category}</h4>
          <ul class="script-list">
            ${scripts.map(s => `
              <li class="script-item" data-path="${escapeHtml(s.path)}" title="${escapeHtml(s.relativePath)}">
                <span class="script-icon">📄</span>
                <span class="script-name">${escapeHtml(s.name)}</span>
              </li>
            `).join('')}
          </ul>
        </div>
      `).join('');
    
    // Event listeners
    container.querySelectorAll('.script-item').forEach(item => {
      item.addEventListener('click', () => selectScript(item.dataset.path));
    });
    
    console.log(`📜 ${state.scripts.length} scripts carregados`);
    
  } catch (error) {
    container.innerHTML = `<p class="error-state">Erro ao carregar scripts: ${error.message}</p>`;
    console.error('Erro ao carregar scripts:', error);
  }
}

// ==================== Seleção e Execução ====================

function selectScript(scriptPath) {
  // Limpar seleção anterior
  document.querySelectorAll('.script-item.selected').forEach(el => {
    el.classList.remove('selected');
  });
  
  // Selecionar novo
  const item = document.querySelector(`.script-item[data-path="${CSS.escape(scriptPath)}"]`);
  if (item) item.classList.add('selected');
  
  state.selectedScript = state.scripts.find(s => s.path === scriptPath);
  
  // Atualizar UI
  const nameEl = document.getElementById('selected-script');
  const runBtn = document.getElementById('run-btn');
  const viewBtn = document.getElementById('view-btn');
  
  if (state.selectedScript) {
    nameEl.textContent = state.selectedScript.name;
    runBtn.disabled = !state.psInfo?.available;
    viewBtn.disabled = false;
  } else {
    nameEl.textContent = 'Nenhum script selecionado';
    runBtn.disabled = true;
    viewBtn.disabled = true;
  }
}

async function runSelectedScript() {
  if (!state.selectedScript || state.isRunning) return;
  
  state.isRunning = true;
  updateRunButton(true);
  clearOutput();
  
  try {
    const result = await window.electronAPI.runScript(state.selectedScript.path);
    
    if (result.success) {
      showNotification('Script executado com sucesso!', 'success');
    } else {
      showNotification(`Script finalizado com código ${result.exitCode}`, 'warning');
    }
  } catch (error) {
    appendOutput(`\n❌ ERRO: ${error.message}\n`, 'error');
    showNotification(`Erro: ${error.message}`, 'error');
  } finally {
    state.isRunning = false;
    updateRunButton(false);
  }
}

async function viewSelectedScript() {
  if (!state.selectedScript) return;
  
  try {
    const content = await window.electronAPI.readScript(state.selectedScript.path);
    showScriptModal(state.selectedScript.name, content);
  } catch (error) {
    showNotification(`Erro ao ler script: ${error.message}`, 'error');
  }
}

// ==================== Output ====================

function handleScriptOutput(data) {
  const typeMap = {
    'stdout': 'output',
    'stderr': 'error',
    'info': 'info',
    'complete': data.exitCode === 0 ? 'success' : 'warning',
    'error': 'error',
  };
  appendOutput(data.data, typeMap[data.type] || 'output');
}

function appendOutput(text, type = 'output') {
  const outputEl = document.getElementById('output');
  const span = document.createElement('span');
  span.className = `output-${type}`;
  span.textContent = text;
  outputEl.appendChild(span);
  outputEl.scrollTop = outputEl.scrollHeight;
}

function clearOutput() {
  document.getElementById('output').innerHTML = '';
}

// ==================== UI Helpers ====================

function updateRunButton(running) {
  const btn = document.getElementById('run-btn');
  if (running) {
    btn.innerHTML = '<span class="spinner"></span> Executando...';
    btn.disabled = true;
  } else {
    btn.innerHTML = '▶️ Executar';
    btn.disabled = !state.selectedScript || !state.psInfo?.available;
  }
}

function setupEventListeners() {
  document.getElementById('run-btn').addEventListener('click', runSelectedScript);
  document.getElementById('view-btn').addEventListener('click', viewSelectedScript);
  document.getElementById('clear-btn').addEventListener('click', clearOutput);
  
  // Feature cards
  document.querySelectorAll('.feature-card').forEach(card => {
    card.addEventListener('click', () => {
      const feature = card.querySelector('h4')?.textContent;
      showNotification(`"${feature}" - Em desenvolvimento`, 'info');
    });
  });
}

function getCategoryIcon(category) {
  const icons = {
    'Exchange': '📧',
    'EntraID': '🔐',
    'Entra': '🔐',
    'OneDrive': '☁️',
    'SharePoint': '📁',
    'Purview': '🛡️',
    'DNS': '🌐',
    'HybridIdentity': '🔄',
    'Remediation': '🔧',
    'Root': '📂',
  };
  return icons[category] || '📁';
}

function escapeHtml(text) {
  const div = document.createElement('div');
  div.textContent = text;
  return div.innerHTML;
}

// ==================== Notificações ====================

function showNotification(message, type = 'info') {
  const container = document.getElementById('notifications') || createNotificationsContainer();
  
  const notification = document.createElement('div');
  notification.className = `notification notification-${type}`;
  
  const icons = { success: '✅', error: '❌', warning: '⚠️', info: 'ℹ️' };
  notification.innerHTML = `
    <span class="notif-icon">${icons[type] || icons.info}</span>
    <span class="notif-message">${escapeHtml(message)}</span>
    <button class="notif-close" onclick="this.parentElement.remove()">×</button>
  `;
  
  container.appendChild(notification);
  
  // Auto-remover após 5s
  setTimeout(() => {
    notification.classList.add('fade-out');
    setTimeout(() => notification.remove(), 300);
  }, 5000);
}

function createNotificationsContainer() {
  const container = document.createElement('div');
  container.id = 'notifications';
  document.body.appendChild(container);
  return container;
}

// ==================== Modal de Visualização ====================

function showScriptModal(title, content) {
  // Remover modal existente
  document.getElementById('script-modal')?.remove();
  
  const modal = document.createElement('div');
  modal.id = 'script-modal';
  modal.className = 'modal-overlay';
  modal.innerHTML = `
    <div class="modal-content">
      <div class="modal-header">
        <h3>📄 ${escapeHtml(title)}</h3>
        <button class="modal-close" onclick="document.getElementById('script-modal').remove()">×</button>
      </div>
      <pre class="modal-body"><code>${escapeHtml(content)}</code></pre>
    </div>
  `;
  
  modal.addEventListener('click', (e) => {
    if (e.target === modal) modal.remove();
  });
  
  document.body.appendChild(modal);
}

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
  manifest: { scripts: {}, workflows: [] },
  paramValues: {},
  settings: { organizeReports: true, reportBaseDir: '' },
  profiles: { profiles: {} },
  history: { runs: [] },
  scriptMetaCache: {},
  queue: [],
  isQueueRunning: false,
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

  // Carregar manifesto (metadados e workflows)
  await loadManifest();

  // Carregar configurações, perfis e histórico
  await loadSettings();
  await loadProfiles();
  await loadHistory();
  
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

async function loadManifest() {
  try {
    const manifest = await window.electronAPI.getManifest();
    state.manifest = manifest || { scripts: {}, workflows: [] };
  } catch (error) {
    console.error('Erro ao carregar manifesto:', error);
    state.manifest = { scripts: {}, workflows: [] };
  }

  renderWorkflows();
}

async function loadSettings() {
  try {
    state.settings = await window.electronAPI.getSettings();
  } catch (error) {
    console.error('Erro ao carregar configurações:', error);
  }

  renderSettings();
}

async function loadProfiles() {
  try {
    state.profiles = await window.electronAPI.getProfiles();
  } catch (error) {
    console.error('Erro ao carregar perfis:', error);
  }
}

async function loadHistory() {
  try {
    state.history = await window.electronAPI.getHistory();
  } catch (error) {
    console.error('Erro ao carregar histórico:', error);
  }

  renderHistory();
  renderQueue();
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
            ${scripts.map(s => {
              const lastRun = getLastRunForScript(s);
              const statusClass = lastRun ? (lastRun.success ? 'status-success' : 'status-fail') : 'status-none';
              const statusTitle = lastRun ? `Última execução: ${formatDateTime(lastRun.endedAt)} (${lastRun.success ? 'sucesso' : 'falha'})` : 'Sem execução recente';
              return `
                <li class="script-item" data-path="${escapeHtml(s.path)}" title="${escapeHtml(s.relativePath)}">
                  <span class="script-icon">${getScriptIcon(s.type)}</span>
                  <span class="script-name">${escapeHtml(s.name)}</span>
                  <span class="script-type">${escapeHtml((s.type || '').toUpperCase())}</span>
                  <span class="script-status ${statusClass}" title="${escapeHtml(statusTitle)}"></span>
                </li>
              `;
            }).join('')}
          </ul>
        </div>
      `).join('');
    
    // Event listeners
    container.querySelectorAll('.script-item').forEach(item => {
      item.addEventListener('click', async () => selectScript(item.dataset.path));
    });
    
    console.log(`📜 ${state.scripts.length} scripts carregados`);
    
  } catch (error) {
    container.innerHTML = `<p class="error-state">Erro ao carregar scripts: ${error.message}</p>`;
    console.error('Erro ao carregar scripts:', error);
  }
}

// ==================== Seleção e Execução ====================

async function selectScript(scriptPath) {
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
  const queueAddBtn = document.getElementById('queue-add-btn');
  
  if (state.selectedScript) {
    nameEl.textContent = state.selectedScript.name;
    runBtn.disabled = !state.psInfo?.available;
    viewBtn.disabled = false;
    if (queueAddBtn) queueAddBtn.disabled = !state.psInfo?.available;
    await ensureScriptMetadata(state.selectedScript);
    renderScriptDetails(state.selectedScript);
  } else {
    nameEl.textContent = 'Nenhum script selecionado';
    runBtn.disabled = true;
    viewBtn.disabled = true;
    if (queueAddBtn) queueAddBtn.disabled = true;
    renderScriptDetails(null);
  }
}

async function runSelectedScript() {
  if (!state.selectedScript || state.isRunning) return;

  const meta = getScriptMeta(state.selectedScript);
  if (meta?.args?.length) {
    const values = state.paramValues[state.selectedScript.relativePath] || {};
    const missing = meta.args.filter(p => p.required && !values[p.key]);
    if (missing.length > 0) {
      showNotification('Preencha os parâmetros obrigatórios.', 'warning');
      return;
    }
  }
  
  state.isRunning = true;
  updateRunButton(true);
  toggleWorkflowButtons(true);
  toggleQueueButtons(true);
  clearOutput();
  
  try {
    const args = await buildArgsForScript(state.selectedScript);
    const result = await window.electronAPI.runScript(state.selectedScript.path, args);
    
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
    toggleWorkflowButtons(false);
    toggleQueueButtons(false);
    await loadHistory();
    await loadScripts();
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
  document.getElementById('queue-add-btn')?.addEventListener('click', addSelectedToQueue);
  document.getElementById('queue-run-btn')?.addEventListener('click', runQueue);
  document.getElementById('cancel-btn')?.addEventListener('click', cancelCurrentExecution);
  document.getElementById('history-clear-btn')?.addEventListener('click', clearHistory);
  document.getElementById('settings-save-btn')?.addEventListener('click', saveSettings);
  document.getElementById('settings-report-browse')?.addEventListener('click', selectReportBaseDir);
  
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

function getScriptIcon(type) {
  const icons = {
    'ps1': '⚡',
    'sh': '🐚',
  };
  return icons[(type || '').toLowerCase()] || '📄';
}

function escapeHtml(text) {
  const div = document.createElement('div');
  div.textContent = text;
  return div.innerHTML;
}

// ==================== Manifesto & Parâmetros ====================

function getScriptMeta(script) {
  if (!script) return null;
  return state.scriptMetaCache[script.relativePath] || null;
}

async function ensureScriptMetadata(script) {
  if (!script) return null;
  if (state.scriptMetaCache[script.relativePath]) return state.scriptMetaCache[script.relativePath];

  const manifestMeta = state.manifest?.scripts?.[script.relativePath] || {};
  let autoMeta = { args: [], description: '', requires: { version: null, modules: [] } };
  try {
    autoMeta = await window.electronAPI.getScriptMetadata(script.path);
  } catch (error) {
    console.error('Erro ao obter metadados do script:', error);
  }

  const merged = {
    ...autoMeta,
    ...manifestMeta,
    description: manifestMeta.description || autoMeta.description || '',
    args: manifestMeta.args || autoMeta.args || [],
    requires: {
      version: manifestMeta.requires?.version || autoMeta.requires?.version || null,
      modules: manifestMeta.requires?.modules || autoMeta.requires?.modules || []
    }
  };

  state.scriptMetaCache[script.relativePath] = merged;
  return merged;
}

function renderScriptDetails(script) {
  const descEl = document.getElementById('script-desc');
  const paramsContainer = document.getElementById('params-container');
  const reqContainer = document.getElementById('requirements-container');
  const profileContainer = document.getElementById('profile-controls');

  if (!script) {
    descEl.textContent = 'Selecione um script para ver detalhes.';
    paramsContainer.innerHTML = '<p class="empty-state">Nenhum parâmetro disponível.</p>';
    if (reqContainer) reqContainer.innerHTML = '<p class="empty-state">Nenhum requisito.</p>';
    if (profileContainer) profileContainer.innerHTML = '';
    return;
  }

  const meta = getScriptMeta(script);
  descEl.textContent = meta?.description || 'Sem descrição disponível.';

  renderRequirements(meta, script);
  renderProfiles(script, meta);

  if (!meta?.args || meta.args.length === 0) {
    paramsContainer.innerHTML = '<p class="empty-state">Nenhum parâmetro disponível.</p>';
    return;
  }

  if (!state.paramValues[script.relativePath]) {
    state.paramValues[script.relativePath] = {};
  }

  const values = state.paramValues[script.relativePath];

  paramsContainer.innerHTML = meta.args.map((param) => {
    const value = values[param.key] ?? param.default ?? '';
    if (param.type === 'switch') {
      const checked = value ? 'checked' : '';
      return `
        <div class="param-row">
          <label class="param-label">
            <input type="checkbox" data-param-key="${escapeHtml(param.key)}" ${checked}>
            ${escapeHtml(param.label || param.key)}
          </label>
          <span class="param-help">${escapeHtml(param.description || '')}</span>
        </div>
      `;
    }

    if (param.type === 'choice') {
      const options = (param.options || []).map(opt => {
        const selected = String(value) === String(opt.value) ? 'selected' : '';
        return `<option value="${escapeHtml(opt.value)}" ${selected}>${escapeHtml(opt.label || opt.value)}</option>`;
      }).join('');
      return `
        <div class="param-row">
          <label class="param-label">${escapeHtml(param.label || param.key)}</label>
          <select class="param-input" data-param-key="${escapeHtml(param.key)}">
            <option value="">Selecione...</option>
            ${options}
          </select>
          <span class="param-help">${escapeHtml(param.description || '')}</span>
        </div>
      `;
    }

    const inputType = param.type === 'number' ? 'number' : 'text';
    const placeholder = param.placeholder ? `placeholder="${escapeHtml(param.placeholder)}"` : '';
    const showBrowse = param.type === 'path';
    const pathKind = param.pathKind || 'file';

    return `
      <div class="param-row">
        <label class="param-label">${escapeHtml(param.label || param.key)}</label>
        <div class="param-input-row">
          <input class="param-input" type="${inputType}" data-param-key="${escapeHtml(param.key)}" value="${escapeHtml(value)}" ${placeholder}>
          ${showBrowse ? `<button class="btn btn-secondary btn-small" data-param-browse="${escapeHtml(param.key)}" data-path-kind="${escapeHtml(pathKind)}">📂</button>` : ''}
        </div>
        <span class="param-help">${escapeHtml(param.description || '')}</span>
      </div>
    `;
  }).join('');

  paramsContainer.querySelectorAll('[data-param-key]').forEach((input) => {
    const key = input.getAttribute('data-param-key');
    if (!key) return;

    const handler = () => {
      if (input.type === 'checkbox') {
        values[key] = input.checked;
      } else {
        values[key] = input.value;
      }
    };

    input.addEventListener('input', handler);
    input.addEventListener('change', handler);
  });

  paramsContainer.querySelectorAll('[data-param-browse]').forEach((button) => {
    button.addEventListener('click', async () => {
      const key = button.getAttribute('data-param-browse');
      const kind = button.getAttribute('data-path-kind');
      if (!key) return;

      let selected = null;
      if (kind === 'directory') {
        selected = await window.electronAPI.selectDirectory();
      } else {
        selected = await window.electronAPI.selectFile();
      }
      if (!selected) return;

      const input = paramsContainer.querySelector(`[data-param-key="${CSS.escape(key)}"]`);
      if (input) {
        input.value = selected;
        values[key] = selected;
      }
    });
  });
}

async function buildArgsForScript(script) {
  const meta = getScriptMeta(script);
  if (!meta?.args || meta.args.length === 0) return [];

  const values = state.paramValues[script.relativePath] || {};
  const resolved = { ...values };

  if (state.settings?.organizeReports) {
    const outputParam = meta.args.find(arg => ['OutputPath', 'ExportPath'].includes(arg.key));
    if (outputParam && !resolved[outputParam.key]) {
      const tenantName = resolved.TenantName || resolved.TenantId || '';
      const autoPath = await window.electronAPI.resolveReportPath(tenantName);
      resolved[outputParam.key] = autoPath;
    }
  }

  return buildArgsFromValues(meta, resolved);
}

function buildArgsFromValues(meta, values) {
  const args = [];

  meta.args.forEach((param) => {
    const value = values[param.key];
    if (param.type === 'switch') {
      if (value) args.push(param.flag);
      return;
    }

    if (param.type === 'positional') {
      if (value !== undefined && value !== null && String(value).trim() !== '') {
        args.push(String(value));
      }
      return;
    }

    if (value !== undefined && value !== null && String(value).trim() !== '') {
      if (param.flag) args.push(param.flag);
      args.push(String(value));
    }
  });

  return args;
}

async function applyAutoReportPath(meta, values) {
  const resolved = { ...values };
  const outputParam = meta.args?.find(arg => ['OutputPath', 'ExportPath'].includes(arg.key));
  if (outputParam && !resolved[outputParam.key]) {
    const tenantName = resolved.TenantName || resolved.TenantId || '';
    const autoPath = await window.electronAPI.resolveReportPath(tenantName);
    resolved[outputParam.key] = autoPath;
  }
  return resolved;
}

// ==================== Requisitos, Perfis, Histórico e Fila ====================

function normalizePath(value) {
  return (value || '').replace(/\\/g, '/');
}

function parseTenantList(value) {
  return (value || '')
    .split(/\r?\n|,|;/)
    .map(v => v.trim())
    .filter(Boolean);
}

function formatDateTime(value) {
  if (!value) return '-';
  const date = new Date(value);
  return date.toLocaleString();
}

function getLastRunForScript(script) {
  const runs = state.history?.runs || [];
  const target = normalizePath(script.relativePath);
  return runs.find(run => normalizePath(run.scriptPath || '').endsWith(target));
}

function renderRequirements(meta, script) {
  const reqContainer = document.getElementById('requirements-container');
  if (!reqContainer) return;

  const items = [];
  if (script.type === 'ps1') {
    items.push('PowerShell disponível');
  }
  if (script.type === 'sh') {
    items.push('Bash disponível');
  }
  if (meta?.requires?.version) {
    items.push(`PowerShell ${meta.requires.version}+`);
  }
  if (meta?.requires?.modules?.length) {
    items.push(`Módulos: ${meta.requires.modules.join(', ')}`);
  }
  if (meta?.requires?.permissions?.length) {
    items.push(`Permissões: ${meta.requires.permissions.join(', ')}`);
  }

  if (items.length === 0) {
    reqContainer.innerHTML = '<p class="empty-state">Nenhum requisito.</p>';
    return;
  }

  reqContainer.innerHTML = `<ul>${items.map(i => `<li>${escapeHtml(i)}</li>`).join('')}</ul>`;
}

function renderProfiles(script, meta) {
  const profileContainer = document.getElementById('profile-controls');
  if (!profileContainer) return;

  const rel = script.relativePath;
  const scriptProfiles = state.profiles?.profiles?.[rel] || {};
  const options = Object.keys(scriptProfiles).map(name => `<option value="${escapeHtml(name)}">${escapeHtml(name)}</option>`).join('');

  profileContainer.innerHTML = `
    <div class="profile-row">
      <label>Perfil:</label>
      <select id="profile-select" class="param-input">
        <option value="">Selecione...</option>
        ${options}
      </select>
      <button class="btn btn-secondary btn-small" id="profile-apply">Aplicar</button>
      <button class="btn btn-secondary btn-small" id="profile-save">Salvar</button>
      <button class="btn btn-ghost btn-small" id="profile-delete">Excluir</button>
    </div>
  `;

  profileContainer.querySelector('#profile-apply')?.addEventListener('click', () => {
    const name = profileContainer.querySelector('#profile-select')?.value;
    if (!name) return;
    const values = scriptProfiles[name];
    state.paramValues[rel] = { ...(values || {}) };
    renderScriptDetails(script);
  });

  profileContainer.querySelector('#profile-save')?.addEventListener('click', async () => {
    const name = window.prompt('Nome do perfil');
    if (!name) return;
    if (!state.paramValues[rel]) state.paramValues[rel] = {};
    const updated = { ...state.profiles };
    updated.profiles = updated.profiles || {};
    updated.profiles[rel] = updated.profiles[rel] || {};
    updated.profiles[rel][name] = { ...state.paramValues[rel] };
    state.profiles = await window.electronAPI.saveProfiles(updated);
    renderProfiles(script, meta);
    showNotification('Perfil salvo.', 'success');
  });

  profileContainer.querySelector('#profile-delete')?.addEventListener('click', async () => {
    const name = profileContainer.querySelector('#profile-select')?.value;
    if (!name) return;
    const updated = { ...state.profiles };
    if (updated.profiles?.[rel]) {
      delete updated.profiles[rel][name];
      state.profiles = await window.electronAPI.saveProfiles(updated);
      renderProfiles(script, meta);
      showNotification('Perfil removido.', 'success');
    }
  });
}

function renderHistory() {
  const container = document.getElementById('history-list');
  if (!container) return;

  const runs = state.history?.runs || [];
  if (runs.length === 0) {
    container.innerHTML = '<p class="empty-state">Nenhuma execução registrada.</p>';
    return;
  }

  container.innerHTML = runs.slice(0, 20).map(run => {
    const statusClass = run.success ? 'history-success' : 'history-fail';
    return `
      <div class="history-item ${statusClass}">
        <div class="history-main">
          <strong>${escapeHtml(run.scriptPath?.split('/').pop() || 'script')}</strong>
          <span>${escapeHtml(formatDateTime(run.endedAt))}</span>
        </div>
        <div class="history-sub">
          <span>Código: ${run.exitCode}</span>
          <span>Log: ${escapeHtml(run.logFile || '')}</span>
        </div>
      </div>
    `;
  }).join('');
}

async function clearHistory() {
  await window.electronAPI.clearHistory();
  await loadHistory();
  await loadScripts();
}

function renderSettings() {
  const organizeToggle = document.getElementById('settings-organize-reports');
  const reportPathInput = document.getElementById('settings-report-path');
  if (organizeToggle) organizeToggle.checked = !!state.settings.organizeReports;
  if (reportPathInput) reportPathInput.value = state.settings.reportBaseDir || '';
}

async function saveSettings() {
  const organizeToggle = document.getElementById('settings-organize-reports');
  const reportPathInput = document.getElementById('settings-report-path');
  const updated = {
    organizeReports: organizeToggle?.checked ?? true,
    reportBaseDir: reportPathInput?.value || ''
  };
  state.settings = await window.electronAPI.saveSettings(updated);
  showNotification('Configurações salvas.', 'success');
}

async function selectReportBaseDir() {
  const selected = await window.electronAPI.selectDirectory();
  if (!selected) return;
  const input = document.getElementById('settings-report-path');
  if (input) input.value = selected;
}

async function addSelectedToQueue() {
  if (!state.selectedScript) return;
  const meta = getScriptMeta(state.selectedScript);
  if (meta?.args?.length) {
    const values = state.paramValues[state.selectedScript.relativePath] || {};
    const missing = meta.args.filter(p => p.required && !values[p.key]);
    if (missing.length > 0) {
      showNotification('Preencha os parâmetros obrigatórios.', 'warning');
      return;
    }
  }
  const args = await buildArgsForScript(state.selectedScript);
  state.queue.push({
    script: state.selectedScript,
    args,
    name: state.selectedScript.name,
  });
  renderQueue();
  showNotification('Adicionado à fila.', 'success');
}

function renderQueue() {
  const container = document.getElementById('queue-list');
  const runBtn = document.getElementById('queue-run-btn');
  if (runBtn) runBtn.disabled = state.queue.length === 0 || state.isRunning;
  if (!container) return;
  if (state.queue.length === 0) {
    container.innerHTML = '<p class="empty-state">Fila vazia.</p>';
    return;
  }

  container.innerHTML = state.queue.map((item, index) => `
    <div class="queue-item">
      <span>${escapeHtml(item.name)}</span>
      <button class="btn btn-ghost btn-small" data-queue-remove="${index}">Remover</button>
    </div>
  `).join('');

  container.querySelectorAll('[data-queue-remove]').forEach((btn) => {
    btn.addEventListener('click', () => {
      const idx = Number(btn.getAttribute('data-queue-remove'));
      state.queue.splice(idx, 1);
      renderQueue();
    });
  });
}

async function runQueue() {
  if (state.isRunning || state.isQueueRunning || state.queue.length === 0) return;
  state.isQueueRunning = true;
  state.isRunning = true;
  updateRunButton(true);
  toggleWorkflowButtons(true);
  toggleQueueButtons(true);
  clearOutput();
  appendOutput(`▶️ Executando fila (${state.queue.length} scripts)\n${'─'.repeat(50)}\n`, 'info');

  try {
    for (const item of state.queue) {
      appendOutput(`\n▶️ Script: ${item.name}\n${'─'.repeat(40)}\n`, 'info');
      const result = await window.electronAPI.runScript(item.script.path, item.args);
      if (!result.success) {
        showNotification(`Fila interrompida: ${item.name} retornou ${result.exitCode}`, 'warning');
        break;
      }
    }
  } catch (error) {
    appendOutput(`\n❌ ERRO: ${error.message}\n`, 'error');
    showNotification(`Erro: ${error.message}`, 'error');
  } finally {
    state.isQueueRunning = false;
    state.isRunning = false;
    updateRunButton(false);
    toggleWorkflowButtons(false);
    toggleQueueButtons(false);
    await loadHistory();
    await loadScripts();
  }
}

async function cancelCurrentExecution() {
  const result = await window.electronAPI.cancelCurrent();
  if (result?.cancelled) {
    showNotification('Execução cancelada.', 'warning');
  }
  state.queue = [];
  renderQueue();
}

function toggleQueueButtons(disabled) {
  document.querySelectorAll('#queue-add-btn, #queue-run-btn').forEach((btn) => {
    if (btn) btn.disabled = disabled;
  });
  const cancelBtn = document.getElementById('cancel-btn');
  if (cancelBtn) cancelBtn.disabled = !disabled;
}

// ==================== Workflows ====================

function renderWorkflows() {
  const container = document.getElementById('workflow-list');
  if (!container) return;

  const workflows = state.manifest?.workflows || [];
  if (workflows.length === 0) {
    container.innerHTML = '<p class="empty-state">Nenhum fluxo disponível.</p>';
    return;
  }

  container.innerHTML = workflows.map((wf) => {
    const steps = (wf.steps || []).map(step => {
      const scriptMeta = state.manifest?.scripts?.[step.script];
      const name = scriptMeta?.displayName || step.script;
      return `<li>${escapeHtml(name)}</li>`;
    }).join('');

    const inputs = (wf.inputs || []).map(input => {
      const required = input.required ? 'required' : '';
      const placeholder = input.placeholder ? `placeholder="${escapeHtml(input.placeholder)}"` : '';
      const inputKey = escapeHtml(input.key);
      if (input.type === 'textarea') {
        return `
          <div class="workflow-input">
            <label>${escapeHtml(input.label || input.key)}</label>
            <textarea class="param-input param-textarea" data-wf-input="${inputKey}" ${placeholder} ${required}></textarea>
          </div>
        `;
      }
      return `
        <div class="workflow-input">
          <label>${escapeHtml(input.label || input.key)}</label>
          <input class="param-input" data-wf-input="${inputKey}" ${placeholder} ${required}>
        </div>
      `;
    }).join('');

    return `
      <div class="workflow-card" data-workflow-id="${escapeHtml(wf.id)}">
        <div class="workflow-title">
          <h4>${escapeHtml(wf.name)}</h4>
          <p>${escapeHtml(wf.description || '')}</p>
        </div>
        ${inputs ? `<div class="workflow-inputs">${inputs}</div>` : ''}
        <div class="workflow-steps">
          <strong>Etapas:</strong>
          <ol>${steps}</ol>
        </div>
        <div class="workflow-actions">
          <button class="btn btn-primary workflow-run-btn">▶️ Executar fluxo</button>
        </div>
      </div>
    `;
  }).join('');

  container.querySelectorAll('.workflow-run-btn').forEach((btn) => {
    btn.addEventListener('click', async (event) => {
      const card = event.target.closest('.workflow-card');
      const workflowId = card?.getAttribute('data-workflow-id');
      if (!workflowId) return;
      await runWorkflow(workflowId, card);
    });
  });
}

async function runWorkflow(workflowId, card) {
  if (state.isRunning) return;

  const workflow = (state.manifest?.workflows || []).find(wf => wf.id === workflowId);
  if (!workflow) return;

  const inputs = {};
  (workflow.inputs || []).forEach((input) => {
    const el = card.querySelector(`[data-wf-input="${CSS.escape(input.key)}"]`);
    inputs[input.key] = el?.value || '';
  });

  const missing = (workflow.inputs || []).filter(i => i.required && !inputs[i.key]);
  if (missing.length > 0) {
    showNotification('Preencha os campos obrigatórios do fluxo.', 'warning');
    return;
  }

  state.isRunning = true;
  updateRunButton(true);
  toggleWorkflowButtons(true);
  toggleQueueButtons(true);
  clearOutput();
  appendOutput(`▶️ Fluxo: ${workflow.name}\n${'─'.repeat(50)}\n`, 'info');

  try {
    const tenants = workflow.multiTenant ? parseTenantList(inputs.Tenants || '') : [inputs.TenantName || ''];
    if (workflow.multiTenant && tenants.length === 0) {
      showNotification('Informe ao menos um tenant válido.', 'warning');
      return;
    }

    for (const tenant of tenants) {
      if (workflow.multiTenant) {
        appendOutput(`\n🏷️ Tenant: ${tenant}\n${'─'.repeat(50)}\n`, 'info');
      }

      for (const step of workflow.steps || []) {
        const script = state.scripts.find(s => s.relativePath === step.script);
        if (!script) {
          appendOutput(`\n❌ Script não encontrado: ${step.script}\n`, 'error');
          break;
        }

        await ensureScriptMetadata(script);
        const meta = getScriptMeta(script);
        const baseInputs = workflow.multiTenant ? { ...inputs, TenantName: tenant } : inputs;
        let stepValues = resolveWorkflowArgs(step.args || {}, baseInputs);
        if (state.settings?.organizeReports && meta?.args) {
          stepValues = await applyAutoReportPath(meta, stepValues);
        }
        const args = meta?.args ? buildArgsFromValues(meta, stepValues) : [];

        appendOutput(`\n▶️ Etapa: ${script.name}\n${'─'.repeat(40)}\n`, 'info');
        const result = await window.electronAPI.runScript(script.path, args);
        if (!result.success) {
          showNotification(`Fluxo interrompido: ${script.name} retornou ${result.exitCode}`, 'warning');
          break;
        }
      }
    }

    showNotification('Fluxo finalizado.', 'success');
  } catch (error) {
    appendOutput(`\n❌ ERRO: ${error.message}\n`, 'error');
    showNotification(`Erro: ${error.message}`, 'error');
  } finally {
    state.isRunning = false;
    updateRunButton(false);
    toggleWorkflowButtons(false);
    toggleQueueButtons(false);
    await loadHistory();
    await loadScripts();
  }
}

function resolveWorkflowArgs(args = {}, inputs = {}) {
  const resolved = {};
  Object.entries(args).forEach(([key, value]) => {
    if (typeof value === 'string' && value.startsWith('$')) {
      const inputKey = value.substring(1);
      resolved[key] = inputs[inputKey] ?? '';
    } else {
      resolved[key] = value;
    }
  });
  return resolved;
}

function toggleWorkflowButtons(disabled) {
  document.querySelectorAll('.workflow-run-btn').forEach((btn) => {
    btn.disabled = disabled;
  });
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

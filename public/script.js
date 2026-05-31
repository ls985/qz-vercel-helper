const STORAGE_KEY = 'qz-helper-config-v2';
const LOG_KEY = 'qz-helper-logs-v2';
const EARLY_START_MS = 5000;

const defaultConfig = {
  cookie: '',
  authorization: '',
  lib_id: '',
  open_time: '07:00:00',
  fast_interval: 0.8,
  slow_interval: 3,
  ntfy_topic: '',
  captcha: '',
};

const state = {
  config: { ...defaultConfig },
  timer: null,
  countdownTimer: null,
  running: false,
  mode: 'idle',
  rounds: 0,
  wakeLock: null,
  backoffMs: 0,
};

const $ = (id) => document.getElementById(id);

const els = {
  healthStatus: $('healthStatus'),
  countdown: $('countdown'),
  modeText: $('modeText'),
  stateText: $('stateText'),
  summaryLib: $('summaryLib'),
  summaryCookie: $('summaryCookie'),
  summaryOpenTime: $('summaryOpenTime'),
  summaryRounds: $('summaryRounds'),
  scheduleBtn: $('scheduleBtn'),
  leakBtn: $('leakBtn'),
  onceBtn: $('onceBtn'),
  stopBtn: $('stopBtn'),
  configForm: $('configForm'),
  cookieInput: $('cookieInput'),
  authorizationInput: $('authorizationInput'),
  libIdInput: $('libIdInput'),
  openTimeInput: $('openTimeInput'),
  captchaInput: $('captchaInput'),
  fastIntervalInput: $('fastIntervalInput'),
  slowIntervalInput: $('slowIntervalInput'),
  ntfyInput: $('ntfyInput'),
  authUrlInput: $('authUrlInput'),
  saveBtn: $('saveBtn'),
  exchangeCookieBtn: $('exchangeCookieBtn'),
  testConfigBtn: $('testConfigBtn'),
  clearLogsBtn: $('clearLogsBtn'),
  logList: $('logList'),
  successDialog: $('successDialog'),
  successText: $('successText'),
  closeSuccessBtn: $('closeSuccessBtn'),
};

function loadConfig() {
  try {
    const saved = JSON.parse(localStorage.getItem(STORAGE_KEY) || '{}');
    state.config = { ...defaultConfig, ...saved };
  } catch {
    state.config = { ...defaultConfig };
  }
}

function saveConfig() {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(state.config));
}

function fillForm() {
  els.cookieInput.value = state.config.cookie || '';
  els.authorizationInput.value = state.config.authorization || '';
  els.libIdInput.value = state.config.lib_id || '';
  els.openTimeInput.value = state.config.open_time || '07:00:00';
  els.captchaInput.value = state.config.captcha || '';
  els.fastIntervalInput.value = state.config.fast_interval || 0.8;
  els.slowIntervalInput.value = state.config.slow_interval || 3;
  els.ntfyInput.value = state.config.ntfy_topic || '';
}

function collectForm() {
  return {
    cookie: els.cookieInput.value.trim(),
    authorization: els.authorizationInput.value.trim(),
    lib_id: Number(els.libIdInput.value || 0),
    open_time: els.openTimeInput.value || '07:00:00',
    fast_interval: Math.max(0.3, Number(els.fastIntervalInput.value || 0.8)),
    slow_interval: Math.max(1, Number(els.slowIntervalInput.value || 3)),
    ntfy_topic: els.ntfyInput.value.trim(),
    captcha: els.captchaInput.value.trim(),
  };
}

function updateSummary() {
  els.summaryLib.textContent = state.config.lib_id ? String(state.config.lib_id) : '未配置';
  els.summaryCookie.textContent = state.config.cookie ? '已配置' : '未配置';
  els.summaryOpenTime.textContent = state.config.open_time || '07:00:00';
  els.summaryRounds.textContent = String(state.rounds);
}

function log(message, type = 'info') {
  const logs = getLogs();
  logs.unshift({
    message,
    type,
    time: new Date().toLocaleTimeString('zh-CN', { hour12: false }),
  });
  localStorage.setItem(LOG_KEY, JSON.stringify(logs.slice(0, 160)));
  renderLogs();
}

function getLogs() {
  try {
    return JSON.parse(localStorage.getItem(LOG_KEY) || '[]');
  } catch {
    return [];
  }
}

function renderLogs() {
  const logs = getLogs();
  els.logList.innerHTML = logs
    .map(
      (item) => `
        <li class="log-item log-${item.type}">
          <span class="log-time">${escapeHtml(item.time)}</span>
          <span class="log-message">${escapeHtml(item.message)}</span>
        </li>
      `,
    )
    .join('');
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function validateConfig() {
  if (!state.config.cookie) throw new Error('请先填写 Cookie');
  if (!Number(state.config.lib_id)) throw new Error('请先填写阅览室 ID');
}

function getOpenDate() {
  const [hour = '7', minute = '0', second = '0'] = String(state.config.open_time || '07:00:00').split(':');
  const date = new Date();
  date.setHours(Number(hour), Number(minute), Number(second), 0);
  if (date.getTime() < Date.now() - 60 * 1000) date.setDate(date.getDate() + 1);
  return date;
}

function formatDuration(ms) {
  if (ms <= 0) return '00:00:00';
  const total = Math.floor(ms / 1000);
  const hours = String(Math.floor(total / 3600)).padStart(2, '0');
  const minutes = String(Math.floor((total % 3600) / 60)).padStart(2, '0');
  const seconds = String(total % 60).padStart(2, '0');
  return `${hours}:${minutes}:${seconds}`;
}

function startCountdown() {
  clearInterval(state.countdownTimer);
  const tick = () => {
    const openDate = getOpenDate();
    const remaining = openDate.getTime() - Date.now();
    els.countdown.textContent = formatDuration(remaining);

    if (state.mode === 'scheduled' && !state.running && remaining <= EARLY_START_MS) {
      startPolling('scheduled');
    }
  };
  tick();
  state.countdownTimer = setInterval(tick, 250);
}

async function requestWakeLock() {
  try {
    if ('wakeLock' in navigator && !state.wakeLock) {
      state.wakeLock = await navigator.wakeLock.request('screen');
      state.wakeLock.addEventListener('release', () => {
        state.wakeLock = null;
      });
      log('已开启屏幕常亮', 'success');
    }
  } catch (error) {
    log(`屏幕常亮开启失败：${error.message}`, 'warn');
  }
}

async function restoreWakeLock() {
  if (document.visibilityState === 'visible' && state.running) {
    await requestWakeLock();
  }
}

async function releaseWakeLock() {
  if (state.wakeLock) {
    await state.wakeLock.release();
    state.wakeLock = null;
  }
}

function libLayoutPayload() {
  return {
    operationName: 'libLayout',
    query:
      'query libLayout($libId: Int, $libType: Int) {\n userAuth {\n reserve {\n libs(libType: $libType, libId: $libId) {\n lib_id\n lib_name\n lib_floor\n is_open\n lib_layout {\n seats_total\n seats_booking\n seats_used\n seats {\n key\n name\n type\n status\n x\n y\n }\n }\n }\n }\n }\n}',
    variables: { libId: Number(state.config.lib_id) },
  };
}

function reservePayload(seatKey) {
  return {
    operationName: 'reserueSeat',
    query:
      'mutation reserueSeat($libId: Int!, $seatKey: String!, $captchaCode: String, $captcha: String!) {\n userAuth {\n reserve {\n reserueSeat(libId: $libId, seatKey: $seatKey, captchaCode: $captchaCode, captcha: $captcha)\n }\n }\n}',
    variables: {
      seatKey,
      libId: Number(state.config.lib_id),
      captchaCode: state.config.captcha || '',
      captcha: state.config.captcha || '',
    },
  };
}

async function graphql(payload) {
  const response = await fetch('/api/proxy', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Trace-Cookie': state.config.cookie,
      'X-Trace-Authorization': state.config.authorization || '',
    },
    body: JSON.stringify(payload),
  });
  const text = await response.text();
  let data;
  try {
    data = JSON.parse(text);
  } catch {
    throw new Error(`接口返回非 JSON：${text.slice(0, 120)}`);
  }
  if (!response.ok) {
    throw new Error(data.message || data.error || `HTTP ${response.status}`);
  }
  if (data.errors?.length) {
    throw new Error(data.errors.map((item) => item.message).join('；'));
  }
  return data;
}

function getSeats(layoutData) {
  const libs = layoutData?.data?.userAuth?.reserve?.libs || [];
  const lib = libs.find((item) => Number(item.lib_id) === Number(state.config.lib_id)) || libs[0];
  return lib?.lib_layout?.seats || [];
}

function shuffle(items) {
  const result = [...items];
  for (let i = result.length - 1; i > 0; i -= 1) {
    const j = Math.floor(Math.random() * (i + 1));
    [result[i], result[j]] = [result[j], result[i]];
  }
  return result;
}

function isSuccessResult(result) {
  const value = result?.data?.userAuth?.reserve?.reserueSeat;
  if (value === true) return true;
  if (typeof value === 'string') return /成功|预约|ok|true/i.test(value);
  return Boolean(value?.success || value?.status === true);
}

async function runOnce() {
  validateConfig();
  state.rounds += 1;
  updateSummary();

  const layout = await graphql(libLayoutPayload());
  const seats = getSeats(layout);
  const freeSeats = shuffle(seats.filter((seat) => Number(seat.type) === 1 && seat.status === false));

  if (!freeSeats.length) {
    log(`第 ${state.rounds} 轮：没有空位`, 'info');
    return false;
  }

  log(`第 ${state.rounds} 轮：发现 ${freeSeats.length} 个空位，开始尝试`, 'success');
  for (const seat of freeSeats) {
    try {
      const result = await graphql(reservePayload(seat.key));
      if (isSuccessResult(result)) {
        await handleSuccess(seat);
        return true;
      }
      log(`座位 ${seat.name || seat.key} 未成功，继续尝试`, 'warn');
    } catch (error) {
      log(`座位 ${seat.name || seat.key} 失败：${error.message}`, 'error');
    }
  }

  return false;
}

async function handleSuccess(seat) {
  stopPolling(false);
  const seatName = seat.name || seat.key;
  document.title = '[已抢到] 抢座助手';
  els.stateText.textContent = `已抢到：${seatName}`;
  els.modeText.textContent = '抢座成功';
  els.successText.textContent = `座位：${seatName}`;
  log(`抢座成功：${seatName}`, 'success');
  playBeep();
  await sendNtfy(`抢座成功：${seatName}`);
  if (typeof els.successDialog.showModal === 'function') els.successDialog.showModal();
}

function playBeep() {
  try {
    const audioContext = new (window.AudioContext || window.webkitAudioContext)();
    const oscillator = audioContext.createOscillator();
    const gain = audioContext.createGain();
    oscillator.type = 'sine';
    oscillator.frequency.value = 880;
    oscillator.connect(gain);
    gain.connect(audioContext.destination);
    gain.gain.setValueAtTime(0.001, audioContext.currentTime);
    gain.gain.exponentialRampToValueAtTime(0.3, audioContext.currentTime + 0.02);
    gain.gain.exponentialRampToValueAtTime(0.001, audioContext.currentTime + 1.2);
    oscillator.start();
    oscillator.stop(audioContext.currentTime + 1.25);
  } catch {
    // 声音失败不影响抢座结果。
  }
}

async function sendNtfy(message) {
  if (!state.config.ntfy_topic) return;
  try {
    await fetch(`https://ntfy.sh/${encodeURIComponent(state.config.ntfy_topic)}`, {
      method: 'POST',
      body: message,
    });
  } catch (error) {
    log(`ntfy 推送失败：${error.message}`, 'warn');
  }
}

function nextDelay(mode) {
  const base = (mode === 'leak' ? state.config.slow_interval : state.config.fast_interval) * 1000;
  const jitter = Math.floor(Math.random() * Math.min(600, base * 0.45));
  return Math.max(300, base + jitter + state.backoffMs);
}

function queueNext(mode) {
  clearTimeout(state.timer);
  if (!state.running) return;
  state.timer = setTimeout(async () => {
    try {
      const success = await runOnce();
      state.backoffMs = success ? 0 : Math.max(0, state.backoffMs - 250);
    } catch (error) {
      state.backoffMs = Math.min(8000, state.backoffMs ? state.backoffMs * 1.7 : 1000);
      log(`轮询失败：${error.message}，退避 ${Math.round(state.backoffMs / 1000)} 秒`, 'error');
    } finally {
      queueNext(mode);
    }
  }, nextDelay(mode));
}

async function startPolling(mode) {
  try {
    validateConfig();
    state.running = true;
    state.mode = mode;
    state.backoffMs = 0;
    document.title = mode === 'leak' ? '[捡漏中] 抢座助手' : '[轮询中] 抢座助手';
    els.modeText.textContent = mode === 'leak' ? '捡漏监控' : '定时抢座';
    els.stateText.textContent = '轮询运行中，请保持页面前台打开';
    await requestWakeLock();
    log(mode === 'leak' ? '开始捡漏监控' : '开始定时轮询', 'success');
    queueNext(mode);
  } catch (error) {
    log(error.message, 'error');
    switchTab('config');
  }
}

function stopPolling(writeLog = true) {
  clearTimeout(state.timer);
  state.running = false;
  state.mode = 'idle';
  state.backoffMs = 0;
  document.title = '抢座助手';
  els.modeText.textContent = '已停止';
  els.stateText.textContent = '轮询未运行';
  releaseWakeLock();
  if (writeLog) log('已停止轮询', 'warn');
}

async function testHealth() {
  try {
    const response = await fetch('/api/proxy?type=health');
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    els.healthStatus.textContent = '代理正常';
    els.healthStatus.className = 'status-pill ok';
    log('代理健康检查通过', 'success');
  } catch (error) {
    els.healthStatus.textContent = '代理异常';
    els.healthStatus.className = 'status-pill bad';
    log(`代理健康检查失败：${error.message}`, 'error');
  }
}

async function exchangeCookie() {
  const url = els.authUrlInput.value.trim();
  if (!url) {
    log('请先粘贴授权链接', 'warn');
    return;
  }

  els.exchangeCookieBtn.disabled = true;
  els.exchangeCookieBtn.textContent = '换取中';
  try {
    const response = await fetch('/api/session', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ url }),
    });
    const data = await response.json();
    if (!response.ok) throw new Error(data.message || data.error || `HTTP ${response.status}`);
    els.cookieInput.value = data.cookie;
    state.config = { ...state.config, ...collectForm(), cookie: data.cookie };
    saveConfig();
    updateSummary();
    log('已通过授权链接换取 Cookie 并保存', 'success');
  } catch (error) {
    log(`换取 Cookie 失败：${error.message}`, 'error');
  } finally {
    els.exchangeCookieBtn.disabled = false;
    els.exchangeCookieBtn.textContent = '链接换 Cookie';
  }
}

function switchTab(name) {
  document.querySelectorAll('.view').forEach((view) => view.classList.remove('view-active'));
  document.querySelector(`#view-${name}`).classList.add('view-active');
  document.querySelectorAll('.tabbar button').forEach((button) => {
    button.classList.toggle('tab-active', button.dataset.tab === name);
  });
}

function bindEvents() {
  document.querySelectorAll('.tabbar button').forEach((button) => {
    button.addEventListener('click', () => switchTab(button.dataset.tab));
  });

  els.configForm.addEventListener('submit', (event) => {
    event.preventDefault();
    state.config = collectForm();
    saveConfig();
    updateSummary();
    log('配置已保存', 'success');
    switchTab('home');
  });

  els.scheduleBtn.addEventListener('click', () => {
    try {
      validateConfig();
      state.mode = 'scheduled';
      els.modeText.textContent = '定时抢座';
      els.stateText.textContent = `等待 ${state.config.open_time}，提前 5 秒启动`;
      log('已进入定时抢座模式', 'success');
      startCountdown();
    } catch (error) {
      log(error.message, 'error');
      switchTab('config');
    }
  });

  els.leakBtn.addEventListener('click', () => startPolling('leak'));
  els.onceBtn.addEventListener('click', async () => {
    try {
      log('开始手动抢一次', 'info');
      await runOnce();
    } catch (error) {
      log(`手动抢座失败：${error.message}`, 'error');
    }
  });
  els.stopBtn.addEventListener('click', () => stopPolling());
  els.clearLogsBtn.addEventListener('click', () => {
    localStorage.removeItem(LOG_KEY);
    renderLogs();
  });
  els.testConfigBtn.addEventListener('click', testHealth);
  els.exchangeCookieBtn.addEventListener('click', exchangeCookie);
  els.closeSuccessBtn.addEventListener('click', () => els.successDialog.close());
  document.addEventListener('visibilitychange', restoreWakeLock);
}

function init() {
  loadConfig();
  fillForm();
  updateSummary();
  renderLogs();
  bindEvents();
  startCountdown();
  testHealth();
}

init();

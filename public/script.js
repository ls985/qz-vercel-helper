const STORAGE_KEY = 'qz-helper-config-v2';
const LOG_KEY = 'qz-helper-logs-v2';
const EARLY_START_MS = 5000;
const OFFICIAL_WX_APP_ID = 'wx2996d437cd442527';
const OFFICIAL_GRAPHQL_URL = 'https://wechat.v2.traceint.com/index.php/graphql/';

const defaultConfig = {
  cookie: '',
  authorization: '',
  lib_id: '',
  open_time: '07:00:00',
  fast_interval: 0.45,
  slow_interval: 3,
  burst_interval: 0.25,
  concurrency: 2,
  candidate_limit: 6,
  preferred_seats: '',
  ntfy_topic: '',
  captcha: '',
  rooms: [],
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
  seatCooldown: {},
  success: false,
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
  roomSelect: $('roomSelect'),
  roomHint: $('roomHint'),
  libIdInput: $('libIdInput'),
  openTimeInput: $('openTimeInput'),
  captchaInput: $('captchaInput'),
  fastIntervalInput: $('fastIntervalInput'),
  slowIntervalInput: $('slowIntervalInput'),
  burstIntervalInput: $('burstIntervalInput'),
  concurrencyInput: $('concurrencyInput'),
  candidateLimitInput: $('candidateLimitInput'),
  preferredSeatsInput: $('preferredSeatsInput'),
  ntfyInput: $('ntfyInput'),
  authUrlInput: $('authUrlInput'),
  openWechatLoginBtn: $('openWechatLoginBtn'),
  copyLoginLinkBtn: $('copyLoginLinkBtn'),
  refreshRoomsBtn: $('refreshRoomsBtn'),
  clearCookieBtn: $('clearCookieBtn'),
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
  els.fastIntervalInput.value = state.config.fast_interval || 0.45;
  els.slowIntervalInput.value = state.config.slow_interval || 3;
  els.burstIntervalInput.value = state.config.burst_interval || 0.25;
  els.concurrencyInput.value = state.config.concurrency || 2;
  els.candidateLimitInput.value = state.config.candidate_limit || 6;
  els.preferredSeatsInput.value = state.config.preferred_seats || '';
  els.ntfyInput.value = state.config.ntfy_topic || '';
  renderRooms();
}

function collectForm() {
  return {
    cookie: els.cookieInput.value.trim(),
    authorization: els.authorizationInput.value.trim(),
    lib_id: Number(els.libIdInput.value || 0),
    open_time: els.openTimeInput.value || '07:00:00',
    fast_interval: Math.max(0.15, Number(els.fastIntervalInput.value || 0.45)),
    slow_interval: Math.max(1, Number(els.slowIntervalInput.value || 3)),
    burst_interval: Math.max(0.1, Number(els.burstIntervalInput.value || 0.25)),
    concurrency: clamp(Number(els.concurrencyInput.value || 2), 1, 4),
    candidate_limit: clamp(Number(els.candidateLimitInput.value || 6), 1, 20),
    preferred_seats: els.preferredSeatsInput.value.trim(),
    ntfy_topic: els.ntfyInput.value.trim(),
    captcha: els.captchaInput.value.trim(),
    rooms: state.config.rooms || [],
  };
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

function updateSummary() {
  const room = getSelectedRoom();
  els.summaryLib.textContent = room ? room.name : state.config.lib_id ? String(state.config.lib_id) : '未配置';
  els.summaryCookie.textContent = state.config.cookie ? '已配置' : '未配置';
  els.summaryOpenTime.textContent = state.config.open_time || '07:00:00';
  els.summaryRounds.textContent = String(state.rounds);
}

function getSelectedRoom() {
  return (state.config.rooms || []).find((room) => Number(room.id) === Number(state.config.lib_id));
}

function renderRooms() {
  const rooms = state.config.rooms || [];
  if (!rooms.length) {
    els.roomSelect.innerHTML = '<option value="">请先登录并获取阅览室</option>';
    els.roomHint.textContent = state.config.cookie ? '未读取到阅览室，可点刷新或手动填写 ID。' : '登录后会自动读取当前账号可用阅览室。';
    els.roomSelect.value = '';
    return;
  }

  const sorted = [...rooms].sort((a, b) => String(a.name).localeCompare(String(b.name), 'zh-CN', { numeric: true }));
  els.roomSelect.innerHTML = sorted
    .map((room) => {
      const count = Number.isFinite(Number(room.available)) ? `，${room.available} 座可用` : '';
      return `<option value="${escapeHtml(room.id)}">${escapeHtml(room.name)}${count}</option>`;
    })
    .join('');
  els.roomSelect.value = String(state.config.lib_id || sorted[0].id);
  els.roomHint.textContent = `已读取 ${rooms.length} 个阅览室。`;
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
      'query libLayout($libId: Int, $libType: Int) {\n userAuth {\n reserve {\n libs(libType: $libType, libId: $libId) {\n lib_id\n lib_name\n lib_floor\n is_open\n lib_layout {\n seats_total\n seats_booking\n seats_used\n seats {\n key\n name\n type\n status\n seat_status\n x\n y\n }\n }\n }\n }\n }\n}',
    variables: { libId: Number(state.config.lib_id), libType: -1 },
  };
}

function reservePayload(seatKey, variant = 'reserveSeat') {
  const fieldName = variant === 'reserueSeat' ? 'reserueSeat' : 'reserveSeat';
  return {
    operationName: fieldName,
    query: `mutation ${fieldName}($libId: Int!, $seatKey: String!, $captchaCode: String, $captcha: String!) {\n userAuth {\n reserve {\n ${fieldName}(libId: $libId, seatKey: $seatKey, captchaCode: $captchaCode, captcha: $captcha)\n }\n }\n}`,
    variables: {
      seatKey,
      libId: Number(state.config.lib_id),
      captchaCode: state.config.captcha || '',
      captcha: state.config.captcha || '',
    },
  };
}

function reserveVerifyPayload() {
  return {
    operationName: 'reserve',
    query: 'query reserve {\n userAuth {\n reserve {\n reserve {\n status\n seat_name\n lib_name\n }\n }\n }\n}',
    variables: {},
  };
}

function roomListPayload() {
  return {
    operationName: 'list',
    query:
      'query list {\n userAuth {\n reserve {\n libs(libType: -1) {\n lib_id\n lib_name\n is_open\n lib_rt {\n seats_has\n }\n }\n }\n }\n}',
    variables: {},
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

function getReserveValue(result) {
  const value = result?.data?.userAuth?.reserve?.reserveSeat ?? result?.data?.userAuth?.reserve?.reserueSeat;
  return value;
}

function isSuccessResult(result) {
  const value = getReserveValue(result);
  if (value === true) return true;
  if (typeof value === 'string') return /成功|预约|ok|true/i.test(value);
  return Boolean(value?.success || value?.status === true);
}

function getReserveMessage(result) {
  const value = getReserveValue(result);
  if (typeof value === 'string') return value;
  if (value && typeof value === 'object') return value.message || value.msg || JSON.stringify(value);
  return value === undefined ? '无返回字段' : String(value);
}

async function refreshRooms() {
  if (!state.config.cookie) {
    log('请先登录获取 Cookie', 'warn');
    return;
  }

  els.refreshRoomsBtn.disabled = true;
  els.refreshRoomsBtn.textContent = '刷新中';
  try {
    const data = await graphql(roomListPayload());
    const libs = data?.data?.userAuth?.reserve?.libs || [];
    const rooms = libs.map((lib) => ({
      id: Number(lib.lib_id),
      name: lib.lib_name || `阅览室 ${lib.lib_id}`,
      available: Number(lib.lib_rt?.seats_has ?? 0),
      is_open: Boolean(lib.is_open),
    }));

    if (!rooms.length) throw new Error('当前账号没有返回阅览室列表');
    const exists = rooms.some((room) => Number(room.id) === Number(state.config.lib_id));
    state.config.rooms = rooms;
    if (!exists) state.config.lib_id = rooms[0].id;
    saveConfig();
    fillForm();
    updateSummary();
    log(`已自动读取 ${rooms.length} 个阅览室`, 'success');
  } catch (error) {
    log(`读取阅览室失败：${error.message}`, 'error');
  } finally {
    els.refreshRoomsBtn.disabled = false;
    els.refreshRoomsBtn.textContent = '刷新阅览室';
  }
}

function buildWechatLoginUrl() {
  const apiUrl = new URL(OFFICIAL_GRAPHQL_URL);
  const cleanPath = apiUrl.pathname.replace(/\/$/, '');
  const redirectUri = encodeURIComponent(`${apiUrl.protocol}//${apiUrl.host}${cleanPath}`);
  return `https://open.weixin.qq.com/connect/oauth2/authorize?appid=${OFFICIAL_WX_APP_ID}&redirect_uri=${redirectUri}&response_type=code&scope=snsapi_userinfo&state=1#wechat_redirect`;
}

async function copyText(text) {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(text);
    return;
  }
  const input = document.createElement('textarea');
  input.value = text;
  document.body.appendChild(input);
  input.select();
  document.execCommand('copy');
  input.remove();
}

async function runOnce() {
  validateConfig();
  if (state.success) return true;
  state.rounds += 1;
  updateSummary();

  const layout = await graphql(libLayoutPayload());
  const seats = getSeats(layout);
  const freeSeats = pickCandidates(seats.filter(isFreeSeat));

  if (!freeSeats.length) {
    log(`第 ${state.rounds} 轮：没有空位`, 'info');
    return false;
  }

  log(`第 ${state.rounds} 轮：尝试 ${freeSeats.length} 个候选空位`, 'success');
  const batches = chunk(freeSeats, state.config.concurrency || 2);
  for (const batch of batches) {
    const result = await raceReserveBatch(batch);
    if (result) return true;
  }

  return false;
}

function pickCandidates(seats) {
  const now = Date.now();
  const preferred = parsePreferredSeats();
  const scored = seats
    .filter((seat) => !state.seatCooldown[seat.key] || state.seatCooldown[seat.key] <= now)
    .map((seat) => ({
      seat,
      score: scoreSeat(seat, preferred),
    }))
    .sort((a, b) => b.score - a.score || String(a.seat.name || '').localeCompare(String(b.seat.name || ''), 'zh-CN', { numeric: true }));

  const limit = state.config.candidate_limit || 6;
  return scored.slice(0, limit).map((item) => item.seat);
}

function parsePreferredSeats() {
  return String(state.config.preferred_seats || '')
    .split(/[,\s，、]+/)
    .map((item) => item.trim())
    .filter(Boolean);
}

function scoreSeat(seat, preferred) {
  const name = String(seat.name || '');
  const preferredIndex = preferred.findIndex((item) => item === name || item === String(seat.key));
  if (preferredIndex >= 0) return 10000 - preferredIndex;

  // 没有偏好时，把座位号靠前的排前面，同时保留少量随机性，避免每轮死磕同一个失败位。
  const number = Number(name.match(/\d+/)?.[0] || 9999);
  return 5000 - number + Math.random() * 12;
}

function chunk(items, size) {
  const result = [];
  for (let i = 0; i < items.length; i += size) result.push(items.slice(i, i + size));
  return result;
}

async function raceReserveBatch(seats) {
  let success = false;
  const attempts = seats.map(async (seat) => {
    if (success) return false;
    const reserved = await tryReserveSeat(seat);
    if (reserved) success = true;
    return reserved;
  });
  const results = await Promise.allSettled(attempts);
  return results.some((item) => item.status === 'fulfilled' && item.value === true);
}

async function tryReserveSeat(seat) {
  if (state.success) return true;
  const seatName = seat.name || seat.key;
  const variants = ['reserveSeat', 'reserueSeat'];

  for (const variant of variants) {
    try {
      const result = await graphql(reservePayload(seat.key, variant));
      if (state.success) return true;
      if (isSuccessResult(result)) {
        await handleSuccess(seat);
        return true;
      }

      const verified = await verifyReservation(seat);
      if (verified) {
        await handleSuccess(seat);
        return true;
      }

      log(`座位 ${seatName} ${variant} 未确认成功：${getReserveMessage(result)}`, 'warn');
    } catch (error) {
      log(`座位 ${seatName} ${variant} 失败：${error.message}`, 'error');
    }
  }

  state.seatCooldown[seat.key] = Date.now() + 1500;
  return false;
}

async function verifyReservation(seat) {
  try {
    const data = await graphql(reserveVerifyPayload());
    const reserve = data?.data?.userAuth?.reserve?.reserve;
    const seatName = seat.name || seat.key;
    if (!reserve) return false;
    if (reserve.status && (!reserve.seat_name || String(reserve.seat_name) === String(seatName))) return true;
    return String(reserve.seat_name || '') === String(seatName);
  } catch (error) {
    log(`预约结果验证失败：${error.message}`, 'warn');
    return false;
  }
}

function isFreeSeat(seat) {
  if (Number(seat.type) !== 1) return false;
  if (seat.seat_status !== undefined && seat.seat_status !== null) {
    return Number(seat.seat_status) === 1;
  }
  return seat.status === false || seat.status === 0 || seat.status === 'false';
}

async function handleSuccess(seat) {
  if (state.success) return;
  state.success = true;
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
  const interval = getActiveInterval(mode);
  const base = interval * 1000;
  const jitter = Math.floor(Math.random() * Math.min(180, base * 0.25));
  return Math.max(300, base + jitter + state.backoffMs);
}

function getActiveInterval(mode) {
  if (mode === 'leak') return state.config.slow_interval;
  const openDate = getOpenDate();
  const delta = Date.now() - openDate.getTime();
  if (delta >= -EARLY_START_MS && delta <= 20 * 1000) {
    return state.config.burst_interval || state.config.fast_interval;
  }
  return state.config.fast_interval;
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
    state.success = false;
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
    log('已通过微信回调链接换取 Cookie', 'success');
    await refreshRooms();
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
    renderRooms();
    updateSummary();
    log('配置已保存', 'success');
    switchTab('home');
  });

  els.roomSelect.addEventListener('change', () => {
    els.libIdInput.value = els.roomSelect.value;
    state.config = { ...state.config, ...collectForm(), lib_id: Number(els.roomSelect.value || 0) };
    saveConfig();
    updateSummary();
  });

  els.libIdInput.addEventListener('change', () => {
    state.config = { ...state.config, ...collectForm() };
    renderRooms();
    updateSummary();
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
  els.refreshRoomsBtn.addEventListener('click', () => {
    state.config = { ...state.config, ...collectForm() };
    saveConfig();
    refreshRooms();
  });
  els.openWechatLoginBtn.addEventListener('click', () => {
    const loginUrl = buildWechatLoginUrl();
    window.open(loginUrl, '_blank', 'noopener,noreferrer');
    log('已打开微信登录链接；授权后复制回调链接粘贴回来', 'info');
  });
  els.copyLoginLinkBtn.addEventListener('click', async () => {
    try {
      await copyText(buildWechatLoginUrl());
      log('微信登录链接已复制', 'success');
    } catch (error) {
      log(`复制失败：${error.message}`, 'error');
    }
  });
  els.clearCookieBtn.addEventListener('click', () => {
    stopPolling(false);
    state.success = false;
    state.config.cookie = '';
    state.config.authorization = '';
    state.config.lib_id = '';
    state.config.rooms = [];
    saveConfig();
    fillForm();
    updateSummary();
    log('已清除登录信息', 'warn');
  });
  els.closeSuccessBtn.addEventListener('click', () => els.successDialog.close());
  document.addEventListener('visibilitychange', restoreWakeLock);
}

function init() {
  loadConfig();
  fillForm();
  renderRooms();
  updateSummary();
  renderLogs();
  bindEvents();
  startCountdown();
  testHealth();
}

init();

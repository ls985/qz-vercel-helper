const STORAGE_KEY = 'qz-helper-config-v2';
const LOG_KEY = 'qz-helper-logs-v2';
const OFFICIAL_WX_APP_ID = 'wx2996d437cd442527';
const OFFICIAL_GRAPHQL_URL = 'https://wechat.v2.traceint.com/index.php/graphql/';
const OFFICIAL_WEB_URL = 'https://web.traceint.com/';
const CHECKIN_INITIAL_QUERY_TIMEOUT_MS = 6000;
const CHECKIN_MUTATION_WAIT_MS = 6500;
const NTFY_TIMEOUT_MS = 5000;

const defaultConfig = {
  cookie: '',
  authorization: '',
  lib_id: '',
  slow_interval: 1.5,
  tomorrow_interval: 8,
  concurrency: 1,
  candidate_limit: 1,
  cooldown: 8,
  preferred_seats: '',
  tomorrow_time: '20:00:00',
  ntfy_topic: '',
  captcha: '',
  rooms: [],
};

const state = {
  config: { ...defaultConfig },
  timer: null,
  worker: null,
  running: false,
  mode: 'idle',
  rounds: 0,
  wakeLock: null,
  backoffMs: 0,
  seatCooldown: {},
  success: false,
  lastNoSeatLogAt: 0,
  reserveFieldName: '',
  guardStopped: false,
  currentUser: null,
  tomorrowSeats: [],
  tomorrowRunAt: 0,
  abortController: null,
  tomorrowDetailedLayoutSupported: null,
  tomorrowNoSeatLogAt: 0,
  checkinSummary: '未检测',
  checkinAttempt: null,
  checkinBusy: false,
};

const $ = (id) => document.getElementById(id);

const els = {
  healthStatus: $('healthStatus'),
  userStatus: $('userStatus'),
  userAvatar: $('userAvatar'),
  adminLink: $('adminLink'),
  logoutBtn: $('logoutBtn'),
  hairBalance: $('hairBalance'),
  checkinState: $('checkinState'),
  checkinBtn: $('checkinBtn'),
  monitorPanel: $('monitorPanel'),
  noticePanel: $('noticePanel'),
  noticeList: $('noticeList'),
  countdown: $('countdown'),
  modeText: $('modeText'),
  stateText: $('stateText'),
  summaryLib: $('summaryLib'),
  summaryCookie: $('summaryCookie'),
  summaryTomorrow: $('summaryTomorrow'),
  summaryCheckin: $('summaryCheckin'),
  summaryOpenTime: $('summaryOpenTime'),
  summaryRounds: $('summaryRounds'),
  leakBtn: $('leakBtn'),
  tomorrowBtn: $('tomorrowBtn'),
  remoteCheckinBtn: $('remoteCheckinBtn'),
  inspectCheckinBtn: $('inspectCheckinBtn'),
  stopBtn: $('stopBtn'),
  configForm: $('configForm'),
  cookieInput: $('cookieInput'),
  authorizationInput: $('authorizationInput'),
  roomSelect: $('roomSelect'),
  roomHint: $('roomHint'),
  libIdInput: $('libIdInput'),
  captchaInput: $('captchaInput'),
  slowIntervalInput: $('slowIntervalInput'),
  concurrencyInput: $('concurrencyInput'),
  candidateLimitInput: $('candidateLimitInput'),
  cooldownInput: $('cooldownInput'),
  preferredSeatsInput: $('preferredSeatsInput'),
  tomorrowRoomText: $('tomorrowRoomText'),
  tomorrowTimeInput: $('tomorrowTimeInput'),
  arrivalCodeInput: $('arrivalCodeInput'),
  submitArrivalCodeBtn: $('submitArrivalCodeBtn'),
  checkinActionLinks: $('checkinActionLinks'),
  resetCheckinAttemptBtn: $('resetCheckinAttemptBtn'),
  ntfyInput: $('ntfyInput'),
  authUrlInput: $('authUrlInput'),
  copyLoginLinkBtn: $('copyLoginLinkBtn'),
  refreshRoomsBtn: $('refreshRoomsBtn'),
  clearCookieBtn: $('clearCookieBtn'),
  saveBtn: $('saveBtn'),
  exchangeCookieBtn: $('exchangeCookieBtn'),
  testConfigBtn: $('testConfigBtn'),
  clearLogsBtn: $('clearLogsBtn'),
  logList: $('logList'),
  successDialog: $('successDialog'),
  successMark: $('successMark'),
  successTitle: $('successTitle'),
  successText: $('successText'),
  closeSuccessBtn: $('closeSuccessBtn'),
};

async function loadCurrentUser() {
  try {
    const response = await fetch('/api/auth/me');
    const data = await response.json();
    if (!data.user) {
      window.location.href = '/login.html';
      return;
    }
    state.currentUser = data.user;
    els.userStatus.textContent = data.user.username;
    els.userAvatar.textContent = data.user.username.slice(0, 1);
    updateAdminVisibility();
    updateUserPanel();
  } catch {
    window.location.href = '/login.html';
  }
}

function updateAdminVisibility() {
  const isAdmin = state.currentUser?.role === 'admin';
  document.querySelectorAll('.admin-only').forEach((element) => {
    element.hidden = !isAdmin;
  });
}

function updateUserPanel() {
  els.hairBalance.textContent = formatHair(state.currentUser?.hair || 0);
  els.hairBalance.classList.remove('value-pop');
  requestAnimationFrame(() => els.hairBalance.classList.add('value-pop'));
  const checkedIn = state.currentUser?.lastCheckinDate === todayKey();
  els.checkinState.textContent = checkedIn ? '今日奖励已领' : '今日奖励可领';
  els.checkinState.classList.toggle('done', checkedIn);
  els.checkinBtn.textContent = checkedIn ? '今日已签到' : '签到领头发';
  els.checkinBtn.disabled = checkedIn;
}

function todayKey() {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Shanghai',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(new Date());
}

function formatHair(value) {
  return Number(value || 0).toFixed(2).replace(/\.?0+$/, '');
}

async function loadAnnouncements() {
  try {
    const response = await fetch('/api/announcements');
    const data = await response.json();
    const announcements = data.announcements || [];
    els.noticePanel.hidden = !announcements.length;
    els.noticeList.innerHTML = announcements
      .map(
        (item) => {
          const copyValue = [item.title, item.content].filter(Boolean).join('\n');
          return `
          <li class="notice-item">
            <div class="notice-item-head">
              <strong>${escapeHtml(item.title)}</strong>
              <button class="notice-copy-button" type="button" data-copy="${escapeHtml(copyValue)}">复制</button>
            </div>
            <span class="notice-content">${escapeHtml(item.content)}</span>
          </li>
        `;
        },
      )
      .join('');
  } catch {
    els.noticePanel.hidden = true;
  }
}

async function checkin() {
  els.checkinBtn.disabled = true;
  try {
    const response = await fetch('/api/auth/checkin', { method: 'POST' });
    const data = await response.json();
    if (!response.ok) throw new Error(data.message || data.error || `HTTP ${response.status}`);
    state.currentUser = data.user;
    updateUserPanel();
    els.checkinBtn.classList.remove('rewarded');
    requestAnimationFrame(() => els.checkinBtn.classList.add('rewarded'));
    log(`签到成功，获得 ${formatHair(data.amount)} 根头发`, 'success');
  } catch (error) {
    log(error.message || '签到失败', 'warn');
  } finally {
    els.checkinBtn.disabled = state.currentUser?.lastCheckinDate === todayKey();
  }
}

async function consumeHairForSuccess() {
  const response = await fetch('/api/auth/consume', { method: 'POST' });
  const data = await response.json();
  if (!response.ok) throw new Error(data.message || data.error || `HTTP ${response.status}`);
  state.currentUser = data.user;
  updateUserPanel();
  log('抢座成功，已消耗 1 根头发', 'success');
}

function loadConfig() {
  try {
    const saved = JSON.parse(localStorage.getItem(STORAGE_KEY) || '{}');
    state.config = normalizeConfig({ ...defaultConfig, ...saved });
  } catch {
    state.config = { ...defaultConfig };
  }
}

function saveConfig() {
  state.config = normalizeConfig(state.config);
  localStorage.setItem(STORAGE_KEY, JSON.stringify(state.config));
}

function normalizeConfig(config) {
  const tomorrowTime = /^([01]\d|2[0-3]):[0-5]\d(?::[0-5]\d)?$/.test(String(config.tomorrow_time || ''))
    ? String(config.tomorrow_time).padEnd(8, ':00')
    : defaultConfig.tomorrow_time;
  return {
    ...config,
    slow_interval: Math.max(1, Number(config.slow_interval || defaultConfig.slow_interval)),
    tomorrow_interval: clamp(Number(config.tomorrow_interval || defaultConfig.tomorrow_interval), 6, 30),
    concurrency: 1,
    candidate_limit: clamp(Number(config.candidate_limit || defaultConfig.candidate_limit), 1, 3),
    cooldown: clamp(Number(config.cooldown || defaultConfig.cooldown), 3, 30),
    tomorrow_time: tomorrowTime,
  };
}

function fillForm() {
  els.cookieInput.value = state.config.cookie || '';
  els.authorizationInput.value = state.config.authorization || '';
  els.libIdInput.value = state.config.lib_id || '';
  els.captchaInput.value = state.config.captcha || '';
  els.slowIntervalInput.value = state.config.slow_interval || defaultConfig.slow_interval;
  els.concurrencyInput.value = state.config.concurrency || 1;
  els.candidateLimitInput.value = state.config.candidate_limit || 1;
  els.cooldownInput.value = state.config.cooldown || 8;
  els.preferredSeatsInput.value = state.config.preferred_seats || '';
  els.tomorrowTimeInput.value = state.config.tomorrow_time || defaultConfig.tomorrow_time;
  els.ntfyInput.value = state.config.ntfy_topic || '';
  renderRooms();
}

function collectForm() {
  return {
    cookie: els.cookieInput.value.trim(),
    authorization: els.authorizationInput.value.trim(),
    lib_id: Number(els.libIdInput.value || 0),
    slow_interval: Math.max(1, Number(els.slowIntervalInput.value || defaultConfig.slow_interval)),
    concurrency: 1,
    candidate_limit: clamp(Number(els.candidateLimitInput.value || 1), 1, 3),
    cooldown: clamp(Number(els.cooldownInput.value || 8), 3, 30),
    preferred_seats: els.preferredSeatsInput.value.trim(),
    tomorrow_time: els.tomorrowTimeInput.value || defaultConfig.tomorrow_time,
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
  els.summaryTomorrow.textContent = room
    ? `${room.name} · 空位即抢 · ${state.config.tomorrow_time || defaultConfig.tomorrow_time}`
    : '未配置';
  els.summaryCheckin.textContent = state.checkinSummary;
  els.tomorrowRoomText.textContent = room ? room.name : '请先在上方选择阅览室';
  els.summaryOpenTime.textContent = `${state.config.slow_interval || defaultConfig.slow_interval} 秒`;
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
  if (Number(state.currentUser?.hair || 0) < 1) throw new Error('头发不足，成功抢座需要 1 根头发');
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

function reservePayload(seatKey, fieldName = 'reserveSeat') {
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

function roomListPayload() {
  return {
    operationName: 'list',
    query:
      'query list {\n userAuth {\n reserve {\n libs(libType: -1) {\n lib_id\n lib_name\n is_open\n lib_rt {\n seats_has\n }\n }\n }\n }\n}',
    variables: {},
  };
}

function tomorrowLayoutPayload(includeSeats = false) {
  const seatFields = includeSeats
    ? '\n seats {\n key\n name\n type\n status\n seat_status\n x\n y\n }'
    : '';
  return {
    operationName: 'libLayout',
    query: `query libLayout($libId: Int!) {\n userAuth {\n prereserve {\n libLayout(libId: $libId) {\n seats_booking\n seats_total\n seats_used${seatFields}\n }\n }\n }\n}`,
    variables: { libId: Number(state.config.lib_id) },
  };
}

function tomorrowSavePayload(seatKey) {
  const key = String(seatKey).endsWith('.') ? String(seatKey) : `${seatKey}.`;
  return {
    operationName: 'save',
    query:
      'mutation save($key: String!, $libid: Int!, $captchaCode: String, $captcha: String) {\n userAuth {\n prereserve {\n save(key: $key, libId: $libid, captcha: $captcha, captchaCode: $captchaCode)\n }\n }\n}',
    variables: {
      key,
      libid: Number(state.config.lib_id),
      captchaCode: state.config.captcha || '',
      captcha: state.config.captcha || '',
    },
  };
}

function tomorrowInfoPayload() {
  return {
    operationName: 'prereserve',
    query:
      'query prereserve {\n userAuth {\n prereserve {\n prereserve {\n day\n lib_id\n seat_key\n seat_name\n is_used\n }\n }\n }\n}',
    variables: {},
  };
}

function checkinStatusPayload() {
  return {
    operationName: 'checkinStatus',
    query:
      'query checkinStatus {\n userAuth {\n reserve {\n reserve {\n token\n status\n sch_id\n sch_name\n lib_id\n lib_name\n lib_floor\n seat_key\n seat_name\n date\n exp_date\n exp_date_str\n validate_date\n hold_date\n }\n qrUrl\n weixiao {\n isOpen\n url\n pic\n }\n }\n config: user {\n notSign: getSchConfig(fields: "reserve.notSign")\n blueSignOpen: getSchConfig(fields: "adm.blueSignOpen")\n doorSignOpen: getSchConfig(fields: "adm.doorSignOpen")\n doorSignURL: getSchConfig(fields: "adm.doorSignURL")\n forbidQrValid: getSchConfig(fields: "forbidQrValid", extra: true)\n }\n }\n}',
    variables: {},
  };
}

function checkinReservationPayload() {
  return {
    operationName: 'checkinReservation',
    query:
      'query checkinReservation {\n userAuth {\n reserve {\n reserve {\n token\n status\n sch_name\n lib_id\n lib_name\n lib_floor\n seat_key\n seat_name\n date\n exp_date\n exp_date_str\n validate_date\n hold_date\n }\n }\n }\n}',
    variables: {},
  };
}

function officialCheckinIndexPayload() {
  return {
    operationName: 'index',
    query:
      'query index($url: String!, $pos: String!, $param: [hash]) {\n userAuth {\n reserve {\n reserve {\n token\n status\n user_id\n user_nick\n sch_id\n sch_name\n lib_id\n lib_name\n lib_floor\n seat_name\n }\n qrUrl\n weixiao {\n isOpen\n url\n pic\n }\n }\n webSocket {\n url\n qrType\n protocol\n }\n config: user {\n notSign: getSchConfig(fields: "reserve.notSign")\n blueSignOpen: getSchConfig(fields: "adm.blueSignOpen")\n doorSignOpen: getSchConfig(fields: "adm.doorSignOpen")\n doorSignURL: getSchConfig(fields: "adm.doorSignURL")\n forbidQrValid: getSchConfig(fields: "forbidQrValid", extra: true)\n }\n }\n wechatJSSDK(url: $url) {\n appId\n timestamp\n nonceStr\n signature\n }\n ad(pos: $pos, param: $param) {\n name\n pic\n url\n }\n}',
    variables: {
      url: 'https://web.traceint.com/web/',
      pos: '新版-签到页面-中间',
    },
  };
}

function singleCheckinConfigPayload(operationName, fieldName) {
  return {
    operationName,
    query: `query ${operationName} {\n userAuth {\n config: user {\n value: getSchConfig(fields: "${fieldName}")\n }\n }\n}`,
    variables: {},
  };
}

async function probeCheckinConfigFields(credentials) {
  const definitions = [
    ['probeNotSign', 'reserve.notSign', 'notSign'],
    ['probeDoorSignOpen', 'adm.doorSignOpen', 'doorSignOpen'],
    ['probeDoorSignURL', 'adm.doorSignURL', 'doorSignURL'],
  ];
  const config = {};
  const rejected = [];

  for (const [operationName, fieldName, key] of definitions) {
    try {
      const result = await graphqlWithTimeout(
        singleCheckinConfigPayload(operationName, fieldName),
        CHECKIN_INITIAL_QUERY_TIMEOUT_MS,
        credentials,
      );
      config[key] = decodeCheckinConfigValue(result?.data?.userAuth?.config?.value);
    } catch (error) {
      rejected.push(`${key}: ${error.message || '读取失败'}`);
    }
  }

  if (!Object.keys(config).length) {
    throw new Error(`学校拒绝读取全部签到配置字段：${rejected.join('；')}`);
  }
  if (rejected.length) log(`部分签到配置字段读取失败：${rejected.join('；')}`, 'warn');
  return config;
}

function autoCheckinPayload() {
  return {
    operationName: 'autoSign',
    query: 'mutation autoSign {\n userAuth {\n reserve {\n autoSign\n }\n }\n}',
    variables: {},
  };
}

function emergencyCheckinPayload(qrData) {
  return {
    operationName: 'offlineScan',
    query:
      'mutation offlineScan($qr: String!) {\n userAuth {\n reserve {\n offlineScan(qrData: $qr)\n }\n }\n}',
    variables: { qr: qrData },
  };
}

async function graphql(payload, options = {}) {
  const headers = {
    'Content-Type': 'application/json',
    'X-Trace-Cookie': options.cookie ?? state.config.cookie,
    'X-Trace-Authorization': options.authorization ?? state.config.authorization ?? '',
  };
  if (options.tomorrow) {
    headers['X-Trace-User-Agent'] =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/107.0.0.0 Safari/537.36 NetType/WIFI MicroMessenger/7.0.20.1781(0x6700143B) WindowsWechat(0x63090719) XWEB/8391 Flue';
  }
  const response = await fetch('/api/proxy', {
    method: 'POST',
    headers,
    body: JSON.stringify(payload),
    signal: options.signal,
  });
  const text = await response.text();
  let data;
  try {
    data = JSON.parse(text);
  } catch {
    throw new Error(`接口返回非 JSON：${text.slice(0, 120)}`);
  }
  if (!response.ok) {
    const error = new Error(data.message || data.error || `HTTP ${response.status}`);
    error.httpStatus = response.status;
    error.remoteCode = data.code ?? data.error?.code;
    error.actionUrl = data.url ?? data.error?.url ?? '';
    error.isGuardRisk = isRiskMessage(error.message);
    throw error;
  }
  if (data.errors?.length) {
    const message = data.errors.map(formatGraphqlError).filter(Boolean).join('；');
    const error = new Error(message || 'GraphQL 返回空错误');
    error.graphqlErrors = data.errors;
    const structuredError =
      data.errors.find(
        (item) => [4, 5].includes(Number(graphqlErrorCode(item))) && graphqlErrorActionUrl(item),
      ) ||
      data.errors.find((item) => graphqlErrorActionUrl(item)) ||
      data.errors.find((item) => graphqlErrorCode(item) != null) ||
      data.errors.find((item) => item && typeof item === 'object') ||
      {};
    error.remoteCode = graphqlErrorCode(structuredError);
    error.actionUrl = graphqlErrorActionUrl(structuredError);
    error.isGuardRisk = isRiskMessage(error.message);
    throw error;
  }
  return data;
}

async function graphqlWithTimeout(payload, timeoutMs, options = {}) {
  const controller = new AbortController();
  const parentSignal = options.signal;
  const abortFromParent = () => controller.abort();
  if (parentSignal?.aborted) controller.abort();
  else parentSignal?.addEventListener('abort', abortFromParent, { once: true });
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
    return await graphql(payload, { ...options, signal: controller.signal });
  } catch (error) {
    if (controller.signal.aborted && !parentSignal?.aborted) {
      const timeoutError = new Error('签到状态查询超时');
      timeoutError.name = 'TimeoutError';
      throw timeoutError;
    }
    throw error;
  } finally {
    clearTimeout(timer);
    parentSignal?.removeEventListener('abort', abortFromParent);
  }
}

function waitForCheckinMutation(mutationPromise, fieldName, abortController) {
  const observed = mutationPromise
    .then((result) => {
      assertCheckinAccepted(result, fieldName);
      return { settled: true, result, error: null };
    })
    .catch((error) => ({ settled: true, result: null, error }));

  return new Promise((resolve) => {
    let finished = false;
    const timer = setTimeout(() => {
      finished = true;
      abortController?.abort();
      const error = new Error('签到请求已发出，但在限定时间内未返回');
      error.checkinTimedOut = true;
      resolve({ settled: false, result: null, error });
    }, CHECKIN_MUTATION_WAIT_MS);

    observed.then((outcome) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      resolve(outcome);
    });
  });
}

function isRiskMessage(message) {
  return /频繁|过快|封|禁|限制|风控|验证码|captcha|access denied|denied|登录|过期|失效|非法|异常|黑名单/i.test(
    String(message || ''),
  );
}

function handleRiskStop(message) {
  if (state.guardStopped) return;
  state.guardStopped = true;
  stopPolling(false);
  els.countdown.textContent = 'STOP';
  els.modeText.textContent = '已触发保护';
  els.stateText.textContent = '疑似风控，已停止请求';
  els.monitorPanel.classList.remove('is-running');
  log(`疑似风控/账号异常，已自动停止：${message}`, 'error');
}

function formatGraphqlError(error) {
  if (!error || typeof error !== 'object') return String(error || '');
  const parts = [
    error.message,
    error.msg,
    error.debugMessage,
    error.extensions?.code,
    error.extensions?.category,
    error.extensions?.reason,
  ].filter(Boolean);
  if (parts.length) return parts.join(' / ');
  return JSON.stringify(error);
}

function graphqlErrorCode(error) {
  if (!error || typeof error !== 'object') return undefined;
  return error.code ?? error.extensions?.code ?? error.extensions?.data?.code ?? error.extensions?.exception?.code;
}

function graphqlErrorActionUrl(error) {
  if (!error || typeof error !== 'object') return '';
  return error.url ?? error.extensions?.url ?? error.extensions?.data?.url ?? error.extensions?.exception?.url ?? '';
}

function decodeCheckinConfigValue(value) {
  if (typeof value !== 'string') return value;
  try {
    return JSON.parse(value);
  } catch {
    return value;
  }
}

function decodeCheckinConfig(config) {
  return Object.fromEntries(
    Object.entries(config || {}).map(([key, value]) => [key, decodeCheckinConfigValue(value)]),
  );
}

function parseCheckinSnapshot(result, capabilitiesKnown = true) {
  const userAuth = result?.data?.userAuth || {};
  return {
    reservation: userAuth.reserve?.reserve || null,
    qrUrl: userAuth.reserve?.qrUrl || '',
    weixiao: userAuth.reserve?.weixiao || {},
    config: decodeCheckinConfig(userAuth.config),
    capabilitiesKnown,
  };
}

async function queryCheckinSnapshot(credentials) {
  let snapshot;
  try {
    snapshot = parseCheckinSnapshot(
      await graphqlWithTimeout(
        checkinStatusPayload(),
        CHECKIN_INITIAL_QUERY_TIMEOUT_MS,
        credentials,
      ),
    );
  } catch (error) {
    const schemaMismatch = /Cannot query field|Unknown field|getSchConfig|qrUrl/i.test(error.message || '');
    if (!schemaMismatch) throw error;
    log('学校接口未返回签到能力配置，已降级为只查询当前预约', 'warn');
    snapshot = parseCheckinSnapshot(
      await graphqlWithTimeout(
        checkinReservationPayload(),
        CHECKIN_INITIAL_QUERY_TIMEOUT_MS,
        credentials,
      ),
      false,
    );
  }
  updateCheckinSummary(snapshot);
  return snapshot;
}

function updateCheckinSummary(snapshot) {
  const reservation = snapshot?.reservation;
  if (!reservation) {
    state.checkinSummary = '无当前预约';
    updateSummary();
    return;
  }

  const room = reservation.lib_name || `场馆 ${reservation.lib_id || '-'}`;
  const seat = reservation.seat_name ? ` ${reservation.seat_name} 号` : '';
  state.checkinSummary = `待签到 · ${room}${seat}`;
  updateSummary();
}

function checkinReservationKey(reservation) {
  if (!reservation) return '';
  const values = [reservation.lib_id, reservation.seat_key, reservation.date];
  if (values.some((value) => value === null || value === undefined || String(value) === '')) return '';
  return values.map((value) => String(value)).join('|');
}

function safeCheckinUrl(value) {
  if (typeof value !== 'string' || !value.trim()) return '';
  try {
    const url = new URL(value, OFFICIAL_WEB_URL);
    const localHttp =
      url.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
    if ((url.protocol !== 'https:' && !localHttp) || url.username || url.password) return '';
    return url.href;
  } catch {
    return '';
  }
}

function getPendingCheckinAttempt(reservation) {
  const attempt = state.checkinAttempt;
  const reservationKey = checkinReservationKey(reservation);
  if (!attempt || !reservationKey || attempt.reservationKey !== reservationKey) return null;
  if (!['pending', 'unknown', 'action-required', 'verified'].includes(attempt.status)) {
    state.checkinAttempt = null;
    return null;
  }
  return attempt;
}

function checkinMutationValue(result, fieldName) {
  return result?.data?.userAuth?.reserve?.[fieldName];
}

function assertCheckinAccepted(result, fieldName) {
  const value = checkinMutationValue(result, fieldName);
  if (value === false || value === null || value === undefined) {
    const error = new Error('签到接口没有返回成功结果');
    error.checkinRejected = true;
    throw error;
  }
  if (typeof value === 'string' && /失败|无效|错误|过期|不支持/i.test(value)) {
    const error = new Error(value);
    error.checkinRejected = true;
    throw error;
  }
}

function describeCheckinRequirement(snapshot) {
  if (!snapshot?.capabilitiesKnown) {
    return {
      kind: 'unknown',
      summary: '能力未知',
      message: '已查到当前预约，但学校接口没有返回签到能力配置；请在官方签到页确认，或粘贴已扫描的场馆/应急码后提交。',
    };
  }

  const config = snapshot?.config || {};
  if (config.forbidQrValid) {
    return {
      kind: 'forbidden',
      summary: '当前不可签到',
      message:
        typeof config.forbidQrValid === 'string'
          ? config.forbidQrValid
          : '学校当前签到通道暂未开放。',
    };
  }

  if (config.notSign) {
    return {
      kind: 'auto',
      summary: '支持一键签到',
      message: '学校已开放设备异常时的一键签到通道。',
    };
  }

  if (snapshot?.weixiao?.isOpen) {
    const actionUrl = safeCheckinUrl(snapshot.weixiao.url);
    return {
      kind: 'weixiao',
      summary: '学校专属入口',
      actions: actionUrl ? [{ label: '打开学校专属签到入口', url: actionUrl }] : [],
      message: actionUrl
        ? '学校使用专属签到入口，请通过下方已校验的官方返回地址继续。'
        : '学校使用专属签到入口，但接口返回的地址格式无效，请从官方签到页进入。',
    };
  }

  const doorOpen = Boolean(config.doorSignOpen);
  const doorUrl = doorOpen ? safeCheckinUrl(config.doorSignURL) : '';
  const qrHelpUrl = safeCheckinUrl(snapshot?.qrUrl);
  const details = [];
  const actions = [];
  if (doorOpen) {
    details.push(doorUrl ? '学校同时开放闸机签到说明' : '学校同时开放闸机签到');
    if (doorUrl) actions.push({ label: '打开闸机签到说明', url: doorUrl });
  }
  if (qrHelpUrl) {
    details.push('学校提供二维码签到说明');
    actions.push({ label: '打开二维码签到说明', url: qrHelpUrl });
  }
  return {
    kind: 'terminal',
    summary: '需现场扫码',
    actions,
    message: `当前预约需由馆内扫码机扫描官方手机端持续刷新的个人动态码；也可粘贴手机扫描到的场馆/应急码。${
      details.length ? ` ${details.join('；')}` : ''
    }`,
  };
}

function describeCheckinChannels(snapshot) {
  const config = snapshot?.config || {};
  const actions = [];
  const details = [];
  const doorOpen = Boolean(config.doorSignOpen);
  const doorUrl = doorOpen ? safeCheckinUrl(config.doorSignURL) : '';
  const weixiaoOpen = Boolean(snapshot?.weixiao?.isOpen);
  const weixiaoUrl = weixiaoOpen ? safeCheckinUrl(snapshot.weixiao.url) : '';
  const qrHelpUrl = safeCheckinUrl(snapshot?.qrUrl);

  details.push(config.notSign ? '一键签到：开放' : '一键签到：未开放');
  details.push(
    doorOpen
      ? `闸机签到：开放${doorUrl ? '（有官方入口）' : '（需到馆使用闸机）'}`
      : '闸机签到：配置未开放',
  );
  details.push(weixiaoOpen ? '学校专属入口：开放' : '学校专属入口：未开放');
  if (config.forbidQrValid) details.push(`学校限制：${String(config.forbidQrValid)}`);

  if (doorUrl) actions.push({ label: '打开学校闸机签到入口', url: doorUrl });
  if (weixiaoUrl) actions.push({ label: '打开学校专属签到入口', url: weixiaoUrl });
  if (qrHelpUrl) actions.push({ label: '打开二维码签到说明', url: qrHelpUrl });

  return {
    doorOpen,
    summary: doorOpen ? '开放闸机签到' : config.notSign ? '支持一键签到' : '需现场签到',
    message: `只读检测结果：${details.join('；')}`,
    actions,
  };
}

async function inspectCheckinChannels() {
  if (state.running) {
    log('请先停止当前捡漏或明日预约任务，再检测签到方式', 'warn');
    return;
  }
  if (state.checkinBusy) {
    log('签到功能正在处理，请稍候', 'warn');
    return;
  }
  if (!state.config.cookie) {
    log('请先登录并保存 Cookie', 'warn');
    switchTab('config');
    return;
  }

  const originalText = els.inspectCheckinBtn.textContent;
  state.checkinBusy = true;
  els.inspectCheckinBtn.disabled = true;
  els.remoteCheckinBtn.disabled = true;
  els.submitArrivalCodeBtn.disabled = true;
  els.inspectCheckinBtn.textContent = '检测中';
  els.monitorPanel.setAttribute('aria-busy', 'true');
  els.countdown.textContent = 'SCAN';
  els.modeText.textContent = '只读检测签到方式';
  els.stateText.textContent = '正在读取学校返回的签到配置，不会提交签到请求';
  els.monitorPanel.classList.remove('is-success');
  els.monitorPanel.classList.add('is-running');

  try {
    const credentials = {
      cookie: state.config.cookie,
      authorization: state.config.authorization || '',
    };
    let snapshot;
    try {
      snapshot = await queryCheckinSnapshot(credentials);
    } catch (error) {
      if (!/access denied/i.test(error.message || '')) throw error;
      log('学校拒绝了精简查询，正在改用官方签到页原样查询', 'warn');
      try {
        snapshot = parseCheckinSnapshot(
          await graphqlWithTimeout(
            officialCheckinIndexPayload(),
            CHECKIN_INITIAL_QUERY_TIMEOUT_MS,
            credentials,
          ),
        );
      } catch (officialError) {
        if (!/access denied/i.test(officialError.message || '')) throw officialError;
        log('官方组合查询仍被拒绝，正在逐项读取一键和闸机配置', 'warn');
        const reservationSnapshot = parseCheckinSnapshot(
          await graphqlWithTimeout(
            checkinReservationPayload(),
            CHECKIN_INITIAL_QUERY_TIMEOUT_MS,
            credentials,
          ),
          false,
        );
        snapshot = {
          ...reservationSnapshot,
          config: await probeCheckinConfigFields(credentials),
          capabilitiesKnown: true,
        };
      }
      updateCheckinSummary(snapshot);
    }
    if (!snapshot.reservation) throw new Error('当前没有可检测签到方式的预约');
    const result = describeCheckinChannels(snapshot);
    state.checkinSummary = result.summary;
    updateSummary();
    renderCheckinActionLinks(result.actions);
    els.countdown.textContent = result.doorOpen ? 'GATE' : 'INFO';
    els.modeText.textContent = result.doorOpen ? '学校开放闸机签到' : '学校签到方式检测完成';
    els.stateText.textContent = result.message;
    els.monitorPanel.classList.remove('is-running');
    els.monitorPanel.classList.toggle('is-success', result.doorOpen);
    log(result.message, result.doorOpen ? 'success' : 'warn');
  } catch (error) {
    state.checkinSummary = '方式检测失败';
    updateSummary();
    els.countdown.textContent = 'FAIL';
    els.modeText.textContent = '签到方式检测失败';
    els.stateText.textContent = error.message || '学校签到配置读取失败';
    els.monitorPanel.classList.remove('is-running', 'is-success');
    log(`签到方式检测失败：${error.message || '未知错误'}`, 'error');
  } finally {
    state.checkinBusy = false;
    els.inspectCheckinBtn.disabled = false;
    els.remoteCheckinBtn.disabled = false;
    els.submitArrivalCodeBtn.disabled = false;
    els.inspectCheckinBtn.textContent = originalText;
    els.monitorPanel.setAttribute('aria-busy', 'false');
  }
}

function setResultDialogState(kind) {
  const pending = kind !== 'success';
  els.successDialog.classList.toggle('is-pending', pending);
  els.successMark.textContent = kind === 'success' ? '✓' : kind === 'pending' ? '?' : '!';
}

function renderCheckinActionLinks(actions = []) {
  els.checkinActionLinks.replaceChildren();
  actions.forEach((action) => {
    const url = safeCheckinUrl(action?.url);
    if (!url) return;
    const link = document.createElement('a');
    link.className = 'checkin-route-link';
    link.href = url;
    link.target = '_blank';
    link.rel = 'noopener noreferrer';
    link.textContent = action.label || '打开官方签到入口';
    els.checkinActionLinks.appendChild(link);
  });
  els.checkinActionLinks.hidden = !els.checkinActionLinks.childElementCount;
}

function setCheckinRetryVisible(visible) {
  els.resetCheckinAttemptBtn.hidden = !visible;
}

async function showRemoteCheckinOutcome(snapshot, method, verified) {
  const reservation = snapshot?.reservation || {};
  const room = reservation.lib_name || `场馆 ${reservation.lib_id || '-'}`;
  const seat = reservation.seat_name ? `${reservation.seat_name} 号` : '未知座位';
  const resultText = verified ? '到馆签到成功' : '签到结果待确认';
  state.checkinSummary = `${verified ? '已签到' : '待确认'} · ${room} ${seat}`;
  updateSummary();
  document.title = verified ? '[已签到] gotolibray' : '[签到待确认] gotolibray';
  els.countdown.textContent = verified ? 'DONE' : 'CHECK';
  els.modeText.textContent = resultText;
  els.stateText.textContent = verified
    ? `${room} · ${seat} · ${method}`
    : `${room} · ${seat} · ${method}；请求只提交了一次，请稍后从官方页面复核`;
  els.monitorPanel.classList.remove('is-running');
  els.monitorPanel.classList.toggle('is-success', verified);
  els.successTitle.textContent = resultText;
  els.successText.textContent = verified
    ? `${room} · ${seat}`
    : `${room} · ${seat}；为避免重复签到，同一预约会保持锁定，复核后可在配置页手动解锁`;
  setResultDialogState(verified ? 'success' : 'pending');
  renderCheckinActionLinks();
  setCheckinRetryVisible(!verified);
  log(`${resultText}：${room} ${seat}（${method}）`, verified ? 'success' : 'warn');
  if (verified) playBeep();
  if (typeof els.successDialog.showModal === 'function') els.successDialog.showModal();
  void sendNtfy(`${resultText}：${room} ${seat}`);
}

async function showRemoteCheckinError(snapshot, method, error, outcomeUnknown) {
  const reservation = snapshot?.reservation || {};
  const room = reservation.lib_name || `场馆 ${reservation.lib_id || '-'}`;
  const seat = reservation.seat_name ? `${reservation.seat_name} 号` : '未知座位';
  const title = outcomeUnknown ? '签到结果待确认' : '签到未通过';
  const detail = outcomeUnknown
    ? `请求已经发出，但暂未确认最终状态：${error.message}`
    : error.message || '学校签到接口未接受本次请求';
  state.checkinSummary = `${outcomeUnknown ? '待确认' : '未通过'} · ${room} ${seat}`;
  updateSummary();
  els.countdown.textContent = outcomeUnknown ? 'CHECK' : 'FAIL';
  els.modeText.textContent = title;
  els.stateText.textContent = detail;
  els.monitorPanel.classList.remove('is-running', 'is-success');
  els.successTitle.textContent = title;
  els.successText.textContent = outcomeUnknown
    ? `${room} · ${seat}；请求没有自动重试，请稍后从官方页面复核`
    : `${room} · ${seat}；${detail}`;
  setResultDialogState(outcomeUnknown ? 'pending' : 'error');
  renderCheckinActionLinks();
  setCheckinRetryVisible(outcomeUnknown);
  log(`${title}：${detail}（${method}）`, outcomeUnknown ? 'warn' : 'error');
  if (typeof els.successDialog.showModal === 'function') els.successDialog.showModal();
  if (outcomeUnknown) void sendNtfy(`${title}：${room} ${seat}`);
}

function showCheckinRequirement(requirement) {
  state.checkinSummary = requirement.summary;
  updateSummary();
  els.countdown.textContent = requirement.kind === 'weixiao' ? 'OPEN' : 'SCAN';
  els.modeText.textContent = requirement.kind === 'weixiao' ? '学校专属签到入口' : '需要其他签到通道';
  els.stateText.textContent = requirement.message;
  els.monitorPanel.classList.remove('is-running', 'is-success');
  renderCheckinActionLinks(requirement.actions);
  setCheckinRetryVisible(false);
  log(requirement.message, requirement.kind === 'forbidden' ? 'error' : 'warn');
}

async function remoteCheckin({ useEmergencyCode = false } = {}) {
  if (state.running) {
    log('请先停止当前捡漏或明日预约任务，再执行到馆签到', 'warn');
    return;
  }
  if (state.checkinBusy) {
    log('到馆签到正在检测或复核，请稍候', 'warn');
    return;
  }
  if (!state.config.cookie) {
    log('请先登录并保存 Cookie', 'warn');
    switchTab('config');
    return;
  }

  const emergencyCode = els.arrivalCodeInput.value;
  if (useEmergencyCode && !emergencyCode.trim()) {
    log('请先粘贴手机扫描得到的场馆/应急码原始内容', 'warn');
    switchTab('config');
    els.arrivalCodeInput.focus();
    return;
  }

  const checkinCredentials = Object.freeze({
    cookie: state.config.cookie,
    authorization: state.config.authorization || '',
  });
  const hasEmergencyCode = useEmergencyCode;
  const actionButton = useEmergencyCode ? els.submitArrivalCodeBtn : els.remoteCheckinBtn;
  const originalRemoteText = els.remoteCheckinBtn.textContent;
  const originalCodeText = els.submitArrivalCodeBtn.textContent;
  const originalLeakDisabled = els.leakBtn.disabled;
  const originalTomorrowDisabled = els.tomorrowBtn.disabled;
  const originalStopDisabled = els.stopBtn.disabled;
  const originalSaveDisabled = els.saveBtn.disabled;
  const originalExchangeDisabled = els.exchangeCookieBtn.disabled;
  const originalRefreshDisabled = els.refreshRoomsBtn.disabled;
  const originalClearCookieDisabled = els.clearCookieBtn.disabled;
  const originalLogoutDisabled = els.logoutBtn.disabled;
  state.checkinBusy = true;
  els.remoteCheckinBtn.disabled = true;
  els.submitArrivalCodeBtn.disabled = true;
  els.leakBtn.disabled = true;
  els.tomorrowBtn.disabled = true;
  els.stopBtn.disabled = true;
  els.saveBtn.disabled = true;
  els.exchangeCookieBtn.disabled = true;
  els.refreshRoomsBtn.disabled = true;
  els.clearCookieBtn.disabled = true;
  els.logoutBtn.disabled = true;
  actionButton.textContent = '检测中';
  els.monitorPanel.setAttribute('aria-busy', 'true');
  els.countdown.textContent = 'SIGN';
  els.modeText.textContent = '到馆签到检测';
  els.stateText.textContent = '正在查询当前预约和学校签到方式';
  els.monitorPanel.classList.remove('is-success');
  els.monitorPanel.classList.add('is-running');
  renderCheckinActionLinks();

  try {
    const before = await queryCheckinSnapshot(checkinCredentials);
    if (!before.reservation) {
      state.checkinAttempt = null;
      setCheckinRetryVisible(false);
      throw new Error('当前没有可签到的预约');
    }
    const currentReservationKey = checkinReservationKey(before.reservation);
    if (
      state.checkinAttempt &&
      state.checkinAttempt.reservationKey !== currentReservationKey
    ) {
      state.checkinAttempt = null;
      setCheckinRetryVisible(false);
    }
    const pendingAttempt = getPendingCheckinAttempt(before.reservation);
    if (pendingAttempt) {
      if (pendingAttempt.status === 'verified') {
        state.checkinSummary = `已签到 · ${before.reservation.lib_name || '当前场馆'} ${before.reservation.seat_name || ''}`;
        updateSummary();
        els.countdown.textContent = 'DONE';
        els.modeText.textContent = '本页面已确认签到成功';
        els.stateText.textContent = '学校签到接口已经明确返回成功，未重复提交请求';
        els.monitorPanel.classList.remove('is-running');
        els.monitorPanel.classList.add('is-success');
        setCheckinRetryVisible(false);
        log('本页面已记录当前预约签到成功，未重复发送签到 mutation', 'success');
        return;
      }
      if (pendingAttempt.status === 'action-required' && pendingAttempt.actionUrl) {
        state.checkinSummary = '需页面确认';
        updateSummary();
        els.countdown.textContent = 'OPEN';
        els.modeText.textContent = '打开签到确认页';
        els.stateText.textContent = '这条预约仍需在学校返回的页面继续确认';
        els.monitorPanel.classList.remove('is-running', 'is-success');
        setCheckinRetryVisible(false);
        renderCheckinActionLinks([
          { label: '继续官方签到确认', url: pendingAttempt.actionUrl },
        ]);
        switchTab('config');
        log('已恢复学校返回的后续签到确认入口，没有重复提交请求', 'warn');
        return;
      }
      if (pendingAttempt.status === 'unknown') {
        state.checkinSummary = '结果待确认';
        updateSummary();
        els.countdown.textContent = 'CHECK';
        els.modeText.textContent = '已阻止重复签到';
        els.stateText.textContent = '请先在官方页复核；确认仍未签到后，可在配置页手动解锁重试';
        els.monitorPanel.classList.remove('is-running', 'is-success');
        setCheckinRetryVisible(true);
        switchTab('config');
        log('同一预约结果仍待确认，未再次发送签到 mutation', 'warn');
        return;
      }
      state.checkinSummary = pendingAttempt.status === 'pending' ? '正在确认' : '结果待确认';
      updateSummary();
      els.countdown.textContent = 'WAIT';
      els.modeText.textContent = '已阻止重复签到';
      els.stateText.textContent = '同一预约正在提交或等待接口确认，请稍候';
      els.monitorPanel.classList.remove('is-running', 'is-success');
      log('已阻止同一预约的重复签到请求', 'warn');
      return;
    }

    const requirement = describeCheckinRequirement(before);
    const reservationKey = currentReservationKey;
    if ((hasEmergencyCode || requirement.kind === 'auto') && !reservationKey) {
      throw new Error('当前预约缺少场馆、座位或日期信息，未发送签到请求');
    }
    let method;
    let fieldName;
    let mutationPayload;
    if (hasEmergencyCode) {
      method = '场馆/应急码';
      fieldName = 'offlineScan';
      actionButton.textContent = '提交中';
      els.stateText.textContent = '正在提交场馆/应急签到码';
      mutationPayload = emergencyCheckinPayload(emergencyCode);
    } else if (requirement.kind === 'auto') {
      method = '学校一键签到';
      fieldName = 'autoSign';
      actionButton.textContent = '签到中';
      els.stateText.textContent = '学校已开放一键签到，正在提交';
      mutationPayload = autoCheckinPayload();
    } else {
      showCheckinRequirement(requirement);
      if (requirement.kind !== 'forbidden') switchTab('config');
      return;
    }

    const dispatchedAt = Date.now();
    const checkinAttempt = {
      reservationKey,
      dispatchedAt,
      method,
      status: 'pending',
    };
    state.checkinAttempt = checkinAttempt;
    state.checkinSummary = '正在确认';
    setCheckinRetryVisible(false);
    updateSummary();

    const mutationController = new AbortController();
    const mutationPromise = graphql(mutationPayload, {
      ...checkinCredentials,
      signal: mutationController.signal,
    });
    if (hasEmergencyCode) els.arrivalCodeInput.value = '';
    const mutationOutcomePromise = waitForCheckinMutation(mutationPromise, fieldName, mutationController);

    actionButton.textContent = '确认中';
    els.stateText.textContent = '请求仅提交一次，正在等待学校签到接口确认';
    const mutationOutcome = await mutationOutcomePromise;
    const mutationError = mutationOutcome.error;

    if (mutationError && [4, 5].includes(Number(mutationError.remoteCode))) {
      const actionUrl = safeCheckinUrl(mutationError.actionUrl || '');
      if (actionUrl) {
        checkinAttempt.status = 'action-required';
        checkinAttempt.actionUrl = actionUrl;
        setCheckinRetryVisible(false);
        state.checkinSummary = '需页面确认';
        updateSummary();
        els.countdown.textContent = 'OPEN';
        els.modeText.textContent = '打开签到确认页';
        els.stateText.textContent = '学校要求在返回的页面继续确认，请使用下方已校验的官方地址';
        els.monitorPanel.classList.remove('is-running', 'is-success');
        renderCheckinActionLinks([{ label: '继续官方签到确认', url: actionUrl }]);
        log('签到接口要求继续页面确认，已显示校验后的官方入口', 'warn');
        switchTab('config');
        return;
      }
      mutationError.message = `${mutationError.message}；接口返回的确认地址格式无效`;
    }

    if (mutationError) {
      const outcomeUnknown =
        !mutationOutcome.settled || !mutationError.checkinRejected;
      if (outcomeUnknown) checkinAttempt.status = 'unknown';
      else if (state.checkinAttempt === checkinAttempt) state.checkinAttempt = null;
      await showRemoteCheckinError(before, method, mutationError, outcomeUnknown);
      return;
    }

    checkinAttempt.status = 'verified';
    await showRemoteCheckinOutcome(before, method, true);
  } catch (error) {
    if (state.checkinSummary !== '无当前预约') state.checkinSummary = '签到检测失败';
    updateSummary();
    els.countdown.textContent = 'FAIL';
    els.modeText.textContent = '到馆签到检测失败';
    els.stateText.textContent = error.message || '签到请求失败';
    els.monitorPanel.classList.remove('is-running', 'is-success');
    log(`到馆签到检测失败：${error.message || '未知错误'}`, 'error');
    if (/Cookie|登录|配置/.test(error.message || '')) switchTab('config');
  } finally {
    state.checkinBusy = false;
    els.monitorPanel.setAttribute('aria-busy', 'false');
    els.remoteCheckinBtn.disabled = false;
    els.submitArrivalCodeBtn.disabled = false;
    els.leakBtn.disabled = originalLeakDisabled;
    els.tomorrowBtn.disabled = originalTomorrowDisabled;
    els.stopBtn.disabled = originalStopDisabled;
    els.saveBtn.disabled = originalSaveDisabled;
    els.exchangeCookieBtn.disabled = originalExchangeDisabled;
    els.refreshRoomsBtn.disabled = originalRefreshDisabled;
    els.clearCookieBtn.disabled = originalClearCookieDisabled;
    els.logoutBtn.disabled = originalLogoutDisabled;
    els.remoteCheckinBtn.textContent = originalRemoteText;
    els.submitArrivalCodeBtn.textContent = originalCodeText;
  }
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
  const value =
    result?.data?.userAuth?.reserve?.reserueSeat ??
    result?.data?.userAuth?.reserve?.reserveSeat;
  return value;
}

function isReserveFieldError(error, fieldName) {
  if (new RegExp(`(?:Cannot query field|Unknown field|Field).*${fieldName}`, 'i').test(error.message)) {
    return true;
  }
  return Array.isArray(error.graphqlErrors) && !error.message.replace('GraphQL 返回空错误', '').trim();
}

async function reserveSeatRequest(seatKey) {
  const preferredField = state.reserveFieldName || 'reserueSeat';
  const fieldNames = [...new Set([preferredField, 'reserueSeat', 'reserveSeat'])];

  for (const fieldName of fieldNames) {
    try {
      const result = await graphql(reservePayload(seatKey, fieldName));
      state.reserveFieldName = fieldName;
      return result;
    } catch (error) {
      if (fieldName === fieldNames[fieldNames.length - 1] || !isReserveFieldError(error, fieldName)) {
        if (!error.message.trim()) error.message = `${fieldName} 返回空错误`;
        throw error;
      }
      log(`预约接口 ${fieldName} 返回异常，已自动切换备用字段：${error.message || '空错误'}`, 'warn');
    }
  }

  throw new Error('预约接口字段不可用');
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
  if (state.checkinBusy) {
    log('请等待到馆签到复核完成后再刷新阅览室', 'warn');
    return;
  }
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
    logNoSeat();
    return false;
  }

  log(`第 ${state.rounds} 轮：发现 ${freeSeats.length} 个候选空位`, 'success');
  const batches = chunk(freeSeats, state.config.concurrency || 1);
  for (const batch of batches) {
    const result = await raceReserveBatch(batch);
    if (result) return true;
  }

  return false;
}

function logNoSeat() {
  const now = Date.now();
  if (now - state.lastNoSeatLogAt < 4000) return;
  state.lastNoSeatLogAt = now;
  log(`第 ${state.rounds} 轮：没有空位`, 'info');
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

  const limit = state.config.candidate_limit || 1;
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

  return Math.random() * 100;
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
  try {
    const result = await reserveSeatRequest(seat.key);
    if (state.success) return true;
    if (isSuccessResult(result)) {
      await handleSuccess(seat);
      return true;
    }

    log(`座位 ${seatName} 未成功：${getReserveMessage(result)}；${formatSeatDebug(seat)}`, 'warn');
  } catch (error) {
    if (error.isGuardRisk || isRiskMessage(error.message)) {
      handleRiskStop(error.message);
      return false;
    }
    log(`座位 ${seatName} 失败：${error.message || '接口返回空错误'}；${formatSeatDebug(seat)}`, 'error');
  }

  state.seatCooldown[seat.key] = Date.now() + (state.config.cooldown || 1.2) * 1000;
  return false;
}

function isFreeSeat(seat) {
  if (Number(seat.type) !== 1) return false;
  if (!seat.name || !seat.key) return false;
  if (seat.seat_status !== undefined && seat.seat_status !== null) {
    return Number(seat.seat_status) === 1;
  }
  return isFreeOccupancyStatus(seat.status);
}

function isFreeOccupancyStatus(value) {
  if (typeof value === 'boolean') return value === false;
  if (typeof value === 'number') return value === 0;
  const normalized = String(value).trim().toLowerCase();
  return ['0', 'false', 'free', 'available', 'empty', '空闲', '可选'].includes(normalized);
}

function formatSeatDebug(seat) {
  return `key=${seat.key}, type=${seat.type}, status=${String(seat.status)}, seat_status=${String(seat.seat_status)}`;
}

async function handleSuccess(seat, kind = 'leak', verification = null) {
  if (state.success) return;
  state.success = true;
  stopPolling(false);
  const seatName = seat.name || seat.key;
  const isTomorrow = kind === 'tomorrow';
  const actionText = isTomorrow ? '明日预约' : '抢座';
  try {
    await consumeHairForSuccess();
  } catch (error) {
    log(`头发扣除失败：${error.message}`, 'error');
  }
  document.title = isTomorrow ? '[明日预约成功] gotolibray' : '[已抢到] gotolibray';
  els.stateText.textContent = `${actionText}成功：${seatName}`;
  els.modeText.textContent = `${actionText}成功`;
  els.monitorPanel.classList.remove('is-running');
  els.monitorPanel.classList.add('is-success');
  els.successTitle.textContent = isTomorrow ? '明日预约成功' : '抢到座位了';
  els.successText.textContent = `座位：${seatName}${verification?.day ? ` · ${verification.day}` : ''}`;
  setResultDialogState('success');
  log(`${actionText}成功：${seatName}`, 'success');
  playBeep();
  if (typeof els.successDialog.showModal === 'function') els.successDialog.showModal();
  void sendNtfy(`${actionText}成功：${seatName}`);
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
  const topic = state.config.ntfy_topic;
  if (!topic) return;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), NTFY_TIMEOUT_MS);
  try {
    const response = await fetch(`https://ntfy.sh/${encodeURIComponent(topic)}`, {
      method: 'POST',
      body: message,
      signal: controller.signal,
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
  } catch (error) {
    const detail = error.name === 'AbortError' ? '请求超时' : error.message;
    log(`ntfy 推送失败：${detail}`, 'warn');
  } finally {
    clearTimeout(timer);
  }
}

function nextDelay(mode) {
  const base = (state.config.slow_interval || defaultConfig.slow_interval) * 1000;
  const jitter = Math.floor(Math.random() * Math.min(80, base * 0.15));
  return Math.max(250, base + jitter + state.backoffMs);
}

function scheduleNextPoll(mode) {
  clearTimeout(state.timer);
  if (!state.running) return;
  const delay = nextDelay(mode);
  if (state.worker) {
    state.worker.postMessage({ type: 'schedule', delay, task: 'poll' });
  } else {
    state.timer = setTimeout(handlePollTick, delay);
  }
}

async function handlePollTick() {
  if (!state.running) return;
  try {
    const success = await runOnce();
    state.backoffMs = success ? 0 : Math.max(0, state.backoffMs - 120);
  } catch (error) {
    if (error.isGuardRisk || isRiskMessage(error.message)) {
      handleRiskStop(error.message);
      return;
    }
    state.backoffMs = Math.min(12000, state.backoffMs ? state.backoffMs * 1.6 : 1500);
    log(`轮询失败：${error.message}，退避 ${Math.round(state.backoffMs / 1000)} 秒`, 'error');
  } finally {
    scheduleNextPoll('leak');
  }
}

async function resolveTomorrowRoomSeats(signal) {
  const layout = await graphql(libLayoutPayload(), { signal });
  const seats = getSeats(layout).filter((seat) => Number(seat.type) === 1 && seat.key && seat.name);
  if (!seats.length) throw new Error('当前阅览室没有可预约座位');
  return seats;
}

function resolveNextTomorrowRunAt(timeText) {
  const [hour, minute, second = 0] = String(timeText || defaultConfig.tomorrow_time)
    .split(':')
    .map(Number);
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat('en-US', {
      timeZone: 'Asia/Shanghai',
      year: 'numeric',
      month: 'numeric',
      day: 'numeric',
    })
      .formatToParts(new Date())
      .filter((part) => part.type !== 'literal')
      .map((part) => [part.type, Number(part.value)]),
  );
  let target = Date.UTC(parts.year, parts.month - 1, parts.day, hour - 8, minute, second);
  if (target <= Date.now()) target += 24 * 60 * 60 * 1000;
  return target;
}

function formatTomorrowRunAt(timestamp) {
  return new Intl.DateTimeFormat('zh-CN', {
    timeZone: 'Asia/Shanghai',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hour12: false,
  }).format(new Date(timestamp));
}

function formatRemaining(milliseconds) {
  const totalSeconds = Math.max(0, Math.ceil(milliseconds / 1000));
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  return [hours, minutes, seconds].map((value) => String(value).padStart(2, '0')).join(':');
}

async function enterTomorrowQueue(signal) {
  const response = await fetch('/api/proxy?type=tomorrow-queue', {
    method: 'POST',
    headers: { 'X-Trace-Cookie': state.config.cookie },
    signal,
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data.message || data.error || `HTTP ${response.status}`);
  return data;
}

function getTomorrowLayout(result) {
  return result?.data?.userAuth?.prereserve?.libLayout || null;
}

function getTomorrowAvailableCount(layout) {
  if (!layout) return null;
  const total = Number(layout.seats_total);
  const used = Number(layout.seats_used || 0);
  const booking = Number(layout.seats_booking || 0);
  return Number.isFinite(total) ? Math.max(0, total - used - booking) : null;
}

async function queryTomorrowAvailability(signal) {
  if (state.tomorrowDetailedLayoutSupported !== false) {
    try {
      const result = await graphql(tomorrowLayoutPayload(true), { tomorrow: true, signal });
      const layout = getTomorrowLayout(result);
      state.tomorrowDetailedLayoutSupported = Array.isArray(layout?.seats);
      return {
        ready: Boolean(layout),
        availableCount: getTomorrowAvailableCount(layout),
        seats: Array.isArray(layout?.seats) ? layout.seats : [],
      };
    } catch (error) {
      if (!/(?:Cannot query field|Unknown field).*seats/i.test(error.message)) throw error;
      state.tomorrowDetailedLayoutSupported = false;
      log('明日接口未返回座位明细，将根据空位数量低频尝试候选座位', 'warn');
    }
  }

  const result = await graphql(tomorrowLayoutPayload(false), { tomorrow: true, signal });
  const layout = getTomorrowLayout(result);
  return { ready: Boolean(layout), availableCount: getTomorrowAvailableCount(layout), seats: [] };
}

function waitWithSignal(milliseconds, signal) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      signal?.removeEventListener('abort', abort);
      resolve();
    }, milliseconds);
    const abort = () => {
      clearTimeout(timer);
      reject(new DOMException('任务已停止', 'AbortError'));
    };
    if (signal?.aborted) abort();
    else signal?.addEventListener('abort', abort, { once: true });
  });
}

function getTomorrowCandidates(availability) {
  if (!availability.ready) return [];
  if (availability.availableCount === 0) return [];
  const detailedFreeSeats = availability.seats.filter(isFreeSeat);
  const pool = detailedFreeSeats.length ? detailedFreeSeats : state.tomorrowSeats;
  return pickCandidates(pool);
}

async function tryTomorrowCandidates(candidates, signal) {
  for (const seat of candidates) {
    if (!state.running) return null;
    try {
      els.stateText.textContent = `发现空位，正在尝试 ${seat.name || seat.key}`;
      await graphql(tomorrowSavePayload(seat.key), { tomorrow: true, signal });
      return seat;
    } catch (error) {
      if (error.name === 'AbortError' || !state.running) throw error;
      if (error.isGuardRisk || isRiskMessage(error.message)) throw error;
      state.seatCooldown[seat.key] = Date.now() + (state.config.cooldown || 8) * 1000;
      log(`明日座位 ${seat.name || seat.key} 未抢到：${error.message}`, 'warn');
    }
  }
  return null;
}

async function verifyTomorrowReservation(seat, signal) {
  try {
    const result = await graphql(tomorrowInfoPayload(), { tomorrow: true, signal });
    const verification = result?.data?.userAuth?.prereserve?.prereserve || null;
    const sameLibrary = Number(verification?.lib_id) === Number(state.config.lib_id);
    const actualKey = String(verification?.seat_key || '').replace(/\.$/, '');
    const targetKey = String(seat.key).replace(/\.$/, '');
    if (verification && (!sameLibrary || actualKey !== targetKey)) {
      log('明日预约验证记录与本次座位不一致，请在官方页面复核', 'warn');
    }
    return verification;
  } catch (error) {
    if (error.name === 'AbortError' || !state.running) throw error;
    log(`明日预约结果验证失败：${error.message}`, 'warn');
    return null;
  }
}

function scheduleTomorrowTick() {
  clearTimeout(state.timer);
  if (!state.running || state.mode !== 'tomorrow-wait') return;
  const delay = Math.min(1000, Math.max(0, state.tomorrowRunAt - Date.now()));
  if (state.worker) state.worker.postMessage({ type: 'schedule', delay, task: 'tomorrow' });
  else state.timer = setTimeout(handleTomorrowTick, delay);
}

async function handleTomorrowTick() {
  if (!state.running || state.mode !== 'tomorrow-wait') return;
  const remaining = state.tomorrowRunAt - Date.now();
  if (remaining > 0) {
    els.countdown.textContent = formatRemaining(remaining);
    scheduleTomorrowTick();
    return;
  }
  await runTomorrowReservation();
}

async function runTomorrowReservation() {
  if (!state.running || !state.tomorrowSeats.length) return;
  const signal = state.abortController?.signal;
  const room = getSelectedRoom();
  state.mode = 'tomorrow';
  els.countdown.textContent = 'GO';
  els.modeText.textContent = '明日空位监控';
  els.stateText.textContent = '正在进入预约排队通道';
  try {
    const queue = await enterTomorrowQueue(signal);
    if (!state.running) return;
    log(queue.message || '已完成明日预约排队', queue.shouldStop ? 'error' : 'info');
    if (queue.shouldStop) throw new Error(`排队被拦截：${queue.message}`);

    log(`开始监控 ${room?.name || state.config.lib_id} 的明日空位`, 'success');
    while (state.running) {
      const availability = await queryTomorrowAvailability(signal);
      const candidates = getTomorrowCandidates(availability);
      if (!candidates.length) {
        const now = Date.now();
        els.stateText.textContent = availability.availableCount === 0 ? '当前没有明日空位，继续监控' : '暂未发现可尝试座位';
        if (now - state.tomorrowNoSeatLogAt >= 5000) {
          state.tomorrowNoSeatLogAt = now;
          log('明日预约：当前没有空位，继续监控', 'info');
        }
      } else {
        const countText = availability.availableCount == null ? '' : `约 ${availability.availableCount} 个空位，`;
        log(`明日预约：${countText}尝试 ${candidates.length} 个候选座位`, 'success');
        const reservedSeat = await tryTomorrowCandidates(candidates, signal);
        if (reservedSeat) {
          const verification = await verifyTomorrowReservation(reservedSeat, signal);
          if (!state.running) return;
          await handleSuccess(reservedSeat, 'tomorrow', verification);
          return;
        }
      }
      await waitWithSignal(getTomorrowPollDelay(), signal);
    }
  } catch (error) {
    if (error.name === 'AbortError' && !state.running) return;
    if (error.isGuardRisk || isRiskMessage(error.message)) {
      handleRiskStop(error.message);
      return;
    }
    stopPolling(false);
    els.countdown.textContent = 'FAIL';
    els.modeText.textContent = '明日预约失败';
    els.stateText.textContent = error.message;
    log(`明日预约失败：${error.message}`, 'error');
  }
}

function getTomorrowPollDelay() {
  // 明日接口采用保守轮询并加入轻微抖动，降低固定高频请求带来的风控与接口压力。
  const base = clamp(Number(state.config.tomorrow_interval || defaultConfig.tomorrow_interval), 6, 30);
  const jitter = 0.8 + Math.random() * 0.4;
  return Math.max(5, Math.round(base * jitter * 1000));
}

async function startTomorrowReservation() {
  if (state.running) return;
  if (state.checkinBusy) {
    log('请等待到馆签到检测完成后再启动明日预约', 'warn');
    return;
  }
  try {
    validateConfig();
    state.success = false;
    state.guardStopped = false;
    state.running = true;
    state.mode = 'tomorrow-start';
    state.abortController = new AbortController();
    state.seatCooldown = {};
    state.tomorrowDetailedLayoutSupported = null;
    state.tomorrowNoSeatLogAt = 0;
    els.tomorrowBtn.disabled = true;
    els.stateText.textContent = '正在读取目标阅览室座位';
    const seats = await resolveTomorrowRoomSeats(state.abortController.signal);
    if (!state.running || state.mode !== 'tomorrow-start') return;
    state.tomorrowSeats = seats;
    state.tomorrowRunAt = resolveNextTomorrowRunAt(state.config.tomorrow_time);
    ensureWorkerTimer();
    state.mode = 'tomorrow-wait';
    document.title = '[等待明日预约] gotolibray';
    els.modeText.textContent = '明日预约等待中';
    const room = getSelectedRoom();
    els.stateText.textContent = `${room?.name || state.config.lib_id} · ${formatTomorrowRunAt(state.tomorrowRunAt)} 开始监控`;
    els.monitorPanel.classList.remove('is-success');
    els.monitorPanel.classList.add('is-running');
    await requestWakeLock();
    if (!state.running || state.mode !== 'tomorrow-wait') return;
    log(`明日预约已启动：监控 ${room?.name || state.config.lib_id}，${formatTomorrowRunAt(state.tomorrowRunAt)} 触发`, 'success');
    scheduleTomorrowTick();
  } catch (error) {
    if (error.name === 'AbortError' && !state.running) return;
    stopPolling(false);
    log(error.message, 'error');
    if (/Cookie|阅览室|配置|座位/.test(error.message)) switchTab('config');
  } finally {
    els.tomorrowBtn.disabled = false;
  }
}

function ensureWorkerTimer() {
  if (state.worker || !window.Worker || !window.Blob || !window.URL) return;
  const code = `
    let timer = null;
    self.onmessage = (event) => {
      if (event.data.type === 'schedule') {
        clearTimeout(timer);
        timer = setTimeout(() => self.postMessage({ type: 'tick', task: event.data.task }), event.data.delay);
      }
      if (event.data.type === 'stop') clearTimeout(timer);
    };
  `;
  const blob = new Blob([code], { type: 'application/javascript' });
  state.worker = new Worker(URL.createObjectURL(blob));
  state.worker.onmessage = (event) => {
    if (event.data?.type !== 'tick') return;
    if (event.data.task === 'tomorrow') handleTomorrowTick();
    else handlePollTick();
  };
}

async function startPolling() {
  if (state.running) return;
  if (state.checkinBusy) {
    log('请等待到馆签到检测完成后再启动捡漏', 'warn');
    return;
  }
  try {
    validateConfig();
    state.success = false;
    state.guardStopped = false;
    state.seatCooldown = {};
    ensureWorkerTimer();
    state.running = true;
    state.mode = 'leak';
    state.backoffMs = 0;
    document.title = '[捡漏中] gotolibray';
    els.countdown.textContent = 'RUN';
    els.modeText.textContent = '高速捡漏';
    els.stateText.textContent = '监控中，请保持页面前台更稳';
    els.monitorPanel.classList.remove('is-success');
    els.monitorPanel.classList.add('is-running');
    await requestWakeLock();
    log('开始高速捡漏监控', 'success');
    scheduleNextPoll('leak');
  } catch (error) {
    log(error.message, 'error');
    if (/Cookie|阅览室/.test(error.message)) switchTab('config');
  }
}

function stopPolling(writeLog = true) {
  clearTimeout(state.timer);
  if (state.worker) state.worker.postMessage({ type: 'stop' });
  state.abortController?.abort();
  state.abortController = null;
  state.running = false;
  state.mode = 'idle';
  state.backoffMs = 0;
  state.tomorrowRunAt = 0;
  state.tomorrowSeats = [];
  state.tomorrowDetailedLayoutSupported = null;
  state.tomorrowNoSeatLogAt = 0;
  document.title = 'gotolibray';
  els.countdown.textContent = 'READY';
  els.modeText.textContent = '已停止';
  els.stateText.textContent = '当前无运行任务';
  els.monitorPanel.classList.remove('is-running');
  releaseWakeLock();
  if (writeLog) log('已停止当前任务', 'warn');
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
  if (state.checkinBusy) {
    log('请等待到馆签到复核完成后再更新登录信息', 'warn');
    return;
  }
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
    if (state.checkinBusy) {
      log('请等待到馆签到复核完成后再保存配置', 'warn');
      return;
    }
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

  els.leakBtn.addEventListener('click', () => startPolling());
  els.tomorrowBtn.addEventListener('click', () => startTomorrowReservation());
  els.remoteCheckinBtn.addEventListener('click', () => remoteCheckin());
  els.inspectCheckinBtn.addEventListener('click', inspectCheckinChannels);
  els.submitArrivalCodeBtn.addEventListener('click', () => remoteCheckin({ useEmergencyCode: true }));
  els.checkinBtn.addEventListener('click', checkin);
  els.stopBtn.addEventListener('click', () => stopPolling());
  els.clearLogsBtn.addEventListener('click', () => {
    localStorage.removeItem(LOG_KEY);
    renderLogs();
  });
  els.testConfigBtn.addEventListener('click', testHealth);
  els.noticeList.addEventListener('click', async (event) => {
    const button = event.target.closest('.notice-copy-button');
    if (!button) return;
    try {
      await copyText(button.dataset.copy || '');
      button.textContent = '已复制';
      setTimeout(() => {
        button.textContent = '复制';
      }, 1200);
    } catch (error) {
      log(`公告复制失败：${error.message}`, 'error');
    }
  });
  els.logoutBtn.addEventListener('click', async () => {
    if (state.checkinBusy) {
      log('请等待到馆签到复核完成后再退出登录', 'warn');
      return;
    }
    stopPolling(false);
    await fetch('/api/auth/logout', { method: 'POST' });
    window.location.href = '/login.html';
  });
  els.exchangeCookieBtn.addEventListener('click', exchangeCookie);
  els.refreshRoomsBtn.addEventListener('click', () => {
    if (state.checkinBusy) {
      log('请等待到馆签到复核完成后再刷新阅览室', 'warn');
      return;
    }
    state.config = { ...state.config, ...collectForm() };
    saveConfig();
    refreshRooms();
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
    if (state.checkinBusy) {
      log('请等待到馆签到复核完成后再清除登录信息', 'warn');
      return;
    }
    stopPolling(false);
    state.success = false;
    state.config.cookie = '';
    state.config.authorization = '';
    state.config.lib_id = '';
    state.config.rooms = [];
    state.checkinSummary = '未检测';
    state.checkinAttempt = null;
    els.arrivalCodeInput.value = '';
    renderCheckinActionLinks();
    setCheckinRetryVisible(false);
    saveConfig();
    fillForm();
    updateSummary();
    log('已清除登录信息', 'warn');
  });
  els.resetCheckinAttemptBtn.addEventListener('click', () => {
    if (state.checkinBusy) {
      log('签到请求仍在等待接口确认，请稍候', 'warn');
      return;
    }
    if (state.checkinAttempt?.status !== 'unknown') {
      setCheckinRetryVisible(false);
      return;
    }
    state.checkinAttempt = null;
    state.checkinSummary = '待重新检测';
    setCheckinRetryVisible(false);
    updateSummary();
    els.countdown.textContent = 'READY';
    els.modeText.textContent = '已允许重新签到';
    els.stateText.textContent = '下次点击将重新检测并提交一次签到请求';
    log('已按用户确认解除同一预约的待确认锁定', 'warn');
  });
  els.closeSuccessBtn.addEventListener('click', () => els.successDialog.close());
  document.addEventListener('visibilitychange', restoreWakeLock);
}

function init() {
  loadCurrentUser();
  loadAnnouncements();
  loadConfig();
  fillForm();
  renderRooms();
  updateSummary();
  renderLogs();
  bindEvents();
  testHealth();
}

init();

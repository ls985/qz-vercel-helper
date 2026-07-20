const WebSocket = require('ws');

const TRACE_GRAPHQL_URL = 'https://wechat.v2.traceint.com/index.php/graphql/';
const TOMORROW_QUEUE_URL = 'wss://wechat.v2.traceint.com/ws?ns=prereserve/queue';
const DEFAULT_UA =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.49';
const TOMORROW_UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/107.0.0.0 Safari/537.36 NetType/WIFI MicroMessenger/7.0.20.1781(0x6700143B) WindowsWechat(0x63090719) XWEB/8391 Flue';
const QUEUE_PAYLOAD = JSON.stringify({ ns: 'prereserve/queue', msg: '' });

function setCors(req, res) {
  const allowed = (process.env.ALLOWED_ORIGINS || '*')
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
  const origin = req.headers.origin || '';
  const allowOrigin =
    allowed.includes('*') || !origin ? '*' : allowed.includes(origin) ? origin : allowed[0] || '*';

  res.setHeader('Access-Control-Allow-Origin', allowOrigin);
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
  res.setHeader(
    'Access-Control-Allow-Headers',
    'Content-Type,Authorization,X-Trace-Cookie,X-Trace-Authorization,X-Trace-User-Agent',
  );
  res.setHeader('Access-Control-Max-Age', '86400');
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    if (req.body) {
      resolve(typeof req.body === 'string' ? req.body : JSON.stringify(req.body));
      return;
    }

    let body = '';
    req.on('data', (chunk) => {
      body += chunk;
      if (body.length > 1024 * 1024) {
        reject(new Error('请求体过大'));
        req.destroy();
      }
    });
    req.on('end', () => resolve(body));
    req.on('error', reject);
  });
}

function pickHeader(req, name) {
  const value = req.headers[name.toLowerCase()];
  return Array.isArray(value) ? value[0] : value || '';
}

function classifyQueueMessage(rawMessage) {
  const raw = String(rawMessage || '');
  if (!raw.trim()) return null;

  let message = raw;
  try {
    const parsed = JSON.parse(raw);
    if (typeof parsed === 'string') message = parsed;
    else if (typeof parsed?.msg === 'string') message = parsed.msg;
  } catch {
    // 非 JSON 消息仍参与关键字判断。
  }

  const normalized = `${message}\n${raw}`.toLowerCase();
  const stopKeywords = ['不在', '未开始', '结束', '已闭馆', '登记了', '已登记'];
  const continueKeywords = ['ok', '排队成功', 'u6392', '您已经预定了座位', 'u6210', '不需要排队'];
  if (stopKeywords.some((keyword) => normalized.includes(keyword.toLowerCase()))) {
    return { shouldStop: true, message };
  }
  if (continueKeywords.some((keyword) => normalized.includes(keyword.toLowerCase()))) {
    return { shouldStop: false, message: `明日预约排队通道返回：${message}` };
  }
  return null;
}

function enterTomorrowReservationQueue(cookie) {
  return new Promise((resolve) => {
    let settled = false;
    let sendTimer = null;
    let timeoutTimer = null;
    const socket = new WebSocket(TOMORROW_QUEUE_URL, {
      headers: {
        Cookie: cookie,
        Origin: 'https://web.traceint.com',
        'User-Agent': TOMORROW_UA,
      },
    });

    const finish = (result, settleDelay = 0) => {
      if (settled) return;
      settled = true;
      clearInterval(sendTimer);
      clearTimeout(timeoutTimer);
      setTimeout(() => {
        try {
          socket.close();
        } catch {
          // 关闭失败不影响排队结果。
        }
        resolve(result);
      }, settleDelay);
    };

    const sendQueueSignal = () => {
      if (socket.readyState === WebSocket.OPEN) socket.send(QUEUE_PAYLOAD);
    };

    socket.on('open', () => {
      sendQueueSignal();
      // 排队通道不需要高频轰炸；降低频率可显著减少触发上游风控的概率。
      sendTimer = setInterval(sendQueueSignal, 1000);
    });
    socket.on('message', (data) => {
      const result = classifyQueueMessage(data.toString());
      if (result) finish(result, result.shouldStop ? 0 : 500);
    });
    socket.on('error', (error) => {
      finish({ shouldStop: false, message: `明日预约排队通道连接异常，继续预约：${error.message}` });
    });
    socket.on('close', () => {
      finish({ shouldStop: false, message: '明日预约排队通道已关闭，继续预约' });
    });
    timeoutTimer = setTimeout(
      () => finish({ shouldStop: false, message: '明日预约排队通道 8 秒内未明确拦截，继续预约' }),
      8000,
    );
  });
}

module.exports = async function handler(req, res) {
  setCors(req, res);

  if (req.method === 'OPTIONS') {
    res.statusCode = 204;
    res.end();
    return;
  }

  if (req.method === 'GET' && req.query?.type === 'health') {
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.end(JSON.stringify({ status: 'ok', time: new Date().toISOString() }));
    return;
  }

  if (req.method !== 'POST') {
    res.statusCode = 405;
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.end(JSON.stringify({ error: 'method_not_allowed' }));
    return;
  }

  try {
    const traceCookie = pickHeader(req, 'x-trace-cookie');
    const traceAuthorization =
      pickHeader(req, 'x-trace-authorization') || pickHeader(req, 'authorization');
    const traceUa = pickHeader(req, 'x-trace-user-agent') || DEFAULT_UA;

    if (!traceCookie) {
      res.statusCode = 400;
      res.setHeader('Content-Type', 'application/json; charset=utf-8');
      res.end(JSON.stringify({ error: 'missing_cookie', message: '缺少 X-Trace-Cookie' }));
      return;
    }

    if (req.query?.type === 'tomorrow-queue') {
      const result = await enterTomorrowReservationQueue(traceCookie);
      res.statusCode = 200;
      res.setHeader('Content-Type', 'application/json; charset=utf-8');
      res.setHeader('Cache-Control', 'no-store');
      res.end(JSON.stringify(result));
      return;
    }

    const rawBody = await readBody(req);

    const upstreamHeaders = {
      Host: 'wechat.v2.traceint.com',
      Origin: 'https://web.traceint.com',
      Referer: 'https://web.traceint.com/',
      'User-Agent': traceUa,
      Cookie: traceCookie,
      'Content-Type': 'application/json',
      'App-Version': '2.2.5',
      'app-version': '2.2.5',
      Accept: 'application/json, text/plain, */*',
    };

    if (traceAuthorization) {
      upstreamHeaders.Authorization = traceAuthorization;
    }

    const upstream = await fetch(TRACE_GRAPHQL_URL, {
      method: 'POST',
      headers: upstreamHeaders,
      body: rawBody,
    });

    const text = await upstream.text();
    res.statusCode = upstream.status;
    res.setHeader('Content-Type', upstream.headers.get('content-type') || 'application/json; charset=utf-8');
    res.setHeader('Cache-Control', 'no-store');
    res.end(text);
  } catch (error) {
    res.statusCode = 502;
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.end(
      JSON.stringify({
        error: 'proxy_failed',
        message: error instanceof Error ? error.message : String(error),
      }),
    );
  }
};

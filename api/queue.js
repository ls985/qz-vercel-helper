const WebSocket = require('ws');

const TRACE_QUEUE_URL = 'wss://wechat.v2.traceint.com/ws?ns=prereserve/queue';
const DEFAULT_UA =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.49';
const QUEUE_TIMEOUT_MS = 4500;

function setCors(req, res) {
  const allowed = (process.env.ALLOWED_ORIGINS || '*')
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
  const origin = req.headers.origin || '';
  const allowOrigin =
    allowed.includes('*') || !origin ? '*' : allowed.includes(origin) ? origin : allowed[0] || '*';

  res.setHeader('Access-Control-Allow-Origin', allowOrigin);
  res.setHeader('Access-Control-Allow-Methods', 'POST,OPTIONS');
  res.setHeader(
    'Access-Control-Allow-Headers',
    'Content-Type,Authorization,X-Trace-Cookie,X-Trace-Authorization,X-Trace-User-Agent',
  );
  res.setHeader('Access-Control-Max-Age', '86400');
}

function pickHeader(req, name) {
  const value = req.headers[name.toLowerCase()];
  return Array.isArray(value) ? value[0] : value || '';
}

function decodeQueueMessage(raw) {
  const text = Buffer.isBuffer(raw) ? raw.toString('utf8') : String(raw || '');
  try {
    const data = JSON.parse(text);
    return {
      raw: text,
      message: typeof data.msg === 'string' ? data.msg : text,
    };
  } catch {
    return { raw: text, message: text };
  }
}

function isQueueReady(message) {
  return /排|成功|预约|ok|true/i.test(message);
}

function passQueue({ cookie, authorization, ua }) {
  return new Promise((resolve, reject) => {
    const messages = [];
    let settled = false;
    let interval = null;

    const finish = (fn, value) => {
      if (settled) return;
      settled = true;
      clearInterval(interval);
      ws.close();
      fn(value);
    };

    const ws = new WebSocket(TRACE_QUEUE_URL, {
      headers: {
        Host: 'wechat.v2.traceint.com',
        Origin: 'https://web.traceint.com',
        Referer: 'https://web.traceint.com/web/index.html',
        'User-Agent': ua || DEFAULT_UA,
        Cookie: cookie,
        'App-Version': '2.2.5',
        'app-version': '2.2.5',
        Accept: '*/*',
        ...(authorization ? { Authorization: authorization } : {}),
      },
      handshakeTimeout: QUEUE_TIMEOUT_MS,
    });

    const timeout = setTimeout(() => {
      finish(reject, new Error(messages.length ? `排队超时：${messages.at(-1).message}` : '排队超时'));
    }, QUEUE_TIMEOUT_MS);

    ws.on('open', () => {
      const sendHeartbeat = () => {
        if (ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({ ns: 'prereserve/queue', msg: '' }));
        }
      };
      sendHeartbeat();
      interval = setInterval(sendHeartbeat, 80);
    });

    ws.on('message', (raw) => {
      const parsed = decodeQueueMessage(raw);
      messages.push(parsed);
      if (isQueueReady(parsed.message) || isQueueReady(parsed.raw)) {
        clearTimeout(timeout);
        finish(resolve, {
          ok: true,
          message: parsed.message,
          messages: messages.slice(-5),
        });
      }
    });

    ws.on('error', (error) => {
      clearTimeout(timeout);
      finish(reject, error);
    });

    ws.on('close', () => {
      clearTimeout(timeout);
      if (!settled) {
        finish(reject, new Error(messages.length ? `排队连接关闭：${messages.at(-1).message}` : '排队连接关闭'));
      }
    });
  });
}

module.exports = async function handler(req, res) {
  setCors(req, res);

  if (req.method === 'OPTIONS') {
    res.statusCode = 204;
    res.end();
    return;
  }

  if (req.method !== 'POST') {
    res.statusCode = 405;
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.end(JSON.stringify({ error: 'method_not_allowed' }));
    return;
  }

  try {
    const cookie = pickHeader(req, 'x-trace-cookie');
    const authorization = pickHeader(req, 'x-trace-authorization') || pickHeader(req, 'authorization');
    const ua = pickHeader(req, 'x-trace-user-agent') || DEFAULT_UA;

    if (!cookie) {
      res.statusCode = 400;
      res.setHeader('Content-Type', 'application/json; charset=utf-8');
      res.end(JSON.stringify({ error: 'missing_cookie', message: '缺少 X-Trace-Cookie' }));
      return;
    }

    const result = await passQueue({ cookie, authorization, ua });
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.setHeader('Cache-Control', 'no-store');
    res.end(JSON.stringify(result));
  } catch (error) {
    res.statusCode = 502;
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.end(
      JSON.stringify({
        error: 'queue_failed',
        message: error instanceof Error ? error.message : String(error),
      }),
    );
  }
};

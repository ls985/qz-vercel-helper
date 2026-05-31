const TRACE_GRAPHQL_URL = 'https://wechat.v2.traceint.com/index.php/graphql/';
const DEFAULT_UA =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.49';

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
    const rawBody = await readBody(req);
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

    const upstream = await fetch(TRACE_GRAPHQL_URL, {
      method: 'POST',
      headers: {
        Host: 'wechat.v2.traceint.com',
        Origin: 'https://web.traceint.com',
        Referer: 'https://web.traceint.com/web/index.html',
        'User-Agent': traceUa,
        Cookie: traceCookie,
        Authorization: traceAuthorization,
        'Content-Type': 'application/json',
        Accept: 'application/json, text/plain, */*',
      },
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

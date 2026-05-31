const https = require('https');

const MAX_REDIRECTS = 6;
const DEFAULT_UA =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.49';
const ALLOWED_HOSTS = new Set(['wechat.v2.traceint.com', 'web.traceint.com']);

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
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  res.setHeader('Access-Control-Max-Age', '86400');
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    if (req.body) {
      if (typeof req.body === 'string') {
        try {
          resolve(JSON.parse(req.body));
        } catch {
          reject(new Error('JSON 格式错误'));
        }
        return;
      }
      resolve(req.body);
      return;
    }

    let body = '';
    req.on('data', (chunk) => {
      body += chunk;
      if (body.length > 32 * 1024) {
        reject(new Error('请求体过大'));
        req.destroy();
      }
    });
    req.on('end', () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch {
        reject(new Error('JSON 格式错误'));
      }
    });
    req.on('error', reject);
  });
}

function parseCookie(setCookie) {
  return setCookie
    .map((item) => item.split(';')[0])
    .filter(Boolean)
    .join('; ');
}

function isAllowedUrl(url) {
  return url.protocol === 'https:' && ALLOWED_HOSTS.has(url.hostname);
}

function requestOnce(url, cookieJar) {
  return new Promise((resolve, reject) => {
    const req = https.request(
      url,
      {
        method: 'GET',
        headers: {
          Host: url.hostname,
          'User-Agent': DEFAULT_UA,
          Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          Cookie: parseCookie(cookieJar),
          Referer: 'https://web.traceint.com/web/index.html',
        },
      },
      (response) => {
        response.resume();
        const setCookie = response.headers['set-cookie'] || [];
        const location = response.headers.location || '';
        resolve({
          statusCode: response.statusCode || 0,
          setCookie,
          location,
        });
      },
    );

    req.setTimeout(10000, () => req.destroy(new Error('上游请求超时')));
    req.on('error', reject);
    req.end();
  });
}

async function follow(url, cookieJar, redirectsLeft) {
  if (!isAllowedUrl(url)) {
    throw new Error('仅允许 traceint.com 的授权链接');
  }

  const result = await requestOnce(url, cookieJar);
  for (const item of result.setCookie) {
    const key = item.split('=')[0];
    const index = cookieJar.findIndex((oldItem) => oldItem.startsWith(`${key}=`));
    if (index >= 0) cookieJar[index] = item;
    else cookieJar.push(item);
  }

  if ([301, 302, 303, 307, 308].includes(result.statusCode) && result.location && redirectsLeft > 0) {
    const next = new URL(result.location, url);
    return follow(next, cookieJar, redirectsLeft - 1);
  }

  return result;
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
    const body = await readJson(req);
    const authUrl = new URL(String(body.url || ''));
    const cookieJar = [];
    const finalResult = await follow(authUrl, cookieJar, MAX_REDIRECTS);
    const cookie = parseCookie(cookieJar);

    if (!cookie) {
      res.statusCode = 422;
      res.setHeader('Content-Type', 'application/json; charset=utf-8');
      res.end(JSON.stringify({ error: 'no_cookie', message: '授权链接没有返回 Cookie' }));
      return;
    }

    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.setHeader('Cache-Control', 'no-store');
    res.end(
      JSON.stringify({
        cookie,
        statusCode: finalResult.statusCode,
      }),
    );
  } catch (error) {
    res.statusCode = 400;
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.end(
      JSON.stringify({
        error: 'session_failed',
        message: error instanceof Error ? error.message : String(error),
      }),
    );
  }
};

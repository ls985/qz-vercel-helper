const https = require('https');

const MAX_REDIRECTS = 6;
const DEFAULT_UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/107.0.0.0 Safari/537.36 NetType/WIFI MicroMessenger/7.0.20.1781 WindowsWechat XWEB/8391';
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

function mergeCookies(cookieJar, setCookie) {
  for (const item of setCookie) {
    const cookie = item.split(';')[0].trim();
    if (!cookie) continue;
    const key = cookie.split('=')[0];
    const index = cookieJar.findIndex((oldItem) => oldItem.startsWith(`${key}=`));
    if (index >= 0) cookieJar[index] = cookie;
    else cookieJar.push(cookie);
  }
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
  mergeCookies(cookieJar, result.setCookie);

  if ([301, 302, 303, 307, 308].includes(result.statusCode) && result.location && redirectsLeft > 0) {
    const next = new URL(result.location, url);
    return follow(next, cookieJar, redirectsLeft - 1);
  }

  return result;
}

function buildAuthUrlFromCallback(callbackUrl) {
  const cleanUrl = String(callbackUrl || '').replace(/\\/g, '');
  const url = new URL(cleanUrl);
  const code = url.searchParams.get('code');

  if (!code) return url;
  if (!ALLOWED_HOSTS.has(url.hostname)) {
    throw new Error('仅允许 traceint.com 的微信回调链接');
  }

  const target = `https://${url.hostname}`;
  const params = new URLSearchParams({
    r: `${target}/web/index.html`,
    code,
    state: url.searchParams.get('state') || '1',
  });

  return new URL(`${target}/index.php/urlNew/auth.html?${params.toString()}`);
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
    const authUrl = buildAuthUrlFromCallback(body.url);
    const cookieJar = [];
    const baseUrl = new URL(`${authUrl.protocol}//${authUrl.hostname}/`);
    await follow(baseUrl, cookieJar, 0);
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

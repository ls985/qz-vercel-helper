const fs = require('fs');
const http = require('http');
const path = require('path');

const proxyHandler = require('./api/proxy');
const sessionHandler = require('./api/session');
const auth = require('./lib/auth-store');

const PORT = Number(process.env.PORT || 3000);
const PUBLIC_DIR = path.join(__dirname, 'public');
const COOKIE_NAME = 'qz_session';
const ALLOWED_ORIGINS = new Set(
  (process.env.ALLOWED_ORIGINS || 'https://igotolib.duckdns.org,http://igotolib.duckdns.org')
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean),
);

const CONTENT_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
};

function parseCookies(req) {
  return String(req.headers.cookie || '')
    .split(';')
    .map((part) => part.trim())
    .filter(Boolean)
    .reduce((cookies, part) => {
      const index = part.indexOf('=');
      if (index > 0) cookies[part.slice(0, index)] = decodeURIComponent(part.slice(index + 1));
      return cookies;
    }, {});
}

function getUser(req) {
  const token = parseCookies(req)[COOKIE_NAME];
  return auth.getSessionUser(auth.readStore(), token);
}

function isSecureRequest(req) {
  return req.socket.encrypted || String(req.headers['x-forwarded-proto'] || '').split(',')[0] === 'https';
}

function sessionCookie(token, req, maxAge) {
  const parts = [
    `${COOKIE_NAME}=${encodeURIComponent(token || '')}`,
    'Path=/',
    'HttpOnly',
    'SameSite=Lax',
    `Max-Age=${maxAge}`,
  ];
  if (isSecureRequest(req)) parts.push('Secure');
  return parts.join('; ');
}

function sendJson(res, status, payload, headers = {}) {
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    ...headers,
  });
  res.end(JSON.stringify(payload));
}

function rejectBadOrigin(req, res) {
  if (!['POST', 'PUT', 'PATCH', 'DELETE'].includes(req.method)) return false;
  const origin = req.headers.origin;
  if (!origin || ALLOWED_ORIGINS.has(origin)) return false;
  sendJson(res, 403, { error: 'bad_origin' });
  return true;
}

function readJson(req, maxBytes = 64 * 1024) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', (chunk) => {
      body += chunk;
      if (body.length > maxBytes) {
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

function redirect(res, location) {
  res.writeHead(302, {
    Location: location,
    'Cache-Control': 'no-store',
  });
  res.end();
}

function serveFile(res, filePath) {
  fs.stat(filePath, (statError, stat) => {
    if (statError || !stat.isFile()) {
      sendJson(res, 404, { error: 'not_found' });
      return;
    }

    const ext = path.extname(filePath).toLowerCase();
    res.writeHead(200, {
      'Content-Type': CONTENT_TYPES[ext] || 'application/octet-stream',
      'Cache-Control': 'no-store',
    });
    fs.createReadStream(filePath).pipe(res);
  });
}

function publicPathFromUrl(urlPath) {
  const normalized = decodeURIComponent(urlPath).replace(/\\/g, '/');
  const relative = normalized === '/' ? 'index.html' : normalized.replace(/^\/+/, '');
  const resolved = path.resolve(PUBLIC_DIR, relative);
  if (!resolved.startsWith(PUBLIC_DIR)) return null;
  return resolved;
}

function enhanceApiRequest(req, url) {
  req.query = Object.fromEntries(url.searchParams.entries());
}

function requireUser(req, res, options = {}) {
  const user = getUser(req);
  if (!user) {
    if (req.url.startsWith('/api/')) sendJson(res, 401, { error: 'unauthorized' });
    else redirect(res, '/login.html');
    return null;
  }
  if (options.admin && user.role !== 'admin') {
    sendJson(res, 403, { error: 'forbidden' });
    return null;
  }
  return user;
}

async function handleAuth(req, res, url) {
  try {
    if (req.method === 'GET' && url.pathname === '/api/auth/me') {
      const user = getUser(req);
      sendJson(res, 200, { user: auth.publicUser(user) });
      return true;
    }

    if (req.method === 'POST' && url.pathname === '/api/auth/login') {
      const body = await readJson(req);
      const result = auth.authenticate(body.username, body.password, req);
      if (!result.ok) {
        sendJson(res, 401, { error: 'invalid_credentials', message: '用户名或密码错误' });
        return true;
      }

      const maxAge = Math.max(1, Number(process.env.AUTH_SESSION_DAYS || 7)) * 24 * 60 * 60;
      sendJson(res, 200, { user: result.user }, { 'Set-Cookie': sessionCookie(result.session.token, req, maxAge) });
      return true;
    }

    if (req.method === 'POST' && url.pathname === '/api/auth/register') {
      const body = await readJson(req);
      const user = auth.registerUser(body, req);
      sendJson(res, 201, {
        user,
        message: '注册成功',
      });
      return true;
    }

    if (req.method === 'POST' && url.pathname === '/api/auth/logout') {
      const user = getUser(req);
      const token = parseCookies(req)[COOKIE_NAME];
      if (user) auth.addActivity(auth.readStore(), user, 'logout', {}, req);
      auth.removeSession(auth.readStore(), token);
      sendJson(res, 200, { ok: true }, { 'Set-Cookie': sessionCookie('', req, 0) });
      return true;
    }

    if (req.method === 'POST' && url.pathname === '/api/auth/checkin') {
      const user = requireUser(req, res);
      if (!user) return true;
      sendJson(res, 200, auth.checkin(user.id, req));
      return true;
    }

    if (req.method === 'POST' && url.pathname === '/api/auth/consume') {
      const user = requireUser(req, res);
      if (!user) return true;
      sendJson(res, 200, { user: auth.consumeHair(user.id, 1, user, req) });
      return true;
    }
  } catch (error) {
    sendJson(res, 400, { error: 'auth_failed', message: error.message });
    return true;
  }

  return false;
}

async function handleAdmin(req, res, url) {
  const user = requireUser(req, res, { admin: true });
  if (!user) return true;

  try {
    if (req.method === 'GET' && url.pathname === '/api/admin/users') {
      sendJson(res, 200, { users: auth.listUsers() });
      return true;
    }

    if (req.method === 'POST' && url.pathname === '/api/admin/users') {
      const body = await readJson(req);
      sendJson(res, 201, { user: auth.createUser(body, user, req) });
      return true;
    }

    const userMatch = url.pathname.match(/^\/api\/admin\/users\/([^/]+)$/);
    if (req.method === 'PATCH' && userMatch) {
      const body = await readJson(req);
      sendJson(res, 200, { user: auth.updateUser(userMatch[1], body, user, req) });
      return true;
    }

    if (req.method === 'GET' && url.pathname === '/api/admin/activity') {
      sendJson(res, 200, { activity: auth.listActivity(url.searchParams.get('limit') || 200) });
      return true;
    }

    const grantMatch = url.pathname.match(/^\/api\/admin\/users\/([^/]+)\/hair$/);
    if (req.method === 'POST' && grantMatch) {
      const body = await readJson(req);
      sendJson(res, 200, { user: auth.grantHair(grantMatch[1], body.amount, user, req) });
      return true;
    }

    if (req.method === 'POST' && url.pathname === '/api/admin/announcements') {
      const body = await readJson(req);
      sendJson(res, 201, { announcement: auth.createAnnouncement(body, user, req) });
      return true;
    }
  } catch (error) {
    sendJson(res, 400, { error: 'admin_failed', message: error.message });
    return true;
  }

  sendJson(res, 404, { error: 'not_found' });
  return true;
}

function handleApi(req, res, url) {
  enhanceApiRequest(req, url);

  if (url.pathname === '/api/proxy' && req.method === 'GET' && url.searchParams.get('type') === 'health') {
    return proxyHandler(req, res);
  }

  const user = requireUser(req, res);
  if (!user) return;

  if (url.pathname === '/api/announcements' && req.method === 'GET') {
    sendJson(res, 200, { announcements: auth.listAnnouncements() });
    return;
  }

  if (url.pathname === '/api/proxy') {
    auth.addActivity(auth.readStore(), user, 'proxy_request', { method: req.method }, req);
    proxyHandler(req, res);
    return;
  }

  sendJson(res, 404, { error: 'not_found' });
}

function handleStatic(req, res, url) {
  const publicFiles = new Set(['/login.html', '/register.html', '/auth.js', '/register.js', '/style.css']);
  if (publicFiles.has(url.pathname)) {
    serveFile(res, publicPathFromUrl(url.pathname));
    return;
  }

  if (url.pathname === '/' && !getUser(req)) {
    redirect(res, '/login.html');
    return;
  }

  const user = requireUser(req, res, { admin: url.pathname === '/admin.html' });
  if (!user) return;

  const filePath = publicPathFromUrl(url.pathname);
  if (!filePath) {
    sendJson(res, 400, { error: 'bad_path' });
    return;
  }
  serveFile(res, filePath);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  if (rejectBadOrigin(req, res)) return;

  if (url.pathname.startsWith('/api/auth/')) {
    if (await handleAuth(req, res, url)) return;
  }

  if (url.pathname === '/api/session') {
    sessionHandler(req, res);
    return;
  }

  if (url.pathname.startsWith('/api/admin/')) {
    await handleAdmin(req, res, url);
    return;
  }

  if (url.pathname.startsWith('/api/')) {
    handleApi(req, res, url);
    return;
  }

  handleStatic(req, res, url);
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`qz-vercel-helper listening on http://127.0.0.1:${PORT}`);
});

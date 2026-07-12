const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const DATA_DIR = process.env.AUTH_DATA_DIR || path.join(process.cwd(), '.data');
const STORE_FILE = process.env.AUTH_STORE_FILE || path.join(DATA_DIR, 'auth-store.json');
const SESSION_DAYS = Math.max(1, Number(process.env.AUTH_SESSION_DAYS || 7));
const ACTIVITY_LIMIT = Math.max(100, Number(process.env.AUTH_ACTIVITY_LIMIT || 2000));
const PEPPER = process.env.AUTH_SECRET || 'change-me-in-production';

function now() {
  return new Date().toISOString();
}

function ensureDataDir() {
  fs.mkdirSync(path.dirname(STORE_FILE), { recursive: true });
}

function defaultStore() {
  return {
    users: [],
    sessions: [],
    activity: [],
    announcements: [],
  };
}

function readStore() {
  ensureDataDir();
  if (!fs.existsSync(STORE_FILE)) {
    const store = defaultStore();
    writeStore(store);
    return bootstrapAdmin(store);
  }

  try {
    const store = JSON.parse(fs.readFileSync(STORE_FILE, 'utf8'));
    return bootstrapAdmin({
      users: Array.isArray(store.users) ? store.users.map(normalizeUserRecord) : [],
      sessions: Array.isArray(store.sessions) ? store.sessions : [],
      activity: Array.isArray(store.activity) ? store.activity : [],
      announcements: Array.isArray(store.announcements) ? store.announcements : [],
    });
  } catch {
    const store = defaultStore();
    writeStore(store);
    return bootstrapAdmin(store);
  }
}

function normalizeUserRecord(user) {
  return {
    ...user,
    hair: Math.max(0, Number(user.hair || 0)),
    lastCheckinDate: user.lastCheckinDate || '',
  };
}

function writeStore(store) {
  ensureDataDir();
  const tempFile = `${STORE_FILE}.tmp`;
  fs.writeFileSync(tempFile, JSON.stringify(store, null, 2));
  fs.renameSync(tempFile, STORE_FILE);
}

function normalizeUsername(username) {
  return String(username || '').trim().toLowerCase();
}

function makeId(prefix) {
  return `${prefix}_${crypto.randomBytes(12).toString('hex')}`;
}

function hashPassword(password, salt = crypto.randomBytes(16).toString('hex')) {
  const hash = crypto.scryptSync(`${password}${PEPPER}`, salt, 64).toString('hex');
  return { salt, hash };
}

function verifyPassword(password, user) {
  const { hash } = hashPassword(password, user.salt);
  return crypto.timingSafeEqual(Buffer.from(hash, 'hex'), Buffer.from(user.passwordHash, 'hex'));
}

function publicUser(user) {
  if (!user) return null;
  return {
    id: user.id,
    username: user.username,
    email: user.email || '',
    role: user.role,
    status: user.status,
    createdAt: user.createdAt,
    updatedAt: user.updatedAt,
    lastLoginAt: user.lastLoginAt || '',
    loginCount: user.loginCount || 0,
    hair: roundHair(user.hair || 0),
    lastCheckinDate: user.lastCheckinDate || '',
  };
}

function roundHair(value) {
  return Math.max(0, Math.round(Number(value || 0) * 100) / 100);
}

function todayKey() {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Shanghai',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(new Date());
}

function findUserByUsername(store, username) {
  const normalized = normalizeUsername(username);
  return store.users.find((user) => normalizeUsername(user.username) === normalized);
}

function bootstrapAdmin(store) {
  const hasAdmin = store.users.some((user) => user.role === 'admin');
  const username = normalizeUsername(process.env.ADMIN_USERNAME || process.env.ADMIN_EMAIL || '');
  const password = process.env.ADMIN_PASSWORD || '';
  if (hasAdmin || !username || !password) return store;

  const { salt, hash } = hashPassword(password);
  store.users.push({
    id: makeId('usr'),
    username,
    email: process.env.ADMIN_EMAIL || username,
    passwordHash: hash,
    salt,
    role: 'admin',
    status: 'active',
    createdAt: now(),
    updatedAt: now(),
    lastLoginAt: '',
    loginCount: 0,
    hair: 0,
    lastCheckinDate: '',
    createdBy: 'env',
  });
  addActivity(store, null, 'admin_bootstrap', { username }, {}, false);
  writeStore(store);
  return store;
}

function clientInfo(req) {
  const headers = req?.headers || {};
  return {
    ip: String(headers['x-forwarded-for'] || req?.socket?.remoteAddress || '').split(',')[0].trim(),
    userAgent: String(headers['user-agent'] || '').slice(0, 240),
  };
}

function addActivity(store, user, action, detail = {}, req, persist = true) {
  store.activity.unshift({
    id: makeId('act'),
    time: now(),
    userId: user?.id || '',
    username: user?.username || '',
    action,
    detail,
    ...clientInfo(req || { headers: {} }),
  });
  store.activity = store.activity.slice(0, ACTIVITY_LIMIT);
  if (persist) writeStore(store);
}

function createSession(store, user) {
  const token = crypto.randomBytes(32).toString('base64url');
  const tokenHash = crypto.createHash('sha256').update(`${token}${PEPPER}`).digest('hex');
  const expiresAt = new Date(Date.now() + SESSION_DAYS * 24 * 60 * 60 * 1000).toISOString();
  store.sessions.push({
    id: makeId('ses'),
    userId: user.id,
    tokenHash,
    createdAt: now(),
    expiresAt,
  });
  return { token, expiresAt };
}

function hashSessionToken(token) {
  return crypto.createHash('sha256').update(`${token}${PEPPER}`).digest('hex');
}

function getSessionUser(store, token) {
  if (!token) return null;
  const tokenHash = hashSessionToken(token);
  const current = Date.now();
  const session = store.sessions.find((item) => item.tokenHash === tokenHash);
  if (!session || new Date(session.expiresAt).getTime() <= current) return null;
  const user = store.users.find((item) => item.id === session.userId);
  if (!user || user.status !== 'active') return null;
  return user;
}

function removeSession(store, token) {
  if (!token) return;
  const tokenHash = hashSessionToken(token);
  store.sessions = store.sessions.filter((item) => item.tokenHash !== tokenHash);
  writeStore(store);
}

function pruneSessions(store) {
  const current = Date.now();
  const before = store.sessions.length;
  store.sessions = store.sessions.filter((item) => new Date(item.expiresAt).getTime() > current);
  if (store.sessions.length !== before) writeStore(store);
}

function authenticate(username, password, req) {
  const store = readStore();
  pruneSessions(store);
  const user = findUserByUsername(store, username);
  if (!user || user.status !== 'active' || !verifyPassword(password || '', user)) {
    addActivity(store, user || { username: normalizeUsername(username) }, 'login_failed', {}, req);
    return { ok: false };
  }

  const session = createSession(store, user);
  user.lastLoginAt = now();
  user.loginCount = Number(user.loginCount || 0) + 1;
  user.updatedAt = now();
  addActivity(store, user, 'login_success', {}, req, false);
  writeStore(store);
  return { ok: true, user: publicUser(user), session };
}

function createUser(input, actor, req) {
  const username = normalizeUsername(input.username);
  const password = String(input.password || '');
  const role = input.role === 'admin' ? 'admin' : 'user';
  if (!username || username.length < 3) throw new Error('用户名至少 3 个字符');
  if (password.length < 8) throw new Error('密码至少 8 个字符');

  const store = readStore();
  if (findUserByUsername(store, username)) throw new Error('用户名已存在');
  const { salt, hash } = hashPassword(password);
  const user = {
    id: makeId('usr'),
    username,
    email: String(input.email || '').trim(),
    passwordHash: hash,
    salt,
    role,
    status: input.status === 'disabled' ? 'disabled' : 'active',
    createdAt: now(),
    updatedAt: now(),
    lastLoginAt: '',
    loginCount: 0,
    hair: 0,
    lastCheckinDate: '',
    createdBy: actor.id,
  };
  store.users.push(user);
  addActivity(store, actor, 'user_create', { username: user.username, role: user.role }, req, false);
  writeStore(store);
  return publicUser(user);
}

function registerUser(input, req) {
  const username = normalizeUsername(input.username);
  const password = String(input.password || '');
  if (!username || username.length < 3) throw new Error('用户名至少 3 个字符');
  if (password.length < 8) throw new Error('密码至少 8 个字符');

  const store = readStore();
  if (findUserByUsername(store, username)) throw new Error('用户名已存在');
  const { salt, hash } = hashPassword(password);
  const user = {
    id: makeId('usr'),
    username,
    email: '',
    passwordHash: hash,
    salt,
    role: 'user',
    status: 'active',
    createdAt: now(),
    updatedAt: now(),
    lastLoginAt: '',
    loginCount: 0,
    hair: 0,
    lastCheckinDate: '',
    createdBy: 'self',
  };
  store.users.push(user);
  addActivity(store, user, 'user_register', { username: user.username }, req, false);
  writeStore(store);
  return publicUser(user);
}

function updateUser(userId, input, actor, req) {
  const store = readStore();
  const user = store.users.find((item) => item.id === userId);
  if (!user) throw new Error('用户不存在');

  if (input.role === 'admin' || input.role === 'user') user.role = input.role;
  if (input.status === 'active' || input.status === 'disabled') user.status = input.status;
  if (typeof input.email === 'string') user.email = input.email.trim();
  if (input.password) {
    if (String(input.password).length < 8) throw new Error('密码至少 8 个字符');
    const { salt, hash } = hashPassword(String(input.password));
    user.salt = salt;
    user.passwordHash = hash;
    store.sessions = store.sessions.filter((session) => session.userId !== user.id);
  }
  user.updatedAt = now();
  addActivity(store, actor, 'user_update', { username: user.username, role: user.role, status: user.status }, req, false);
  writeStore(store);
  return publicUser(user);
}

function listUsers() {
  const store = readStore();
  return store.users.map(publicUser).sort((a, b) => a.username.localeCompare(b.username));
}

function listActivity(limit = 200) {
  const store = readStore();
  return store.activity.slice(0, Math.min(500, Math.max(1, Number(limit) || 200)));
}

function grantHair(userId, amount, actor, req) {
  const value = roundHair(amount);
  if (value <= 0) throw new Error('发放头发必须大于 0');
  const store = readStore();
  const user = store.users.find((item) => item.id === userId);
  if (!user) throw new Error('用户不存在');
  user.hair = roundHair(Number(user.hair || 0) + value);
  user.updatedAt = now();
  addActivity(store, actor, 'hair_grant', { username: user.username, amount: value }, req, false);
  writeStore(store);
  return publicUser(user);
}

function consumeHair(userId, amount, actor, req) {
  const value = roundHair(amount || 1);
  if (value <= 0) throw new Error('消耗头发必须大于 0');
  const store = readStore();
  const user = store.users.find((item) => item.id === userId);
  if (!user) throw new Error('用户不存在');
  if (Number(user.hair || 0) < value) throw new Error('头发不足，请先签到或联系管理员发放');
  user.hair = roundHair(Number(user.hair || 0) - value);
  user.updatedAt = now();
  addActivity(store, actor || user, 'hair_consume', { amount: value }, req, false);
  writeStore(store);
  return publicUser(user);
}

function checkin(userId, req) {
  const store = readStore();
  const user = store.users.find((item) => item.id === userId);
  if (!user) throw new Error('用户不存在');
  const today = todayKey();
  if (user.lastCheckinDate === today) throw new Error('今天已经签到过了');

  const amount = roundHair(Math.max(0.01, Math.ceil(Math.random() * 100) / 100));
  user.hair = roundHair(Number(user.hair || 0) + amount);
  user.lastCheckinDate = today;
  user.updatedAt = now();
  addActivity(store, user, 'hair_checkin', { amount }, req, false);
  writeStore(store);
  return { user: publicUser(user), amount };
}

function listAnnouncements() {
  const store = readStore();
  return store.announcements
    .filter((item) => item.status !== 'hidden')
    .slice(0, 5)
    .map((item) => ({
      id: item.id,
      title: item.title,
      content: item.content,
      createdAt: item.createdAt,
      createdBy: item.createdBy,
    }));
}

function createAnnouncement(input, actor, req) {
  const title = String(input.title || '').trim();
  const content = String(input.content || '').trim();
  if (!title) throw new Error('公告标题不能为空');
  if (!content) throw new Error('公告内容不能为空');

  const store = readStore();
  const announcement = {
    id: makeId('ann'),
    title: title.slice(0, 80),
    content: content.slice(0, 500),
    status: 'active',
    createdAt: now(),
    createdBy: actor.username,
  };
  store.announcements.unshift(announcement);
  store.announcements = store.announcements.slice(0, 20);
  addActivity(store, actor, 'announcement_create', { title: announcement.title }, req, false);
  writeStore(store);
  return announcement;
}

module.exports = {
  authenticate,
  checkin,
  createUser,
  createAnnouncement,
  consumeHair,
  getSessionUser,
  grantHair,
  listActivity,
  listAnnouncements,
  listUsers,
  publicUser,
  readStore,
  registerUser,
  removeSession,
  updateUser,
  addActivity,
};

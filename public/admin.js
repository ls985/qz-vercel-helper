const usersBody = document.getElementById('usersBody');
const activityList = document.getElementById('activityList');
const createUserForm = document.getElementById('createUserForm');
const announcementForm = document.getElementById('announcementForm');
const adminMessage = document.getElementById('adminMessage');
const logoutBtn = document.getElementById('logoutBtn');
const refreshUsersBtn = document.getElementById('refreshUsersBtn');
const refreshActivityBtn = document.getElementById('refreshActivityBtn');
const actionDialog = document.getElementById('actionDialog');
const actionTitle = document.getElementById('actionTitle');
const actionEyebrow = document.getElementById('actionEyebrow');
const actionDescription = document.getElementById('actionDescription');
const actionInputLabel = document.getElementById('actionInputLabel');
const actionInput = document.getElementById('actionInput');
const actionSubmit = document.getElementById('actionSubmit');

const stats = {
  users: document.getElementById('statUsers'),
  active: document.getElementById('statActive'),
  hair: document.getElementById('statHair'),
  today: document.getElementById('statToday'),
};

const inputs = {
  username: document.getElementById('newUsernameInput'),
  password: document.getElementById('newPasswordInput'),
  role: document.getElementById('newRoleInput'),
  announcementTitle: document.getElementById('announcementTitleInput'),
  announcementContent: document.getElementById('announcementContentInput'),
};

const activityLabels = {
  admin_bootstrap: '系统初始化',
  login_success: '登录成功',
  login_failed: '登录失败',
  logout: '退出登录',
  user_register: '用户注册',
  user_create: '创建用户',
  user_update: '更新用户',
  hair_grant: '发放头发',
  hair_checkin: '签到领头发',
  hair_consume: '消耗头发',
  announcement_create: '发布公告',
  proxy_request: '运行抢座任务',
  session_exchange: '更新图书馆登录',
};

let pendingAction = null;

function escapeHtml(value) {
  return String(value || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function formatTime(value) {
  if (!value) return '-';
  return new Date(value).toLocaleString('zh-CN', {
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  });
}

function formatHair(value) {
  return Number(value || 0).toFixed(2).replace(/\.?0+$/, '');
}

function todayKey(value = new Date()) {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Shanghai',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(value);
}

function setAdminMessage(message, type = 'info') {
  adminMessage.textContent = message;
  adminMessage.className = `auth-message ${type}`;
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    ...options,
    headers: { 'Content-Type': 'application/json', ...(options.headers || {}) },
  });
  const data = await response.json();
  if (response.status === 401) window.location.href = '/login.html';
  if (!response.ok) throw new Error(data.message || data.error || `HTTP ${response.status}`);
  return data;
}

async function loadUsers() {
  const data = await api('/api/admin/users');
  const users = data.users || [];
  stats.users.textContent = users.length;
  stats.active.textContent = users.filter((user) => user.status === 'active').length;
  stats.hair.textContent = formatHair(users.reduce((total, user) => total + Number(user.hair || 0), 0));
  usersBody.innerHTML = users
    .map(
      (user, index) => `
        <tr class="row-in" style="animation-delay:${Math.min(index * 25, 180)}ms">
          <td><div class="user-name"><span class="user-avatar">${escapeHtml(user.username.slice(0, 1))}</span><strong>${escapeHtml(user.username)}</strong></div></td>
          <td>${escapeHtml(formatHair(user.hair))}</td>
          <td>
            <select aria-label="${escapeHtml(user.username)} 的角色" data-action="role" data-id="${escapeHtml(user.id)}">
              <option value="user" ${user.role === 'user' ? 'selected' : ''}>普通用户</option>
              <option value="admin" ${user.role === 'admin' ? 'selected' : ''}>管理员</option>
            </select>
          </td>
          <td>
            <select aria-label="${escapeHtml(user.username)} 的状态" data-action="status" data-id="${escapeHtml(user.id)}">
              <option value="active" ${user.status === 'active' ? 'selected' : ''}>启用</option>
              <option value="disabled" ${user.status === 'disabled' ? 'selected' : ''}>禁用</option>
            </select>
          </td>
          <td>${escapeHtml(formatTime(user.lastLoginAt))}</td>
          <td><div class="table-actions">
            <button class="grant-action" data-action="grant" data-id="${escapeHtml(user.id)}" data-username="${escapeHtml(user.username)}" type="button">发头发</button>
            <button data-action="reset" data-id="${escapeHtml(user.id)}" data-username="${escapeHtml(user.username)}" type="button">改密码</button>
          </div></td>
        </tr>
      `,
    )
    .join('');
}

async function loadActivity() {
  const data = await api('/api/admin/activity?limit=160');
  const activity = data.activity || [];
  stats.today.textContent = activity.filter(
    (item) => todayKey(new Date(item.time)) === todayKey() && ['hair_checkin', 'hair_consume'].includes(item.action),
  ).length;
  activityList.innerHTML = activity.length
    ? activity
        .map(
          (item, index) => `
            <li class="activity-item" style="animation-delay:${Math.min(index * 20, 160)}ms">
              <span class="activity-icon"></span>
              <div><strong>${escapeHtml(activityLabels[item.action] || '其他活动')}</strong><p>${escapeHtml(item.username || '系统')}</p></div>
              <time>${escapeHtml(formatTime(item.time))}</time>
            </li>
          `,
        )
        .join('')
    : '<li class="activity-item"><span class="activity-icon"></span><div><strong>暂无活动</strong><p>系统</p></div></li>';
}

function openActionDialog(type, id, username) {
  pendingAction = { type, id, username };
  actionInput.value = '';
  if (type === 'grant') {
    actionEyebrow.textContent = 'HAIR BALANCE';
    actionTitle.textContent = '发放头发';
    actionDescription.textContent = `向 ${username} 的账户增加头发。`;
    actionInputLabel.textContent = '发放数量';
    actionInput.type = 'number';
    actionInput.min = '0.01';
    actionInput.step = '0.01';
    actionInput.placeholder = '例如 5';
  } else {
    actionEyebrow.textContent = 'SECURITY';
    actionTitle.textContent = '修改密码';
    actionDescription.textContent = `为 ${username} 设置新的登录密码。`;
    actionInputLabel.textContent = '新密码';
    actionInput.type = 'password';
    actionInput.minLength = 8;
    actionInput.removeAttribute('min');
    actionInput.removeAttribute('step');
    actionInput.placeholder = '至少 8 个字符';
  }
  actionDialog.showModal();
  requestAnimationFrame(() => actionInput.focus());
}

async function submitAction() {
  if (!pendingAction || !actionInput.reportValidity()) return;
  actionSubmit.disabled = true;
  try {
    if (pendingAction.type === 'grant') {
      const amount = Number(actionInput.value);
      if (!(amount > 0)) throw new Error('发放数量必须大于 0');
      await api(`/api/admin/users/${encodeURIComponent(pendingAction.id)}/hair`, {
        method: 'POST',
        body: JSON.stringify({ amount }),
      });
      setAdminMessage(`已向 ${pendingAction.username} 发放 ${formatHair(amount)} 根头发`, 'success');
    } else {
      await api(`/api/admin/users/${encodeURIComponent(pendingAction.id)}`, {
        method: 'PATCH',
        body: JSON.stringify({ password: actionInput.value }),
      });
      setAdminMessage(`${pendingAction.username} 的密码已更新`, 'success');
    }
    actionDialog.close();
    await Promise.all([loadUsers(), loadActivity()]);
  } catch (error) {
    setAdminMessage(error.message, 'error');
  } finally {
    actionSubmit.disabled = false;
  }
}

usersBody.addEventListener('change', async (event) => {
  const select = event.target.closest('select[data-action]');
  if (!select) return;
  select.disabled = true;
  try {
    await api(`/api/admin/users/${encodeURIComponent(select.dataset.id)}`, {
      method: 'PATCH',
      body: JSON.stringify({ [select.dataset.action]: select.value }),
    });
    setAdminMessage('用户信息已更新', 'success');
    await Promise.all([loadUsers(), loadActivity()]);
  } catch (error) {
    setAdminMessage(error.message, 'error');
    await loadUsers();
  }
});

usersBody.addEventListener('click', (event) => {
  const button = event.target.closest('button[data-action]');
  if (!button) return;
  openActionDialog(button.dataset.action, button.dataset.id, button.dataset.username);
});

actionSubmit.addEventListener('click', submitAction);
actionInput.addEventListener('keydown', (event) => {
  if (event.key === 'Enter') {
    event.preventDefault();
    submitAction();
  }
});

announcementForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  const button = announcementForm.querySelector('button[type="submit"]');
  button.disabled = true;
  try {
    await api('/api/admin/announcements', {
      method: 'POST',
      body: JSON.stringify({ title: inputs.announcementTitle.value, content: inputs.announcementContent.value }),
    });
    announcementForm.reset();
    setAdminMessage('公告已发布', 'success');
    await loadActivity();
  } catch (error) {
    setAdminMessage(error.message, 'error');
  } finally {
    button.disabled = false;
  }
});

createUserForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  const button = createUserForm.querySelector('button[type="submit"]');
  button.disabled = true;
  try {
    await api('/api/admin/users', {
      method: 'POST',
      body: JSON.stringify({ username: inputs.username.value, password: inputs.password.value, role: inputs.role.value }),
    });
    createUserForm.reset();
    setAdminMessage('用户已创建', 'success');
    await Promise.all([loadUsers(), loadActivity()]);
  } catch (error) {
    setAdminMessage(error.message, 'error');
  } finally {
    button.disabled = false;
  }
});

logoutBtn.addEventListener('click', async () => {
  await fetch('/api/auth/logout', { method: 'POST' });
  window.location.href = '/login.html';
});

refreshUsersBtn.addEventListener('click', () => loadUsers().catch((error) => setAdminMessage(error.message, 'error')));
refreshActivityBtn.addEventListener('click', () => loadActivity().catch((error) => setAdminMessage(error.message, 'error')));

Promise.all([loadUsers(), loadActivity()]).catch((error) => setAdminMessage(error.message, 'error'));

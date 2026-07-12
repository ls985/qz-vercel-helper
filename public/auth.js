const loginForm = document.getElementById('loginForm');
const usernameInput = document.getElementById('usernameInput');
const passwordInput = document.getElementById('passwordInput');
const loginBtn = document.getElementById('loginBtn');
const messageBox = document.getElementById('messageBox');

function setMessage(message, type = 'info') {
  messageBox.textContent = message;
  messageBox.className = `auth-message ${type}`;
}

async function checkSession() {
  try {
    const response = await fetch('/api/auth/me');
    const data = await response.json();
    if (data.user) window.location.href = '/';
  } catch {
    setMessage('服务暂时不可用', 'error');
  }
}

loginForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  loginBtn.disabled = true;
  setMessage('登录中...');

  try {
    const response = await fetch('/api/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        username: usernameInput.value.trim(),
        password: passwordInput.value,
      }),
    });
    const data = await response.json();
    if (!response.ok) throw new Error(data.message || data.error || `HTTP ${response.status}`);
    window.location.href = '/';
  } catch (error) {
    setMessage(error.message || '登录失败', 'error');
  } finally {
    loginBtn.disabled = false;
  }
});

checkSession();

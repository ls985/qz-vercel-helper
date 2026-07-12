const registerForm = document.getElementById('registerForm');
const usernameInput = document.getElementById('usernameInput');
const passwordInput = document.getElementById('passwordInput');
const confirmInput = document.getElementById('confirmInput');
const registerBtn = document.getElementById('registerBtn');
const messageBox = document.getElementById('messageBox');

function setMessage(message, type = 'info') {
  messageBox.textContent = message;
  messageBox.className = `auth-message ${type}`;
}

registerForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  if (passwordInput.value !== confirmInput.value) {
    setMessage('两次输入的密码不一致', 'error');
    return;
  }

  registerBtn.disabled = true;
  setMessage('提交中...');

  try {
    const response = await fetch('/api/auth/register', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        username: usernameInput.value.trim(),
        password: passwordInput.value,
      }),
    });
    const data = await response.json();
    if (!response.ok) throw new Error(data.message || data.error || `HTTP ${response.status}`);
    setMessage(data.message || '注册成功', 'success');

    const loginResponse = await fetch('/api/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        username: usernameInput.value.trim(),
        password: passwordInput.value,
      }),
    });
    if (!loginResponse.ok) {
      registerForm.reset();
      setMessage('注册成功，请返回登录', 'success');
      return;
    }
    window.location.href = '/';
  } catch (error) {
    setMessage(error.message || '注册失败', 'error');
  } finally {
    registerBtn.disabled = false;
  }
});

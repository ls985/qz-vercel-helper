# 我去图书馆抢座助手

一个适合部署到 Vercel 的轻量版抢座助手：Vercel 只做瞬时 API 转发，轮询逻辑跑在手机浏览器里。

## 功能

- 手机端深色控制面板，首页、配置、日志三页。
- 定时抢座：到开放时间前 5 秒开始轮询。
- 捡漏监控：按慢间隔持续检查空位。
- 手动抢一次：立即查询并尝试预约。
- 通过 `/api/proxy` 转发 GraphQL 请求，前端用 `X-Trace-Cookie` 传 Cookie，代理端再转成真实 `Cookie` 请求头。
- 可选 `/api/session`：粘贴我去图书馆授权链接，辅助换取 Cookie，服务器不保存。
- Wake Lock 屏幕常亮、随机抖动、失败退避、日志和 ntfy.sh 通知。

## 部署到 Vercel

1. 将本目录推送到 GitHub 仓库。
2. 在 Vercel 新建项目并导入仓库。
3. Framework Preset 选择 `Other`，保持默认即可。
4. 部署完成后，用手机浏览器打开 Vercel URL。
5. 到“配置”页填写 Cookie、阅览室 ID、开放时间并保存。

可选环境变量：

- `ALLOWED_ORIGINS`：限制允许访问 API 的前端来源，例如 `https://your-app.vercel.app`。不填默认 `*`。

## Cookie 获取建议

最稳的方式是只获取你自己账号的登录态：

1. 在微信里打开“我去图书馆”，进入网页端。
2. 复制授权跳转链接，常见形态类似：

   ```text
   https://wechat.v2.traceint.com/urlNew/auth.html?code=...&state=...
   ```

3. 在本工具“配置”页粘贴到“授权链接换 Cookie”，点“链接换 Cookie”。
4. 如果换取失败，就用浏览器开发者工具或抓包工具复制请求里的 Cookie，手动填入：

   ```text
   wechatSESS_ID=xxx; SERVERID=xxx
   ```

注意：浏览器不允许前端 JS 直接设置 `Cookie` 请求头，所以本项目使用 `X-Trace-Cookie` 发给自己的 Vercel 代理，再由代理请求上游。

## 使用建议

- 抢座前让手机页面保持前台打开，Wake Lock 只能在可见页面上尽量保持屏幕常亮，不能保证锁屏或后台继续执行。
- 轮询间隔不要设置过低。默认快速间隔是 0.8 秒，并带随机抖动；接口失败会自动退避。
- 如果接口返回验证码错误，需要在配置里填写验证码字段，或改造为人工确认流程。
- 成功后页面会弹窗、播放提示音，并可向 ntfy.sh 推送。

## 本地预览

静态页面可以直接打开 `public/index.html`。如果要测试 API，请使用 Vercel 本地环境：

```bash
npx vercel dev
```

然后访问 `http://localhost:3000`。

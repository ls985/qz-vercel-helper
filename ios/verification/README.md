# WechatSessionCodec 纯逻辑自检用例

`GoToLibrary/Core/WechatSessionCodec.swift` 的 `parse(_:)` 与
`mergeSetCookies(_:_)` 不依赖任何 iOS 框架，是纯字符串逻辑。这些用例在
Windows/macOS/Linux 上都能人工核对；Swift 实现与 Android 端
`WechatSessionCodec.java` 共用同一套 19 组用例。

`parse` 返回 `SessionRequest(baseURL:authURL:)`，下表 `base` 列是 `baseURL`，
`auth` 列是 `authURL`。

## parse 用例

| # | 输入 | 期望结果 |
|---|---|---|
| 1 | `https://wechat.v2.traceint.com/index.php/graphql/?code=abc123&state=1` | base=`https://wechat.v2.traceint.com/`，auth=`https://wechat.v2.traceint.com/index.php/urlNew/auth.html?r=https%3A%2F%2Fwechat.v2.traceint.com%2Fweb%2Findex.html&code=abc123&state=1` |
| 2 | `https://web.traceint.com/web/index.html?code=X%2FY%2Bz&state=` | base=`https://web.traceint.com/`，auth=`https://web.traceint.com/index.php/urlNew/auth.html?r=https%3A%2F%2Fweb.traceint.com%2Fweb%2Findex.html&code=X%2FY%2Bz&state=1`（state 为空回落 `"1"`） |
| 3 | `https://wechat.v2.traceint.com/index.php/urlNew/auth.html?r=xxx` | 无 `code`，https 直链：base=`https://wechat.v2.traceint.com/`，auth=原输入串 |
| 4 | `随便写的 https://web.traceint.com/a?code=ok 前面还有字` | 取**最后一个** `https://` 起始片段：base=`https://web.traceint.com/`，auth 含 `code=ok` |
| 5 | `"https://wechat.v2.traceint.com/?code=a\" >"` | 截断到第一个引号/尖括号/空白：base=`https://wechat.v2.traceint.com/`，auth=`https://wechat.v2.traceint.com/?code=a` |
| 6 | `  https://wechat.v2.traceint.com/?code=a  ` | 剥离首尾空白后同 #1 的 host，`code=a` |
| 7 | `微信里复制的链接\\https://web.traceint.com/?code=a` | 剥离反斜杠后同 #4 逻辑 |
| 8 | `https://wechat.v2.traceint.com/?code=1&code=2` | 同名 `code` 取**后者**：`code=2` |
| 9 | `HTTPS://WEB.TRACEINT.COM/?code=a` | host 大小写不敏感：base=`https://web.traceint.com/`（host 归一小写） |
| 10 | `https://evil.example.com/?code=a` | 抛 `notLibraryHost`："这不是有效的图书馆微信授权回调链接" |
| 11 | `http://web.traceint.com/?code=a` | 抛 `requiresHTTPS`："直接授权链接必须使用 HTTPS" |
| 12 | `not a url at all` | 抛 `invalidURL`："请输入有效的微信回调链接" |
| 13 | `https://web.traceint.com/?code=bad%zz` | 转义序列非法（`%` 后不是两位十六进制）：抛 `invalidURL`："请输入有效的微信回调链接"（Java `URI` 语义对齐；微信长链接被截断时会出现这种串） |
| 13b | `https://wechat.v2.traceint.com/?code=%E4%B8` | `%E4%B8` 是**合法**转义（只是不完整的 UTF-8），不抛错：`code` 解码为两个替换字符 U+FFFD，auth 里 formEncode 成 `%EF%BF%BD%EF%BF%BD` |
| 14 | `https://wechat.v2.traceint.com/?code=hello+world` | `+` 按表单编码解码为空格：`code=hello world`，auth 里重新 formEncode 回 `hello+world` |

## mergeSetCookies 用例

jar 为既有 cookie 表（保序），headers 为响应 `Set-Cookie` 列表，只取每项
`分号前` 的 `name=value`：

| # | jar（有序） | Set-Cookie | 期望结果 |
|---|---|---|---|
| 1 | `{wechatSESS_ID: a}` | `SERVERID=xy; Path=/` | `{wechatSESS_ID: a, SERVERID: xy}` |
| 2 | `{SERVERID: old}` | `SERVERID=new; HttpOnly` | `{SERVERID: new}`（同名覆盖） |
| 3 | `{a: 1}` | `b=2`、`c=3`（两条） | `{a: 1, b: 2, c: 3}`（新名追加） |
| 4 | `{}` | `=`（无名字）、`d=4` | `{d: 4}`（畸形项跳过） |
| 5 | `{a: 1}` | `a=`（空值） | `{a: ""}`（仍覆盖，与 Android `put` 语义一致） |

## Android ↔ Swift 语义差异说明（已知且接受）

- Swift `Dictionary` 不保序，`mergeSetCookies` 的"保序"退化为"同名覆盖、新名
  追加"；cookie 是按名查找的，语义无影响。
- 无 `code` 的直链分支：Java 返回 `URI.toASCIIString()`（会重新百分号编码），
  Swift 返回剥离空白/反斜杠后的原串。回调链接含非 ASCII 字符时 Swift 侧
  `URL(string:)` 可能解析失败——按 #13 报"请输入有效的微信回调链接"。

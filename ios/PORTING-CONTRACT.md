# iOS 端移植契约（所有实现文件必须严格遵守）

本文件是 `ios/` 工程的**唯一接口契约**。Android 参考实现在
`android/app/src/main/java/com/gotolibrary/app/`，Swift 端要复刻它的业务语义，
但必须用 iOS 惯用写法（async/await、URLSession、CryptoKit、Keychain），
不要逐行直译 Java 的线程/回调模型。

## 0. 工程约束

- 目标：iOS 16.0+，Swift 5.9，SwiftUI，**不引入任何第三方依赖**。
  只用 Foundation / SwiftUI / CryptoKit / Security / UIKit / UserNotifications / Network。
- Bundle id：`com.gotolibrary.nativeapp`
- 源文件根目录：`ios/GoToLibrary/`，分组目录 `Core/`、`Services/`、`UI/`。
- 注释用中文，风格对齐 Android 端：**只写代码本身看不出来的约束**
  （上游协议怪癖、风控边界、为什么用这个常量），不要写"下一行做什么"。
- 所有跨线程共享的可变状态必须用 `actor` 或 `@MainActor` + 明确的同步点，
  不允许裸 `var` 跨线程读写。
- 严禁修改 `android/`、`public/`、`server.js`、`lib/` 下的任何文件。

## 1. 存储层 `AppConfig`（Core/AppConfig.swift）

`enum AppConfig`（无实例，全部 static）。存储：UserDefaults（suite 名
`gotolibrary_native`）+ Keychain 主密钥做 AES-GCM 加密，语义对齐 Android 的
Keystore 方案。

Keychain 主密钥：`kSecClassGenericPassword`，service `com.gotolibrary.nativeapp`，
account `gotolibrary_session_key`，256-bit 随机，`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`，
`kSecAttrSynchronizable = false`。首次访问时生成。

必须提供的 API（签名固定，其它文件依赖）：

```swift
static func cookie() -> String
static func setCookie(_ value: String) -> Bool
static func clearCookie()
static func isLoggedIn() -> Bool
static func secret(_ key: String) -> String
static func setSecret(_ key: String, _ value: String) -> Bool

static func selectedSeats() -> [String]
static func saveSelectedSeats(_ seats: [String])
static func announcements() -> [String]          // 公告文案数组
static func saveAnnouncements(_ items: [String])

static func queueAdvanceAuto() -> Bool           // 默认 true
static func queueAdvanceMs() -> Int              // 默认 200
static func queueBeforeInterval() -> Int         // 默认 80
static func queueAfterInterval() -> Int          // 默认 500
static func captchaAutoSolve() -> Bool           // 默认 false
static func setCaptchaAutoSolve(_ on: Bool)
static func autoGrabOther() -> Bool              // 默认 true
static func keepCookie() -> Bool                 // 默认 true
static func setKeepCookie(_ on: Bool)
static func keepCookieAutoTomorrow() -> Bool      // 默认 true
static func venueAutoWait() -> Bool               // 默认 true
static func prefetchCaptcha() -> Bool             // 默认 false
static func glassOpacity() -> Int                 // 0...100，默认 40
static func setGlassOpacity(_ value: Int)
static func theme() -> String                     // "warm" | "ocean" | "mint"
static func setTheme(_ value: String)
static func displayName() -> String
static func setDisplayName(_ value: String)
static func avatarData() -> Data?
static func setAvatarData(_ data: Data?)
static func lastUpdateCheckAt() -> Date?
static func setLastUpdateCheckAt(_ date: Date)

static func addLog(_ message: String)             // 前缀 "HH:mm:ss  "，最多 300 条
static func logsText() -> String                  // 无记录返回 "暂无运行记录"
static func clearLogs()
```

常量：`prefsSuiteName`、`maxLogEntries = 300`、
`modeRealtime = "realtime"`、`modeTomorrow = "tomorrow"`、
`themeWarm/themeOcean/themeMint`。

`addLog` 除写存储外，**必须** `NotificationCenter.default.post(name: .goToLibraryLogsChanged, object: nil)`，
并 `os_log` 到 subsystem `com.gotolibrary.nativeapp`，category `run`。
（对齐 Android 端同时镜像 logcat 的做法：真机排障时应用内日志取不出来。）

其它键值：`KEY_MODE = "mode"`、`KEY_TIME = "tomorrow_time"`、`KEY_RUNNING = "running"`、
`KEY_STATUS_TITLE/KEY_STATUS_DETAIL/KEY_STATUS_COUNTDOWN`、`KEY_ROOM_ID/KEY_ROOM_NAME`
（提供 `static func roomId() -> Int` / `setRoomId(_:)` / `roomName()` / `setRoomName(_:)` /
`mode()` / `setMode(_:)` / `tomorrowTime() -> String` 默认 `"20:00:00"` / `setTomorrowTime(_:)` /
`running() -> Bool` / `setRunning(_:)` / `status() -> (title: String, detail: String, countdownMs: Int)` /
`setStatus(title:detail:countdownMs:)`）。

存储加密失败一律 **fail-closed**：拿不到密文就返回空字符串并清掉脏数据。

## 2. 微信回调解析 `WechatSessionCodec`（Core/WechatSessionCodec.swift）

```swift
struct SessionRequest { let baseURL: String; let authURL: String }
enum SessionCodecError: LocalizedError {
    case invalidURL, notLibraryHost, requiresHTTPS, badEncoding, encodeFailed
    var errorDescription: String? { get }   // 文案照抄 Android：
    // "请输入有效的微信回调链接" / "这不是有效的图书馆微信授权回调链接"
    // / "直接授权链接必须使用 HTTPS" / "微信回调链接编码无效" / "微信回调链接编码失败"
}
static func parse(_ callbackURL: String) throws -> SessionRequest
static func mergeSetCookies(_ jar: inout [String: String], _ setCookieHeaders: [String])
```

`parse` 语义严格照抄 `WechatSessionCodec.java:26-60`：
1. 剥离首尾空白、去掉反斜杠，取**最后一个** `http://` 或 `https://` 起始片段，
   截到第一个空白/引号/尖括号为止；
2. host 只接受 `wechat.v2.traceint.com`、`web.traceint.com`（大小写不敏感）；
3. 有 `code` 时构造
   `https://<host>/index.php/urlNew/auth.html?r=<urlEncoded(https://host/web/index.html)>&code=<urlEncoded(code)>&state=<urlEncoded(state 或 "1")>`；
4. 没有 `code` 时要求 scheme 为 https，直接返回原 URL 作为 authURL。

编码用 `formURLEncoded`（空格转 `+`，与 Java `URLEncoder` 一致），
**不要**用 `URLComponents` 的默认 query 编码（空格会变 `%20`，上游不认）。

## 3. 上游客户端 `TraceintClient`（Core/TraceintClient.swift）

用 `URLSession` + `async/await`。`final class TraceintClient`，**线程安全**，
内部用 `actor` 或 `NSLock` 保护可变的 `cookie`。

```swift
static let graphqlURL = "https://wechat.v2.traceint.com/index.php/graphql/"
static let loginURL = "https://open.weixin.qq.com/connect/oauth2/authorize?appid=wx2996d437cd442527&redirect_uri=https%3A%2F%2Fwechat.v2.traceint.com%2Findex.php%2Fgraphql&response_type=code&scope=snsapi_userinfo&state=1#wechat_redirect"
static let websocketUA: String
static func httpUserAgent() -> String

struct Room { let id: Int; let name: String; let available: Int; let open: Bool }
struct Seat { let key: String; let name: String; let type: Int; let status: Any?; let seatStatus: Int? }
struct TomorrowAvailability { let ready: Bool; let available: Int?; let seats: [Seat] }
struct Captcha { let code: String; let imageBase64: String }
struct ReserveOutcome { let success: Bool; let message: String }
struct CandidateList { let list: [Seat]; let fellBack: Bool }
struct IndexProbe { let invalid: Bool; let detail: String; let userId: String }
struct ApiError: LocalizedError { let message: String }

init(cookie: String, onCookieRefreshed: ((String) -> Void)? = nil)

func fetchRooms() async throws -> [Room]
func fetchSeats(roomId: Int) async throws -> [Seat]
func reserveSeat(roomId: Int, seat: Seat, captcha: String, captchaCode: String) async throws -> ReserveOutcome
func fetchTomorrowAvailability(roomId: Int, includeSeats: Bool) async throws -> TomorrowAvailability
func reserveTomorrow(roomId: Int, seat: Seat, captcha: String, captchaCode: String) async throws -> ReserveOutcome
func fetchCaptcha(tomorrow: Bool) async throws -> Captcha
func fetchUserId() async throws -> String
func verifyTomorrow(roomId: Int, seat: Seat) async throws -> Bool
func indexProbe() async throws -> IndexProbe

static func exchangeCallbackForCookie(_ callbackURL: String) async throws -> String
static func isRiskMessage(_ message: String?) -> Bool
static func isSessionExpired(_ message: String?) -> Bool
static func isSessionInvalid(_ message: String?) -> Bool
static func isFree(_ seat: Seat) -> Bool
static func orderCandidates(_ seats: [Seat], preferred: [String], freeOnly: Bool) -> [Seat]
static func chooseCandidates(_ seats: [Seat], preferred: [String], freeOnly: Bool, allowOther: Bool) -> CandidateList
static func mergeServerCookies(_ cookieHeader: String, _ setCookies: [String]) -> String
static func cookieNames(_ cookieHeader: String) -> String
```

GraphQL 请求必须复刻以下 4 个**不能改**的行为：

1. **请求体用 `Data` 直接构造，绝不设 `charset`。**
   `Content-Type: application/json` 必须精确，带 `; charset=utf-8` 时上游把 body 当空处理
   并返回 `Syntax Error: Unexpected <EOF>`。见 Android `TraceintClient.java:437-446`。
2. **头部集合照抄 Android `graphqlOnce` 的列表**（`TraceintClient.java:443-466`）：
   Host / Referer `https://web.traceint.com/` / Origin `https://web.traceint.com` /
   Connection keep-alive / app-version `2.1.5` / Upgrade-Insecure-Requests 1 /
   User-Agent / sec-ch-ua-platform `"Android"` / sec-ch-ua
   `"Chromium";v="134", "Not:A-Brand";v="24", "Android WebView";v="134"` / sec-ch-ua-mobile `?1` /
   x-requested-with `com.tencent.mm` / Sec-Fetch-Site same-site / Sec-Fetch-Mode cors /
   Sec-Fetch-Dest empty / accept-language / Accept `*/*` / priority `u=1, i` / Cookie。
   这一整套是逆向出来的"微信客户端"指纹，**不要为了"更像 iOS"而改动**；
   在文件顶部用注释写明这一点。
3. `Authorization` 四态重放：从 cookie 里取 `Authorization` 值，依次尝试
   不带头 → 原值 → URL 解码值 → 解码值前补 `Bearer `；只有错误信息含
   `Unexpected <EOF>` 才换下一态，其它错误直接抛出。
4. 响应里每个 `Set-Cookie` 都要合并进当前 cookie（同名覆盖、新名追加，保持顺序），
   变化时回调 `onCookieRefreshed`。这是长跑保活的关键，不能省。

`httpUserAgent()`：复刻 Android `buildHttpUserAgent` 的结构，但设备信息换成 iOS：
`Mozilla/5.0 (iPhone; CPU iPhone OS <版本> like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko)
Mobile/15E148 MicroMessenger/8.0.49(0x18003128) NetType/<WIFI|4G|UNKNOWN> Language/<zh_CN> ABI/arm64`。
`websocketUA` 用同族固定串（对齐 Android 里 WS 侧写死 UA 的做法）。
`NetType` 用 `NWPathMonitor` 判定（Wi-Fi → `WIFI`，蜂窝 → `4G`，未知 → `UNKNOWN`）。

`exchangeCallbackForCookie`：**不跟随自动重定向**，手工逐跳跟随最多 6 跳，
每跳都吃 `Set-Cookie`；跳转目标 host 必须是两个图书馆域之一，否则抛
`ApiException("授权跳转到了非图书馆地址")`。最后若除 `SERVERID` 外没有任何非空
cookie，抛 `"微信授权已失效，请重新获取回调链接"`；否则拼成 `k=v; k=v` 返回。

GraphQL errors 数组拼成中文分号连接的消息抛出。
`explicitSuccess` 分派逻辑照抄 `TraceintClient.java:654-665`。

## 4. 会员校验 `LicenseManager`（Core/LicenseManager.swift）

```swift
enum LicenseState { case active, none, expired, stale, tampered, hostile }
static let refreshWindow: TimeInterval = 72 * 3600      // 与服务端 GRACE_MS 一致
static let refreshInterval: TimeInterval = 24 * 3600
static func deviceFingerprint() -> String               // identifierForVendor 的 SHA-256 hex 小写
static func displayDeviceCode() -> String               // 前 16 位 4 位一组
static func currentState() -> LicenseState
static func isUsable() -> Bool
static func entitlementToken() -> String?                // 仅当验签通过才返回
static func membershipExpiresAt() -> TimeInterval        // 0 表示未知
static func storeVerifiedToken(_ token: String, serverTime: String) -> Bool
static func clearLicense()
static func shouldRefresh() -> Bool
static func lastRefreshAt() -> Date?
```

- 凭证格式 `<base64url(payloadJSON)>.<base64url(DER 签名)>`，payload 字段
  `deviceId` / `expiresAt` / `refreshNotAfter` / `issuedAt`（ISO8601 字符串）。
- 验签用 CryptoKit：公钥来自 `BuildConfig.licensePublicKey`（**DER/SPKI base64**），
  转成 x9.63 再 `P256.Signing.PublicKey(x963Representation:)`，
  签名用 `P256.Signing.ECDSASignature(derRepresentation:)`，对**解码后的 payload 原始字节**验签。
  SPKI→x9.63 要做真实 DER 解析（P-256 SPKI 共 91 字节，尾部 65 字节为
  `0x04 || X || Y`），不要盲取末 65 字节以外的位置；解析失败返回 nil（fail-closed）。
- 必须校验 `payload.deviceId == deviceFingerprint()`。
- 信任时钟：`max(系统时间, 见过的最大服务器时间 + 开机以来流逝)`，用
  `ProcessInfo.processInfo.systemUptime` 当单调时钟锚点（替代 Android 的 `elapsedRealtime`），
  对齐 `LicenseManager.java:143-151`。
- `isHostileEnvironment()`：iOS 上做 best-effort 越狱探测（`/Applications/Cydia.app`、
  `/bin/bash`、`/usr/sbin/sshd`、`/etc/apt`、`/private/var/lib/apt`、`canOpenURL("cydia://")`）。
  **注释写明**：iOS 无 Root/重打包概念，这里的 tampered 判定退化为越狱探测，
  真实签名校验由 App Store / 描述文件承担。
- 公钥缺失或为空 → `currentState()` 返回 `.none`，一切拒绝（fail-closed）。

## 5. 许可接口 `LicenseClient`（Core/LicenseClient.swift）

```swift
final class LicenseClient {
    init()
    func activate(code: String, deviceId: String, deviceName: String) async throws -> String   // 返回响应 body
    func refreshEntitlement(deviceId: String, nonce: String) async throws -> String
}
```

- `POST <BuildConfig.licenseAPIBase>activate` / `entitlement`，JSON body，`Content-Type: application/json`。
- 重试：网络失败按 `[0.8, 2.5, 5.0]` 秒退避重试 3 次（大陆链路对自签 IP 的 TLS 重置是
  按连接随机的，换连接重试常能通过）。
- **SPKI 证书固定**：用 `URLSessionDelegate` 的
  `urlSession(_:didReceive:completionHandler:)` 手工校验
  `SecTrustCopyKey`/`SecCertificateCopyKey` 的 SPKI SHA-256 是否命中
  `BuildConfig.licenseSPKIPins`（值为 `"sha256/<base64>"` 形式）。
  这是自签 IP 证书的唯一信任锚；**不做**系统 CA 与主机名校验。
  命中即放行，否则 `cancelChallenge`。
- 明文放行条件：仅当 `BuildConfig.licenseAllowHTTP` 为真（debug 联调）才允许
  `http://` 基址，否则非 https 直接报 `"许可服务未配置"`。

## 6. 验证码 `CaptchaSolver`（Core/CaptchaSolver.swift）

```swift
struct SolveResult { let code: String; let uniqueCode: String? }
final class CaptchaSolver {
    static let codePattern = "^[A-Za-z0-9]{4}$"
    static func isPlausible(_ answer: String?) -> Bool
    var leftCredits: Int { get }              // -1 表示未知
    var isTokenUnavailable: Bool { get }
    func solve(imageBase64: String) async -> SolveResult?     // nil = 失败，不回退不抛
    func refund(uniqueCode: String?) async
}
```

- 走 `BuildConfig.captchaAPIBase` + `solve` / `refund`，鉴权头
  `X-Device-Id`（设备指纹）、`X-Device-Token`（`LicenseManager.entitlementToken()`）。
- 与许可服务共用同一套 SPKI 固定的 URLSession。
- `solve` 响应含 `error == "device_forbidden"` 或 `"captcha_not_configured"` 时，
  置 `tokenUnavailable = true` 并且**之后不再重试**（配额失效时重试只会白等十几秒，
  拖过抢座窗口 —— 见 Android `CaptchaSolver.java:68-103` 的注释）。
- 识别结果不匹配 4 位正则时按失败处理；调用方负责退码。

## 7. 构建常量 `BuildConfig`（Core/BuildConfig.swift）

`enum BuildConfig`，值通过编译条件或 `Info.plist` 注入，**默认值与 Android release 对齐**：

```swift
static var licenseAPIBase: String      // "https://120.27.227.206/api/device/"
static var captchaAPIBase: String      // "https://120.27.227.206/api/captcha/"
static var updateBase: String          // "http://120.27.227.206/apk/"  → iOS 侧仅用于查询版本
static var licensePublicKey: String    // 服务端 ECDSA P-256 公钥（DER/SPKI base64）
static var licenseSPKIPins: [String]   // ["sha256/6gKK6e/e21R0JtWagsehCa/VqlL58q6Gy838emip2eY="]
static var licenseAllowHTTP: Bool
static var isDebug: Bool
static var appVersion: String          // Info.plist CFBundleShortVersionString
static var appBuild: String            // Info.plist CFBundleVersion
```

用 `#if DEBUG` 切换联调地址（`http://127.0.0.1:3990/api/device/`、
`http://127.0.0.1:3990/api/captcha/`）与联调公钥
`MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE6FWKOgeTnCsO4nEG1niOOdcaAuRho7T9YWldwD4u45w2cpkTTgvfJFKK3k5M+/TKVaQs1O+BFT4zmlHH1buXGw==`。
**注释写明**：发版前必须替换 `licensePublicKey` 与 `licenseSPKIPins`
（管理面板"APK 设备"页可复制公钥；`openssl s_client -connect host:443` 取 SPKI）。

## 8. 排队引擎 `QueueEngine`（Core/QueueEngine.swift）

复刻 `QueueEngine.java` 的全部阶段逻辑，用 `actor` 承载可变状态。

```swift
protocol QueueEngineListener: AnyObject {
    func queueLog(_ message: String)
    func queuePassed()
    func queueAlreadyBooked()
    func queueBlocked(_ message: String)
    func queueExhausted(_ message: String)
}

final class QueueEngine {
    init(cookie: String, userAgent: String, advanceMs: Double, beforeIntervalMs: Double,
         afterIntervalMs: Double, fallbackOpenTime: String?, listener: QueueEngineListener)
    func run() async                  // 跑完或被 cancel 后返回
    func cancel()
    static func queryClockOffsetMs(host: String, timeoutMs: Int) async -> Int
    static func decodeUnicodeEscapes(_ text: String) -> String
}
```

必须保留的常量与行为（**逐个对齐，不要"简化"**）：

- `queueURL = wss://wechat.v2.traceint.com/ws?ns=prereserve/queue`，origin header
  `https://web.traceint.com`；握手头同 Android（Host/Origin/User-Agent/Pragma/Cache-Control/
  Sec-WebSocket-Version 13/Accept-Encoding/Accept-Language/Cookie）。用 `URLSessionWebSocketTask`
  + `URLRequest` 设置这些头。
- ping 载荷 `{"ns":"prereserve/queue","msg":""}`。
- 关键常量：`crowdedQueueThreshold = 30`、`fineCountdownWindowSeconds = 13.0`、
  `coarseCountdownLeadMs = 10_000`、`coarseGuardTriggerMs = 8_000`、
  `reconnectBackoffMs = [10, 100, 500, 1000, 2000, 4000, 8000]`、
  `cookieKeepalivePingMs = 5_000`、`stableConnectionMs = 5_000`、
  `openTimeCarryOverMs = 15 * 60 * 1000`、`maxUnknownMessageLogs = 5`、
  `overallTimeoutMs = 30 * 60 * 1000`、`crowdedQueuePingMs = 1000`、`coarseWaitPingMs = 30_000`。
- 三阶段推进：`warmup → coarse（30s 低频 + 粗倒计时 500ms tick）→ fine（50ms tick，
  距开放 ≤13s）→ highFreq（距开放 ≤advanceMs）`，阶段位**只进不退**。
- **倒计时按绝对截止时刻判断**（不是逐 tick 累减）：定时器被系统冻结后恢复，
  第一拍就要发现已到点。见 `QueueEngine.java:412-433` 的注释。
- 低频阶段另起 1 秒周期的看门狗，按真实时刻重算，进入"距高频不足 8s"就推进。
- ping 循环排在**固定绝对时间网格**上：落后时对齐到网格下一点，
  不累加漂移也不在恢复后连续补发一串请求（`QueueEngine.java:471-496`）。
- 服务器消息分派顺序不能改，且 `"prereserve/queue\",\"code\":0,\"data\":"`
  这个匹配串**必须紧跟 `"data":`**，否则同帧里其它文案会被抢进人数分支，
  挡住后面"不在预约时间内"的判断（那个判断才驱动三阶段计时）。
- 消息处理前先 `decodeUnicodeEscapes`：还原 `\/` → `/` 与 `\uXXXX`。
  少了 `\/` 这一步整个排队人数分支都匹配不上。
- 重连退避：只有连接稳定存活 ≥5s 才把退避重置为 10ms，否则继续升级
  （否则服务器"握手成功立刻断开"会变成 10ms 热循环）。
- 服务器已告知的开放时刻要跨重连带过去（宽容窗口 15 分钟）。
- 排队人数 >30 放宽到 1000ms，≤30 用 `afterIntervalMs`；已进入高频或低频等待期
  **不因人数改档**。
- 断线必须置位重连标志让外层退出等待；只在 `onFailure` 打日志会让引擎干等到 30 分钟总超时。
- `queryClockOffsetMs`：真 UDP socket 发 NTP 请求（LI=0,VN=3,Mode=3 → 首字节 `0x1B`），
  按 RFC 计算往返与偏差，失败返回 0。用 `Network.framework` 的
  `NWConnection`/`NWUDPSession` 或 BSD socket 均可，但**必须是真实 NTP 往返**，
  不能本地编造。`ntp.aliyun.com`、超时 5000ms。

## 9. 预约执行 `ReservationRunner`（Services/ReservationRunner.swift）

替代 Android 的 `ReservationService`（前台服务）。iOS **不能**常驻后台，
所以：

- 运行时用 `UIApplication.shared.isIdleTimerDisabled = true` 保持屏幕常亮，
  并在开始时申请 `beginBackgroundTask` 拿到约 30 秒的额外后台时间；
  后台额度耗尽时把任务置为"已挂起"状态并**发本地通知**提示用户回到应用
  （而不是假装还在跑）。
- 必须在日志与 UI 里如实说明当前处于前台/后台，不能让用户以为锁屏也在抢。

```swift
@MainActor
final class ReservationRunner: ObservableObject {
    static let shared = ReservationRunner()
    @Published private(set) var running: Bool
    @Published private(set) var statusTitle: String
    @Published private(set) var statusDetail: String
    @Published private(set) var countdownMs: Int
    func start() async
    func stop()
}
```

业务逻辑从 `ReservationService.java` 移植，**语义必须一致**：

- 启动前二次校验 `LicenseManager.isUsable()`，不通过就拒绝并写日志
  （任务真正下发前必须再验一次签名凭证，门禁只是 UI 层）。
- 常量：`chainDelayStartMs = 1000`、`chainDelayGrowStepMs = 300`、`seatTakenDelayMs = 1100`、
  `venueRecheckMs = 500`、`todayScanIntervalMs = 600`、`captchaRetryCap = 20`、
  `queueLeadSeconds = 30`。
- 今日模式 `runRealtime`：扫座位 → `chooseCandidates(preferred, freeOnly: true, allowOther: false)`
  → 尝试链；**尝试链跑完即结束任务，不回头继续扫**；无空位时每 600ms 重扫，
  且"暂时没有符合条件的空位"日志 5 秒最多一条。
- 明日模式 `runTomorrow`：先把明日目标时间前推 30 秒算 `connectAt`，
  每秒刷倒计时（界面倒计时要实时跳，不能一分钟跳一格）→ 到点进排队 →
  `prefetchCaptcha` 开且打码开时预取一张验证码 → 指定座位一轮尝试链 →
  没有空位且 `autoGrabOther` 时**再查一遍全部空位**跑"捡漏"轮 → 两轮都抢不到就结束
  （明日座位被抢完基本不会回吐，持续轮询没有意义）。
- 排队引擎参数：`computeAdvanceMs()` 复刻 `ReservationService.java:478-495` ——
  手动模式用用户值；自动模式 NTP 校时，本机慢 → `offset + 150`，
  本机快 → `350 + offset`。日志文案照抄。
- 尝试链 `runAttemptChain`：`RETRY_SAME_SEAT` 受 `captchaRetryCap` 限制，
  超限转下一座位；`RETRY_SAME_SEAT_GROW` 无上限，延迟 1000→1300→1600…累进；
  `SEAT_TAKEN` 把链内共享延迟重置为 1100ms。
- `attemptBooking` 的响应分派按 `ReservationService.java:554-599` 的
  关键字顺序逐条对齐（成功 / 您已经预定了座位 / 输入验证码 / 该座位已经被 /
  重新尝试 / 名额已满·不可选座·异常预约 → 终止 / 未开放·不开放 → 场馆关闭 /
  其余 → 换下一座位延迟 1000ms）。
- "输入验证码"分支：先退码；若 `captchaAutoSolve` 关闭，**直接换下一座位**
  （再拿空验证码重试同一座位只会拿到同一句提示，会在这个座位上耗满 20 次）。
- `fetchAndSolveCaptcha`：取图 → 打码 → 4 位正则校验 → 无效退码立即重取；
  打码服务确定性拒绝本设备时直接放弃本次识别（不要取 20 张图）。
- 会话失效 → 清 cookie + "登录已失效"；命中风控文案 → "账号保护已触发" 并停止。
- 明日预约模式下若 `keepCookieAutoTomorrow` 且保活未运行，自动拉起 `SessionKeeper`。
- 状态写入走 `AppConfig.setStatus(title:detail:countdownMs:)` 并发
  `NotificationCenter` 通知 `.goToLibraryStatusChanged`。
- 到达终态发本地通知（成功/失败两类，见 `NotificationService`）。

## 10. 保活 `SessionKeeper`（Services/SessionKeeper.swift）

```swift
@MainActor
final class SessionKeeper: ObservableObject {
    static let shared = SessionKeeper()
    @Published private(set) var running: Bool
    @Published private(set) var invalid: Bool
    @Published private(set) var pingCount: Int
    func start() async
    func stop()
}
```

- 常量：`throttleMs = 2500`、`minIntervalMs = 5000`、`intervalSpreadMs = 25000`
  （间隔 = 5000 + random(25000)）；距上次请求不足 2500ms 先等满。
- 每轮 `client.indexProbe()`，仅当上游**明确拒绝会话**（`isSessionInvalid`）
  才停止并把 `invalid` 持久化（进程被杀后 UI 仍要如实显示"登录已失效"，
  不能因为 cookie 还在就显示有效）；网络超时与瞬时错误一律继续下一轮。
- 复用同一个 `TraceintClient`（避免每轮新建连接池），cookie 变化时重建。
- iOS 限制：后台只能维持很短时间。前台运行即可；进入后台超过系统额度时暂停循环，
  回到前台自动恢复，并把 `invalid`/`running` 状态如实反映到 UI。
  在文件顶部注释说明这一点。

## 11. 通知与更新

`Services/NotificationService.swift`：

```swift
enum NotificationService {
    static func requestAuthorization() async -> Bool
    static func postResult(title: String, detail: String) async
    static func postMonitor(title: String, detail: String) async   // 用于前台可选的常驻提示
}
```

- `UNUserNotificationCenter`，两个 category：`reservation_result`（高优先级、
  声音 + 震动）、`reservation_monitor`（静默）。
- 结果通知文案对齐 Android：成功 "预约成功 / 明日预约成功 / 任务已停止"，
  失败 "登录已失效 / 账号保护已触发 / 明日预约未进入队列"。

`Services/AppUpdater.swift`（替代 `AppUpdater.java`）：

```swift
enum AppUpdater {
    struct Release { let version: String; let versionCode: Int; let notes: String; let url: String }
    static func checkForUpdate(force: Bool = false) async -> Release?
}
```

- 拉 `BuildConfig.updateBase + "version.json"`，与本地 `versionCode`（`CFBundleVersion` 整数化）
  比较，发现更高版本返回 `Release`。
- **iOS 不能自安装**：只用于弹窗提示 + `UIApplication.shared.open` 打开下载页或
  跳转 App Store。在注释里写清这个平台差异。

## 12. UI 层（UI/）

对齐 Android 的四页结构（首页 / 预约 / 日志 / 我的）+ 会员激活门禁：

- `UI/Theme.swift`：三套主题（warm/ocean/mint）。warm 的颜色照抄
  `android/app/src/main/res/values/colors.xml`：
  `appBackground #F6F2EA`、`surface/ink #1D1B18`、`secondaryText #7A736C`、
  `primary #BF552F`、`primaryDark #2A1711`、`danger #C84F55`、`navIdle #746F67`。
  ocean / mint 各给一套同结构的协调色值。提供 `Theme.current`（读 `AppConfig.theme()`）。
- `UI/Glass.swift`：液态玻璃视觉 —— 动态渐变光斑背景（`MeshGradient` 在 iOS18 可用时用，
  否则多层 `RadialGradient` + `TimelineView` 缓慢漂移）、玻璃卡片
  （`.ultraThinMaterial` + 描边 + 阴影，透明度由 `AppConfig.glassOpacity()` 控制）、
  玻璃按钮、呼吸状态点（对齐 `PulseDotView`）。全部做成
  `ViewModifier` / `ButtonStyle` 供其它页复用。
- `UI/MainView.swift`：底部胶囊导航（首页/预约/日志/我的），
  用 `matchedGeometryEffect` 做指示器滑动，切页有入场位移 + 淡入
  （对齐 Android 的 `PANEL_ENTRANCE_OFFSET_DP = 14` 与 26ms 交错）。
- `UI/HomeView.swift`：问候语 + 任务状态卡 + 倒计时 + 开始/停止/明日预约按钮 +
  最近日志摘要 + 公告列表。
- `UI/BookingView.swift`：模式选择（实时/明日）+ 目标时间 + 阅览室下拉 +
  座位多选（网格选座面板）+ 预约参数（排队提前量、前后间隔、验证码自动识别、
  捡漏、场馆自动等待、预取验证码）+ 保存/启动。
- `UI/LogsView.swift`：日志列表（读 `AppConfig.logsText()`），支持复制全部、清空；
  用 `NotificationCenter` 订阅 `.goToLibraryLogsChanged` 自动刷新。
- `UI/AccountView.swift`：头像（PhotosPicker）、昵称、主题切换、玻璃通透度滑杆、
  玻璃/微信登录状态、登录链接复制 + 回调链接粘贴解析、退出登录、会员状态卡、
  保活开关、应用更新检查。
- `UI/LicenseGateView.swift`：未激活时的全屏门禁 —— 设备码、卡密输入、
  激活按钮、重新校验；展示会员到期时间与上次复验时间。

登录流程在 iOS 上的正确做法（写进注释）：
复制授权链接 → 在微信里打开并授权 → 把跳转后的完整链接粘回应用。
iOS 无法像 Android 那样读剪贴板以外的方式截获回调，所以额外提供
"从剪贴板读取"按钮（`UIPasteboard.general.string`）方便用户。
**不要**试图用 `ASWebAuthorizationSession` 或 `SFSafariViewController` 截获
微信授权回调，那条路在微信 OAuth 下走不通。

## 13. 工程文件

- `ios/GoToLibrary/Info.plist`：`CFBundleDisplayName` "野原家书屋"、
  `UILaunchScreen`（字典形式）、`NSAppTransportSecurity` 仅对
  `120.27.227.206` 与 `127.0.0.1` 开 `NSExceptionAllowsInsecureHTTPLoads`
  （对齐 Android 的 `network_security_config.xml` 只在 debug 放行明文）、
  `NSPhotoLibraryUsageDescription`、`UIBackgroundModes = [audio]`（不允许 —— 
  **不要**加音视频后台模式骗后台时间，只加 `fetch` 并注释说明限制）。
- `ios/GoToLibrary/Assets.xcassets`：`AccentColor`、`AppIcon`（用仓库
  `public/icons/icon-v11-512.png` 作为 1024 图标来源，说明需在 macOS 上导出各尺寸）。
- `ios/GoToLibrary.xcodeproj/project.pbxproj`：手写工程文件，
  objectVersion 56、`SWIFT_VERSION = 5.9`、`IPHONEOS_DEPLOYMENT_TARGET = 16.0`、
  `PRODUCT_BUNDLE_IDENTIFIER = com.gotolibrary.nativeapp`、
  `GENERATE_INFOPLIST_FILE = NO` + `INFOPLIST_FILE`，
  Debug/Release 两个 configuration，所有源文件加入 `PBXSourcesBuildPhase`。
  `DEVELOPMENT_TEAM` 留空并注释说明发版前需填。
- `ios/README.md`：构建步骤（macOS + Xcode 15+、`xcodebuild` 命令、
  签名配置、发版前三处必改配置）、与 Android 端的功能对照表、
  **iOS 平台限制**（不能常驻后台抢座、不能自安装更新、不能截获微信回调）的如实说明、
  `ios/verification/` 里放不依赖 Xcode 的纯逻辑自检脚本（Swift 版
  `WechatSessionCodec` 的用例表用 markdown 列出期望输入→输出，便于任何平台核对）。

## 14. 命名与风格硬约束

- 类型名/Case 名沿用 Android 语义（`Seat`、`Room`、`CandidateList`、`LicenseState`…），
  但遵循 Swift 命名规范（方法首参不重复标签，`fetchSeats(roomId:)` 而非 `fetchSeats(_ roomId:)`）。
- 所有 `async` 方法不得在内部 `Thread.sleep`；延迟统一用
  `try await Task.sleep(nanoseconds:)` 并正确处理 `CancellationError`。
- 捕获 `CancellationError` 时必须**向上传播**，不要吞掉后继续循环。
- 每个文件顶部用一行 `//` 注释说明该文件对应 Android 侧的哪个类。

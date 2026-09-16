# 野原家书屋 iOS 客户端

原生 SwiftUI 客户端，与 `android/` 下的原生 Android 客户端功能对齐：微信回调解析、
Cookie 加密存储（Keychain）、阅览室/座位查询、实时捡漏、明日预约（排队通道 + 结果复核）、
验证码打码、会员激活。液态玻璃风格界面（动态光斑背景、玻璃卡片、呼吸状态灯）。

## 构建步骤

需要 macOS + Xcode 15+（Swift 5.9）。**无法在 Windows 上构建** —— 本目录的
Swift 源码是在 Windows 上编写的，未经编译器验证，首次在 macOS 构建时需要按
「未验证项」一节修错。

命令行归档：

```bash
cd ios
xcodebuild -project GoToLibrary.xcodeproj -scheme GoToLibrary \
  -configuration Release -archivePath build/GoToLibrary.xcarchive archive
```

导出 IPA：

```bash
xcodebuild -exportArchive -archivePath build/GoToLibrary.xcarchive \
  -exportPath build -exportOptionsPlist ExportOptions.plist
```

签名配置：

1. Xcode 里打开 `GoToLibrary.xcodeproj` → target `GoToLibrary` → Signing & Capabilities；
2. 填自己的 `DEVELOPMENT_TEAM`（当前留空，archive 会失败）；
3. 个人开发证书即可真机安装；分发到 App Store 需要 Apple Developer Program。

本机没有 Xcode 时如何生成新工程文件：源码增删后重跑
`node ios/tools/generate-xcodeproj.js`，脚本会从磁盘真实文件树重建
`project.pbxproj`，保证 Sources 阶段与文件系统一致。

## 发版前必改的配置

1. `GoToLibrary/Core/BuildConfig.swift` 的 `licensePublicKey`：服务端 ECDSA P-256
   公钥（DER/SPKI base64），管理面板"APK 设备"页顶部可复制。留空时一切凭证
   校验直接失败（fail-closed）。
2. `GoToLibrary/Core/BuildConfig.swift` 的 `licenseSPKIPins`：服务器证书链的
   SPKI SHA-256（许可服务走自签 IP 证书，这是唯一信任锚）。取法：

   ```bash
   openssl s_client -connect 120.27.227.206:443 </dev/null 2>/dev/null \
     | openssl x509 -pubkey -noout \
     | openssl pkey -pubin -outform der \
     | openssl dgst -sha256 -binary | openssl enc -base64
   ```

   服务器换证书时必须同步更新并重新发版。
3. `GoToLibrary/Info.plist` 的 `CFBundleShortVersionString` / `CFBundleVersion`
   与 `Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`。当前 1024 图标是
   从 `public/icons/icon-v11-512.png` Lanczos 放大生成的占位件，上架前应在
   macOS 上用原始矢量/高清源重新导出真实 1024×1024。
4. `GoToLibrary/Info.plist` 的 `UpdatePageURL`：iOS 不能自安装更新，更新提示必须落到
   App Store 或下载页地址；留空则不做更新提示。iOS 的版本清单走
   `BuildConfig.updateManifestName`（默认 `version-ios.json`，可用 Info.plist 同名键覆盖），
   **不复用 Android 的 `version.json`** —— 那份由 `android/build-apk.ps1` 生成，
   versionCode 是 Android 构建号，iOS 读它只会把"Android 发了新包"误报成 iOS 有新版本。
   `version-ios.json` 需要与 Android 的清单分开维护，字段：`versionCode` / `versionName` /
   `notes` / `iosUrl`（下载页或 App Store 地址）。

## 与 Android 端的功能对照

| 功能 | Android | iOS |
|---|---|---|
| 微信登录 | 粘贴回调链接，Java 解析 + 手工逐跳换 Cookie | 同一算法移植到 Swift（`WechatSessionCodec`），另有「从剪贴板读取」辅助按钮 |
| Cookie 加密存储 | Android Keystore AES-GCM | Keychain 主密钥 + AES-GCM（`AppConfig`） |
| 阅览室/座位查询 | GraphQL `libs` / `libLayout` | 同一 GraphQL 协议（`TraceintClient`），请求体/头部指纹逐字对齐 |
| 实时捡漏 | 前台服务 `ReservationService` | 前台运行 `ReservationRunner`（屏幕常亮，见平台限制） |
| 明日预约排队 | `QueueEngine` WebSocket 三阶段 | 同一阶段机移植（`QueueEngine.swift`），ping 网格/看门狗/退避全对齐 |
| NTP 校时 | UDP `ntp.aliyun.com` | 真实 UDP NTP 往返（`NWConnection`/BSD） |
| 验证码打码 | 主站中转 `/api/captcha/*`，SPKI 锁定 | 同一接口 + `URLSessionDelegate` SPKI 固定 |
| 会员激活 | ECDSA P-256 凭证 + 72h 复验窗口 | CryptoKit 验签，同一凭证格式（`LicenseManager`） |
| Cookie 保活 | 前台服务随机 5–30s 探针 | 前台循环探针（`SessionKeeper`），后台会暂停（见平台限制） |
| 应用内日志 | SharedPreferences 环形 300 条 + logcat 镜像 | UserDefaults 环形 300 条 + os_log 镜像 |
| 主题/玻璃通透度 | warm/ocean/mint，BlurView | 同三主题，`.ultraThinMaterial`，通透度滑杆 |
| 应用更新 | 下载 APK 交给系统安装器 | 仅检查 + 打开下载页（见平台限制） |

## iOS 平台限制（如实说明）

1. **不能常驻后台抢座。** Android 有前台服务可以锁屏整夜运行；iOS 进程进入
   后台几秒内就被挂起，`beginBackgroundTask` 只多给约 30 秒。任务在后台会被
   置为"已挂起"并发本地通知提示回到应用——这是如实状态，不是还在跑。
   应用不使用任何音视频/定位后台模式骗取后台时间（会导致上架被拒）。
   Info.plist 也不声明任何 `UIBackgroundModes`：工程没有实现 `BGTaskScheduler` /
   `performFetch`，声明用不到的后台模式同样是审核拒绝理由。
2. **不能自安装更新。** Android 可下载 APK 交给系统安装器；iOS 只提示新版本
   并跳转下载页/App Store。
3. **不能截获微信授权回调。** `ASWebAuthenticationSession` 与
   `SFSafariViewController` 都拿不到微信 OAuth 的自定义跳转，所以登录流程是：
   复制授权链接 → 微信里打开并授权 → 把跳转后的完整链接粘回应用
   （页面提供「从剪贴板读取」减少手工操作）。
4. **没有重打包自校验。** `LicenseManager` 的 tampered 状态在 iOS 上退化为
   越狱探测；真实签名完整性由 App Store / 描述文件分发渠道承担。
5. **网络栈差异。** OkHttp 能精确锁定 HTTP/1.1 与全部请求头；`URLSession`
   可能覆盖 `Host`/`Accept-Encoding`/`Sec-WebSocket-Version` 等头部（代码里
   已尽力设置并注释），实际指纹需要在真机抓包确认。HTTP/1.1 的强制也无法
   复刻（iOS 无公开 API）。

## 未验证项（重要）

全部 Swift 代码在 Windows 上编写，**未经任何编译器验证**。已做的核对：
括号/圆括号配对逐文件计数一致；UI 层调用的核心层 API 逐符号交叉比对通过；
pbxproj 的 Sources 阶段与磁盘文件一一对应（脚本生成 + 自检）。

首次在 macOS 构建时最可能需要修的位置：

- `LicenseManager.swift`：CryptoKit 的 `P256.Signing.PublicKey(x963Representation:)`
  与 SPKI DER 解析部分；
- `LicenseClient.swift` / `CaptchaSolver.swift`：`SecTrustCopyCertificateChain`
  等较新的 Security API 与 `URLCredential(trust:)` 放行路径；
- 并发隔离诊断：工程已设 `SWIFT_STRICT_CONCURRENCY = minimal`，如仍出现
  Sendable/actor 隔离报错，优先看 `@MainActor` 单例与 `Task` 闭包的交互。
- 隐私清单 `GoToLibrary/PrivacyInfo.xcprivacy` 已声明 UserDefaults（CA92.1）与
  SystemBootTime（35F9.1）两个 Required Reason API，以及作为设备标识上传的
  DeviceID 类型；提交前请核对是否与本机实际使用的 API 一致。

## 纯逻辑自检用例

见 [verification/README.md](verification/README.md)：`WechatSessionCodec` 的
期望输入→输出用例表，不依赖 Xcode，可在任何平台人工核对。

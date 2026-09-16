// 对应 Android 侧 com.gotolibrary.app.AppConfig。
import Foundation
import CryptoKit
import Security
import os

/// 应用内的日志变更通知。订阅方（日志页、首页摘要）只读 AppConfig.logsText()。
/// 注意：`.goToLibraryStatusChanged` 也在这里统一定义，UI / 服务层**不要重复声明**，
/// 否则会与 Core 层出现同名扩展冲突。
extension Notification.Name {
    static let goToLibraryLogsChanged = Notification.Name("goToLibraryLogsChanged")
    static let goToLibraryStatusChanged = Notification.Name("goToLibraryStatusChanged")
}

/// 本地存储层。等价 Android 的 SharedPreferences + AndroidKeyStore：
/// 明文键值走 UserDefaults(suite)，敏感值（cookie、许可凭证）用 Keychain 里的
/// 256-bit 主密钥做 AES-GCM 加密后存 UserDefaults。
///
/// 加密失败一律 fail-closed：读不出来就返回空串并清掉脏数据，绝不返回半解密的中间态。
enum AppConfig {

    // MARK: - 常量

    static let prefsSuiteName = "gotolibrary_native"
    /// 应用内日志保留条数。Android 侧 40 条在真实排障时经常不够用（一次多阶段抢座就被冲掉）。
    static let maxLogEntries = 300

    static let modeRealtime = "realtime"
    static let modeTomorrow = "tomorrow"
    static let themeWarm = "warm"
    static let themeOcean = "ocean"
    static let themeMint = "mint"

    static let KEY_COOKIE = "cookie"
    static let KEY_MODE = "mode"
    static let KEY_TIME = "tomorrow_time"
    static let KEY_RUNNING = "running"
    static let KEY_STATUS_TITLE = "status_title"
    static let KEY_STATUS_DETAIL = "status_detail"
    static let KEY_STATUS_COUNTDOWN = "status_countdown"
    static let KEY_ROOM_ID = "room_id"
    static let KEY_ROOM_NAME = "room_name"
    static let KEY_SEATS = "preferred_seats"
    static let KEY_LOGS = "logs"
    static let KEY_SITE_ANNOUNCEMENTS = "site_announcements"
    static let KEY_GLASS_OPACITY = "glass_opacity"
    static let KEY_THEME = "theme"
    static let KEY_AVATAR_DATA = "avatar_data"
    static let KEY_DISPLAY_NAME = "display_name"
    static let KEY_UPDATE_CHECK_AT = "update_check_at"

    static let KEY_QUEUE_ADVANCE_AUTO = "queue_advance_auto"
    static let KEY_QUEUE_ADVANCE_MS = "queue_advance_ms"
    static let KEY_QUEUE_BEFORE_INTERVAL = "queue_before_interval"
    static let KEY_QUEUE_AFTER_INTERVAL = "queue_after_interval"
    static let KEY_CAPTCHA_AUTO_SOLVE = "captcha_auto_solve"
    static let KEY_AUTO_GRAB_OTHER = "auto_grab_other"
    static let KEY_KEEP_COOKIE = "keep_cookie"
    static let KEY_KEEP_COOKIE_AUTO_TOMORROW = "keep_cookie_auto_tomorrow"
    static let KEY_VENUE_AUTO_WAIT = "venue_auto_wait"
    static let KEY_PREFETCH_CAPTCHA = "prefetch_captcha"

    /// 玻璃通透度 0-100：0 最实，100 最透；作用于卡片与按键，不含底部胶囊。
    static let DEFAULT_GLASS_OPACITY = 40
    static let defaultTomorrowTime = "20:00:00"

    private static let cookieCipherKey = "cookie_cipher"
    private static let keychainService = "com.gotolibrary.nativeapp"
    private static let keychainAccount = "gotolibrary_session_key"

    private static let log = Logger(subsystem: "com.gotolibrary.nativeapp", category: "run")
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// UserDefaults 单次读改写（日志追加、状态复合写入）不是原子的，跨线程会丢条目。
    private static let lock = NSLock()
    /// 主密钥的 Keychain 读写单独一把锁，见 sessionKey()。
    private static let keychainLock = NSLock()

    private static let defaults: UserDefaults =
        UserDefaults(suiteName: prefsSuiteName) ?? .standard

    private static func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// 通知必须在主线程投递：订阅方（日志页 / 首页）收到后会直接改 SwiftUI 状态，
    /// 而 addLog 的调用方包含排队引擎的 actor 与保活循环，都在后台线程上。
    private static func postOnMain(_ name: Notification.Name) {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: name, object: nil)
        } else {
            DispatchQueue.main.async { NotificationCenter.default.post(name: name, object: nil) }
        }
    }

    // MARK: - Cookie（Keychain 主密钥加密）

    static func cookie() -> String {
        withLock { cookieUnlocked() }
    }

    @discardableResult
    static func setCookie(_ value: String) -> Bool {
        withLock { setCookieUnlocked(value) }
    }

    static func clearCookie() {
        withLock { clearCookieUnlocked() }
    }

    // lock 不可重入，以下三个是已持锁的版本，只允许上面三个包装器/彼此调用。
    private static func cookieUnlocked() -> String {
        let encrypted = defaults.string(forKey: cookieCipherKey) ?? ""
        if !encrypted.isEmpty {
            guard let plain = decrypt(encrypted) else {
                // 主密钥被换掉 / 数据被篡改：清掉脏密文，当作未登录。
                defaults.removeObject(forKey: cookieCipherKey)
                return ""
            }
            return plain
        }
        // 兼容早期明文写入（对齐 Android 的 legacy KEY_COOKIE 迁移分支）。
        let legacy = defaults.string(forKey: KEY_COOKIE) ?? ""
        guard !legacy.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        return setCookieUnlocked(legacy) ? legacy : ""
    }

    private static func setCookieUnlocked(_ value: String) -> Bool {
        guard !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            clearCookieUnlocked()
            return true
        }
        guard let encrypted = encrypt(value) else {
            clearCookieUnlocked()
            return false
        }
        defaults.set(encrypted, forKey: cookieCipherKey)
        defaults.removeObject(forKey: KEY_COOKIE)
        return true
    }

    private static func clearCookieUnlocked() {
        defaults.removeObject(forKey: KEY_COOKIE)
        defaults.removeObject(forKey: cookieCipherKey)
    }

    static func isLoggedIn() -> Bool {
        !cookie().trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - 通用加密键值（许可凭证等）

    static func secret(_ key: String) -> String {
        withLock {
            let encrypted = defaults.string(forKey: key + "_cipher") ?? ""
            guard !encrypted.isEmpty else { return "" }
            guard let plain = decrypt(encrypted) else {
                defaults.removeObject(forKey: key + "_cipher")
                return ""
            }
            return plain
        }
    }

    @discardableResult
    static func setSecret(_ key: String, _ value: String) -> Bool {
        withLock {
            guard !value.trimmingCharacters(in: .whitespaces).isEmpty else {
                defaults.removeObject(forKey: key + "_cipher")
                return true
            }
            guard let encrypted = encrypt(value.trimmingCharacters(in: .whitespaces)) else {
                return false
            }
            defaults.set(encrypted, forKey: key + "_cipher")
            return true
        }
    }

    // MARK: - 座位 / 公告

    static func selectedSeats() -> [String] {
        let raw = defaults.string(forKey: KEY_SEATS) ?? ""
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        if let data = raw.data(using: .utf8),
           let values = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            return values.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        // 旧版用竖线分隔；顺手迁移到 JSON，避免每次都要再解析一遍。
        let seats = raw.split(separator: "|").map(String.init).filter { !$0.isEmpty }
        saveSelectedSeats(seats)
        return seats
    }

    static func saveSelectedSeats(_ seats: [String]) {
        let values = seats.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let data = try? JSONSerialization.data(withJSONObject: values),
              let text = String(data: data, encoding: .utf8) else { return }
        defaults.set(text, forKey: KEY_SEATS)
    }

    static func announcements() -> [String] {
        guard let text = defaults.string(forKey: KEY_SITE_ANNOUNCEMENTS),
              let data = text.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return []
        }
        return values.compactMap { $0 as? String }
    }

    static func saveAnnouncements(_ items: [String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: items),
              let text = String(data: data, encoding: .utf8) else { return }
        defaults.set(text, forKey: KEY_SITE_ANNOUNCEMENTS)
    }

    // MARK: - 抢座参数

    /// 排队提前量 auto：交给 QueueEngine 用 NTP 校时推算；手动模式读用户值。
    static func queueAdvanceAuto() -> Bool {
        boolValue(KEY_QUEUE_ADVANCE_AUTO, fallback: true)
    }

    static func queueAdvanceMs() -> Int {
        intValue(KEY_QUEUE_ADVANCE_MS, fallback: 200)
    }

    /// 入队前高频排队请求间隔（复刻 beforeIntervalTime）。
    static func queueBeforeInterval() -> Int {
        intValue(KEY_QUEUE_BEFORE_INTERVAL, fallback: 80)
    }

    /// 入队后排队请求间隔（复刻 afterIntervalTime_v3）。
    static func queueAfterInterval() -> Int {
        intValue(KEY_QUEUE_AFTER_INTERVAL, fallback: 500)
    }

    /// 自动识别验证码。默认关闭：打码链路依赖作者服务器的账号配额，配额失效时
    /// 取图 + 换 token 只会白等十几秒，还会拖过抢座窗口。关闭后以空验证码提交。
    static func captchaAutoSolve() -> Bool {
        boolValue(KEY_CAPTCHA_AUTO_SOLVE, fallback: false)
    }

    static func setCaptchaAutoSolve(_ on: Bool) {
        defaults.set(on, forKey: KEY_CAPTCHA_AUTO_SOLVE)
    }

    /// 指定座位全部失效后是否捡漏其他空位（复刻 autoReserveOtherSwitch）。
    static func autoGrabOther() -> Bool {
        boolValue(KEY_AUTO_GRAB_OTHER, fallback: true)
    }

    /// 维持 Cookie 有效：默认开。原版默认关，用户不知晓而整夜过期。
    static func keepCookie() -> Bool {
        boolValue(KEY_KEEP_COOKIE, fallback: true)
    }

    static func setKeepCookie(_ on: Bool) {
        defaults.set(on, forKey: KEY_KEEP_COOKIE)
    }

    /// 明日预约模式下自动开启 Cookie 保活（复刻 autoKeepCookieForTomo）。
    static func keepCookieAutoTomorrow() -> Bool {
        boolValue(KEY_KEEP_COOKIE_AUTO_TOMORROW, fallback: true)
    }

    /// 场馆未开放时自动等待并重试，而不是直接判定任务失败。
    static func venueAutoWait() -> Bool {
        boolValue(KEY_VENUE_AUTO_WAIT, fallback: true)
    }

    /// 预约前预先获取并识别验证码，省去提交时约 1s 的等待。
    static func prefetchCaptcha() -> Bool {
        boolValue(KEY_PREFETCH_CAPTCHA, fallback: false)
    }

    // MARK: - 外观 / 资料

    static func glassOpacity() -> Int {
        guard defaults.object(forKey: KEY_GLASS_OPACITY) != nil else { return DEFAULT_GLASS_OPACITY }
        return min(100, max(0, defaults.integer(forKey: KEY_GLASS_OPACITY)))
    }

    static func setGlassOpacity(_ value: Int) {
        defaults.set(min(100, max(0, value)), forKey: KEY_GLASS_OPACITY)
    }

    static func theme() -> String {
        let value = (defaults.string(forKey: KEY_THEME) ?? "").trimmingCharacters(in: .whitespaces)
        switch value {
        case themeOcean, themeMint, themeWarm: return value
        default: return themeWarm
        }
    }

    static func setTheme(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces).lowercased()
        switch trimmed {
        case themeOcean, themeMint, themeWarm: defaults.set(trimmed, forKey: KEY_THEME)
        default: defaults.set(themeWarm, forKey: KEY_THEME)
        }
    }

    static func displayName() -> String {
        defaults.string(forKey: KEY_DISPLAY_NAME) ?? ""
    }

    static func setDisplayName(_ value: String) {
        defaults.set(value, forKey: KEY_DISPLAY_NAME)
    }

    static func avatarData() -> Data? {
        defaults.data(forKey: KEY_AVATAR_DATA)
    }

    static func setAvatarData(_ data: Data?) {
        if let data { defaults.set(data, forKey: KEY_AVATAR_DATA) }
        else { defaults.removeObject(forKey: KEY_AVATAR_DATA) }
    }

    static func lastUpdateCheckAt() -> Date? {
        guard defaults.object(forKey: KEY_UPDATE_CHECK_AT) != nil else { return nil }
        let stamp = defaults.double(forKey: KEY_UPDATE_CHECK_AT)
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    static func setLastUpdateCheckAt(_ date: Date) {
        defaults.set(date.timeIntervalSince1970, forKey: KEY_UPDATE_CHECK_AT)
    }

    // MARK: - 任务状态

    static func roomId() -> Int {
        intValue(KEY_ROOM_ID, fallback: 0)
    }

    static func setRoomId(_ value: Int) {
        defaults.set(value, forKey: KEY_ROOM_ID)
    }

    static func roomName() -> String {
        defaults.string(forKey: KEY_ROOM_NAME) ?? ""
    }

    static func setRoomName(_ value: String) {
        defaults.set(value, forKey: KEY_ROOM_NAME)
    }

    static func mode() -> String {
        let value = defaults.string(forKey: KEY_MODE) ?? ""
        return value == modeTomorrow ? modeTomorrow : modeRealtime
    }

    static func setMode(_ value: String) {
        defaults.set(value == modeTomorrow ? modeTomorrow : modeRealtime, forKey: KEY_MODE)
    }

    static func tomorrowTime() -> String {
        let value = (defaults.string(forKey: KEY_TIME) ?? "").trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? defaultTomorrowTime : value
    }

    static func setTomorrowTime(_ value: String) {
        defaults.set(value, forKey: KEY_TIME)
    }

    static func running() -> Bool {
        boolValue(KEY_RUNNING, fallback: false)
    }

    static func setRunning(_ value: Bool) {
        defaults.set(value, forKey: KEY_RUNNING)
    }

    static func status() -> (title: String, detail: String, countdownMs: Int) {
        (title: defaults.string(forKey: KEY_STATUS_TITLE) ?? "",
         detail: defaults.string(forKey: KEY_STATUS_DETAIL) ?? "",
         countdownMs: intValue(KEY_STATUS_COUNTDOWN, fallback: 0))
    }

    static func setStatus(title: String, detail: String, countdownMs: Int) {
        withLock {
            defaults.set(title, forKey: KEY_STATUS_TITLE)
            defaults.set(detail, forKey: KEY_STATUS_DETAIL)
            defaults.set(countdownMs, forKey: KEY_STATUS_COUNTDOWN)
        }
    }

    // MARK: - 日志

    /// 追加一条运行日志。除写存储外必须同时镜像到 os_log：
    /// 真机排障时应用内日志页经常取不出来（要连 Xcode / 控制台），
    /// 没有这一行就只能看到网络层日志，业务侧发生了什么完全看不到。
    static func addLog(_ message: String) {
        log.info("\(message, privacy: .public)")
        withLock {
            var entries = storedLogs()
            entries.insert(timeFormatter.string(from: Date()) + "  " + message, at: 0)
            if entries.count > maxLogEntries {
                entries.removeSubrange(maxLogEntries..<entries.count)
            }
            if let data = try? JSONSerialization.data(withJSONObject: entries),
               let text = String(data: data, encoding: .utf8) {
                defaults.set(text, forKey: KEY_LOGS)
            }
        }
        postOnMain(.goToLibraryLogsChanged)
    }

    static func logsText() -> String {
        let entries = withLock { storedLogs() }
        return entries.isEmpty ? "暂无运行记录" : entries.joined(separator: "\n")
    }

    static func clearLogs() {
        withLock { defaults.removeObject(forKey: KEY_LOGS) }
        postOnMain(.goToLibraryLogsChanged)
    }

    private static func storedLogs() -> [String] {
        guard let text = defaults.string(forKey: KEY_LOGS),
              let data = text.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return []
        }
        return values.compactMap { $0 as? String }
    }

    // MARK: - 键值读取辅助

    private static func boolValue(_ key: String, fallback: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }

    private static func intValue(_ key: String, fallback: Int) -> Int {
        if let number = defaults.object(forKey: key) as? NSNumber { return number.intValue }
        guard let text = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespaces),
              let value = Int(text) else { return fallback }
        return value
    }

    // MARK: - AES-GCM

    /// 密文格式：base64(nonce ‖ ciphertext ‖ tag)，即 CryptoKit 的 combined 表示。
    /// Android 侧把 IV 单独存一个键，iOS 没有这个必要——combined 里自带 nonce，
    /// 反而少一处"IV 与密文不同源"的失败面。
    private static func encrypt(_ plaintext: String) -> String? {
        guard let key = sessionKey() else { return nil }
        guard let sealed = try? AES.GCM.seal(Data(plaintext.utf8), using: key) else { return nil }
        return sealed.combined?.base64EncodedString()
    }

    private static func decrypt(_ base64: String) -> String? {
        guard let key = sessionKey() else { return nil }
        guard let data = Data(base64Encoded: base64) else { return nil }
        guard let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        guard let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    /// 首次访问生成 256-bit 随机主密钥存 Keychain。
    /// `AfterFirstUnlockThisDeviceOnly`：后台保活（锁屏后仍在跑）必须能读到密钥，
    /// 所以不能用 WhenUnlocked；ThisDeviceOnly + 不同步 iCloud，密钥不离开本机。
    ///
    /// 单独的 keychainLock：本方法会在 `lock` 已持有的情况下被调用（加解密路径），
    /// 用它把"读不到就生成"做成单飞，避免两个线程同时生成导致其中一个拿到已被
    /// 覆盖删除的旧密钥。锁序恒为 lock → keychainLock，不会反向嵌套。
    private static func sessionKey() -> SymmetricKey? {
        keychainLock.lock()
        defer { keychainLock.unlock() }
        if let existing = loadKeyData() { return SymmetricKey(data: existing) }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        let data = Data(bytes)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        SecItemDelete(query as CFDictionary)
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { return nil }
        return SymmetricKey(data: data)
    }

    private static func loadKeyData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == 32 else { return nil }
        return data
    }
}

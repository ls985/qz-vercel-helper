// 对应 Android 侧 com.gotolibrary.app.LicenseManager。
import Foundation
import CryptoKit
import UIKit
import os

enum LicenseState {
    /// 凭证有效且在复验窗口内。
    case active
    /// 从未激活。
    case none
    /// 会员到期。
    case expired
    /// 超过复验窗口（默认 72 小时）未联网复验。
    case stale
    /// 客户端被改动。见 currentState() 里关于 iOS 平台差异的说明。
    case tampered
    /// 检测到越狱环境。
    case hostile
}

/// 设备激活会员的本地校验核心。
///
/// 信任锚只有一样东西：内嵌的 `BuildConfig.licensePublicKey`。会员状态永远来自
/// 服务器签名的凭证，本地不落任何明文"已激活"布尔值；凭证缓存走 AppConfig 的
/// Keychain 加密通道，验不过一律视为未激活。
enum LicenseManager {

    /// 复验窗口，与服务端 lib/device-store.js 的 GRACE_MS 保持一致。
    static let refreshWindow: TimeInterval = 72 * 3600
    /// 凭证主动刷新间隔：有效期内每 24 小时静默续签一次。
    static let refreshInterval: TimeInterval = 24 * 3600

    private static let tokenKey = "license_token"
    private static let keyMaxServerTime = "license_max_server_time"
    private static let keyAnchorUptime = "license_anchor_realtime"
    private static let keyLastRefresh = "license_last_refresh_ms"

    private static let log = Logger(subsystem: "com.gotolibrary.nativeapp", category: "license")
    private static let defaults = UserDefaults(suiteName: AppConfig.prefsSuiteName) ?? .standard

    // MARK: - 设备身份

    /// 本机指纹：identifierForVendor 的 SHA-256 小写 hex，与服务端激活时上传的值一致。
    /// 注意 uuidString 是原样参与哈希的（大写），任何时候都不要"顺手"改成小写再算，
    /// 否则已激活设备会全部变成未激活。
    static func deviceFingerprint() -> String {
        guard let vendor = UIDevice.current.identifierForVendor?.uuidString,
              !vendor.isEmpty else {
            // 取不到 IDFV 时返回空串：激活接口会拒绝非 64 位 hex，比伪造一个假指纹安全。
            return ""
        }
        let digest = SHA256.hash(data: Data(vendor.trimmingCharacters(in: .whitespaces).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 激活界面展示用的短码（指纹前 16 位，4 位一组）。
    static func displayDeviceCode() -> String {
        let fingerprint = deviceFingerprint()
        guard fingerprint.count >= 16 else { return "无法生成，请重启应用" }
        let head = Array(fingerprint.prefix(16))
        var groups: [String] = []
        for start in stride(from: 0, to: 16, by: 4) {
            groups.append(String(head[start..<(start + 4)]))
        }
        return groups.joined(separator: "-")
    }

    // MARK: - 状态

    /// 平台差异：iOS 没有 Root 与"重打包"的概念 —— 应用签名由 App Store / 描述文件
    /// 在安装时校验，运行期读不到可比的签名摘要，所以 tampered 分支在这里不可达，
    /// 能做的只有越狱探测（归到 hostile）。保留 tampered 这个 case 是为了 UI 文案
    /// 与 Android 端对齐；真实签名校验责任在系统，不在应用。
    static func currentState() -> LicenseState {
        if isHostileEnvironment() { return .hostile }
        let token = AppConfig.secret(tokenKey)
        guard !token.isEmpty else { return .none }
        guard let payload = verifyToken() else { return .none }

        let now = trustedNow()
        let expiresAt = parseTime(payload["expiresAt"] as? String)
        let refreshNotAfter = parseTime(payload["refreshNotAfter"] as? String)
        if now > refreshNotAfter { return .stale }
        if expiresAt <= 0 || now >= expiresAt { return .expired }
        return .active
    }

    static func isUsable() -> Bool {
        currentState() == .active
    }

    /// 增值接口（打码中转等）的设备鉴权：返回当前有效凭证，无有效凭证时返回 nil。
    static func entitlementToken() -> String? {
        guard verifyToken() != nil else { return nil }
        let token = AppConfig.secret(tokenKey)
        return token.isEmpty ? nil : token
    }

    /// 会员到期时刻（Unix 秒）。0 表示未知。
    static func membershipExpiresAt() -> TimeInterval {
        guard let payload = verifyToken() else { return 0 }
        return parseTime(payload["expiresAt"] as? String)
    }

    /// 激活成功或凭证刷新成功后调用；token 必须验签通过才落地。
    @discardableResult
    static func storeVerifiedToken(_ token: String, serverTime: String) -> Bool {
        AppConfig.setSecret(tokenKey, token)
        guard verifyToken() != nil else {
            AppConfig.setSecret(tokenKey, "")
            return false
        }
        let serverNow = parseTime(serverTime)
        if serverNow > 0 {
            let maxSeen = max(defaults.double(forKey: keyMaxServerTime), serverNow)
            defaults.set(maxSeen, forKey: keyMaxServerTime)
            defaults.set(ProcessInfo.processInfo.systemUptime, forKey: keyAnchorUptime)
        }
        defaults.set(Date().timeIntervalSince1970, forKey: keyLastRefresh)
        return true
    }

    /// 激活 / 续签响应的解析结果。
    enum ResponseResult {
        /// 凭证已验签通过并落地。
        case stored
        /// 响应体里没有可用的 token（服务端返回了别的东西）。
        case invalidPayload
        /// 有 token 但验签或设备绑定没通过，脏凭证已被清掉。
        case rejected
    }

    /// 解析 `{"token": "...", "serverTime": "..."}` 并落地。门禁页与静默续签共用，
    /// 避免两处各写一遍解析、对"缺 token"和"验签失败"给出不同处理。
    static func acceptResponse(_ body: String) -> ResponseResult {
        guard let data = body.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = json["token"] as? String, !token.isEmpty else {
            return .invalidPayload
        }
        return storeVerifiedToken(token, serverTime: json["serverTime"] as? String ?? "")
            ? .stored : .rejected
    }

    static func clearLicense() {
        AppConfig.setSecret(tokenKey, "")
        defaults.removeObject(forKey: keyMaxServerTime)
        defaults.removeObject(forKey: keyAnchorUptime)
        defaults.removeObject(forKey: keyLastRefresh)
    }

    static func shouldRefresh() -> Bool {
        let last = defaults.double(forKey: keyLastRefresh)
        guard last > 0 else { return true }
        return Date().timeIntervalSince1970 - last >= refreshInterval
    }

    static func lastRefreshAt() -> Date? {
        let last = defaults.double(forKey: keyLastRefresh)
        return last > 0 ? Date(timeIntervalSince1970: last) : nil
    }

    // MARK: - 信任时钟

    /// 信任时钟：系统时间可被用户回拨，所以以"见过的最大服务器时间 + 开机以来的流逝"
    /// 为下限。`systemUptime` 相当于 Android 的 elapsedRealtime，但它在重启后清零 ——
    /// 那时锚点漂移为负，直接取 maxSeen 兜底（与 Android 的 Math.max(drift, 0) 同义）。
    private static func trustedNow() -> TimeInterval {
        let wallNow = Date().timeIntervalSince1970
        let maxSeen = defaults.double(forKey: keyMaxServerTime)
        guard maxSeen > 0 else { return wallNow }
        let anchor = defaults.double(forKey: keyAnchorUptime)
        let drift = anchor > 0 ? ProcessInfo.processInfo.systemUptime - anchor : 0
        return max(wallNow, maxSeen + max(drift, 0))
    }

    private static func parseTime(_ iso: String?) -> TimeInterval {
        guard let iso, !iso.isEmpty else { return 0 }
        if let date = iso8601WithFraction.date(from: iso) { return date.timeIntervalSince1970 }
        if let date = iso8601.date(from: iso) { return date.timeIntervalSince1970 }
        return 0
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let iso8601WithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: - 凭证验签

    /// 验签 + 设备绑定校验；任何一步失败返回 nil（fail-closed）。
    ///
    /// 凭证格式 `<base64url(payloadJSON)>.<base64url(DER 签名)>`，
    /// 验签对象是**解码后的 payload 原始字节**（不是 base64 文本）。
    private static func verifyToken() -> [String: Any]? {
        let publicKeyBase64 = BuildConfig.licensePublicKey.trimmingCharacters(in: .whitespaces)
        guard !publicKeyBase64.isEmpty else {
            log.warning("许可公钥未配置，拒绝一切凭证")
            return nil
        }
        let token = AppConfig.secret(tokenKey)
        guard !token.isEmpty else { return nil }
        guard let separator = token.firstIndex(of: "."),
              separator != token.startIndex,
              token.index(after: separator) != token.endIndex else { return nil }
        let encodedPayload = String(token[token.startIndex..<separator])
        let encodedSignature = String(token[token.index(after: separator)...])

        guard let payloadBytes = base64URLDecode(encodedPayload),
              let signatureBytes = base64URLDecode(encodedSignature),
              let spki = Data(base64Encoded: publicKeyBase64),
              let x963 = x963PublicKey(fromSPKI: spki),
              let publicKey = try? P256.Signing.PublicKey(x963Representation: x963),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureBytes),
              publicKey.isValidSignature(signature, for: payloadBytes) else {
            log.warning("凭证校验失败")
            return nil
        }
        guard let payload = (try? JSONSerialization.jsonObject(with: payloadBytes)) as? [String: Any],
              deviceFingerprint() == (payload["deviceId"] as? String) else {
            log.warning("凭证设备绑定不匹配")
            return nil
        }
        return payload
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var text = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = text.count % 4
        if remainder > 0 { text += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: text)
    }

    /// SPKI（`SubjectPublicKeyInfo`）→ x9.63，做**真实 DER 解析**而不是按长度猜偏移：
    ///
    ///     SEQUENCE {                       -- 外层，P-256 时共 91 字节
    ///       SEQUENCE {                     -- AlgorithmIdentifier
    ///         OID 1.2.840.10045.2.1        -- ecPublicKey
    ///         OID 1.2.840.10045.3.1.7      -- prime256v1
    ///       }
    ///       BIT STRING { 00 04 X(32) Y(32) }
    ///     }
    ///
    /// 只有两条 OID 都对上、BIT STRING 的未用位为 0 且点压缩标记是 0x04 时才返回那
    /// 65 字节；任何一处不符返回 nil —— 公钥被替换成别的曲线/别的结构时必须拒绝，
    /// 不能"取尾巴 65 字节试试看"。
    private static func x963PublicKey(fromSPKI der: Data) -> Data? {
        var index = der.startIndex
        guard let body = readDER(der, &index, tag: 0x30) else { return nil }
        var bodyIndex = body.startIndex
        guard let algorithm = readDER(body, &bodyIndex, tag: 0x30) else { return nil }
        var algorithmIndex = algorithm.startIndex
        guard let ecPublicKeyOID = readDER(algorithm, &algorithmIndex, tag: 0x06),
              let prime256v1OID = readDER(algorithm, &algorithmIndex, tag: 0x06) else { return nil }
        guard ecPublicKeyOID == Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]),
              prime256v1OID == Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]) else {
            return nil
        }
        guard let bitString = readDER(body, &bodyIndex, tag: 0x03),
              bitString.count == 66,
              bitString[bitString.startIndex] == 0x00 else { return nil }
        let point = Data(bitString.dropFirst())
        guard point.count == 65, point[point.startIndex] == 0x04 else { return nil }
        return point
    }

    /// 读取一个 DER TLV，返回内容（不含 tag 与长度），并把 `index` 推到下一个 TLV。
    private static func readDER(_ data: Data, _ index: inout Data.Index,
                                tag expected: UInt8) -> Data? {
        guard index < data.endIndex, data[index] == expected else { return nil }
        index = data.index(after: index)
        guard index < data.endIndex else { return nil }
        let firstLengthByte = data[index]
        index = data.index(after: index)
        var length = 0
        if firstLengthByte & 0x80 == 0 {
            length = Int(firstLengthByte)
        } else {
            let byteCount = Int(firstLengthByte & 0x7F)
            guard byteCount > 0, byteCount <= 4,
                  data.distance(from: index, to: data.endIndex) >= byteCount else { return nil }
            for _ in 0..<byteCount {
                length = length << 8 | Int(data[index])
                index = data.index(after: index)
            }
        }
        guard data.distance(from: index, to: data.endIndex) >= length else { return nil }
        let end = data.index(index, offsetBy: length)
        defer { index = end }
        return Data(data[index..<end])
    }

    // MARK: - 环境检测

    /// iOS 上的 best-effort 越狱探测。
    ///
    /// 目的是抬高自动化修改的门槛，不是对抗专业逆向 —— 越狱设备可以通过各种
    /// hook 绕过路径探测。**真实签名校验由 App Store / 描述文件承担**，
    /// 应用层不做也无法做代码签名自校验（这是与 Android 侧最大的差异：
    /// Android 有 APK 签名摘要可比，iOS 运行期拿不到可依赖的等价物）。
    static func isHostileEnvironment() -> Bool {
        let paths = ["/Applications/Cydia.app", "/bin/bash", "/usr/sbin/sshd",
                     "/etc/apt", "/private/var/lib/apt"]
        for path in paths where FileManager.default.fileExists(atPath: path) {
            return true
        }
        // canOpenURL 必须在主线程调用；非主线程时跳过这一项（路径探测已覆盖同一类设备，
        // 不值得为了它阻塞或死锁）。另外它需要 Info.plist 的 LSApplicationQueriesSchemes
        // 声明 cydia，否则恒为 false。路径检查不受此限制。
        if Thread.isMainThread, let url = URL(string: "cydia://package/com.example.package") {
            if UIApplication.shared.canOpenURL(url) { return true }
        }
        return false
    }
}

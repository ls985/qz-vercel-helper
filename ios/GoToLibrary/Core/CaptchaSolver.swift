// 对应 Android 侧 com.gotolibrary.app.CaptchaSolver。
import Foundation
import os

struct SolveResult {
    let code: String
    let uniqueCode: String?
}

/// 验证码识别：经主站中转（POST solve / refund），以设备会员凭证鉴权。
///
/// 打码平台的 token 与账号信息只保存在服务端，客户端不内嵌任何签名密钥，
/// 也不与打码平台直接通信。识别结果是否可用由调用方按 4 位正则判定，
/// 判错/格式不对时由调用方负责退码。
final class CaptchaSolver: @unchecked Sendable {

    /// 与旧版一致的识别类型：4 位字母数字验证码（服务端固定使用）。
    static let codePattern = "^[A-Za-z0-9]{4}$"

    private static let codeRegex = try? NSRegularExpression(pattern: codePattern)
    private static let log = Logger(subsystem: "com.gotolibrary.nativeapp", category: "captcha")

    private let lock = NSLock()
    private var storedLeftCredits = -1
    private var storedTokenUnavailable = false
    /// 与许可服务共用同一个 SPKI 固定的会话（同一台服务器、同一张自签证书）。
    private let session: URLSession

    init() {
        session = LicenseClient.pinnedSession()
    }

    static func isPlausible(_ answer: String?) -> Bool {
        guard let answer, let regex = codeRegex else { return false }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        // Java 用的是 matcher.matches()（整串匹配），而 pattern 本身没有 ^$，
        // 所以这里必须要求匹配区间覆盖整串，否则 "AB12CD" 也会被判为合格。
        guard let match = regex.firstMatch(in: trimmed, options: [], range: range) else { return false }
        return match.range == range
    }

    /// 剩余次数；-1 表示未知。
    var leftCredits: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedLeftCredits
    }

    /// 打码服务已确定性拒绝本设备；此时不应再重试。
    var isTokenUnavailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedTokenUnavailable
    }

    /// 识别一张验证码。返回 nil 表示识别失败（调用方自行决定跳过该座位或回退）。
    ///
    /// 配额失效时**不再重试**：device_forbidden / captcha_not_configured 说明这台的
    /// 凭证已不可用，继续取图 + 换 token 只会白等十几秒，还会拖过抢座窗口。
    func solve(imageBase64: String) async -> SolveResult? {
        guard !imageBase64.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if isTokenUnavailable { return nil }
        guard let token = LicenseManager.entitlementToken() else {
            CaptchaSolver.log.warning("无有效设备会员凭证，跳过自动打码")
            markTokenUnavailable()
            return nil
        }
        let response = await post(path: "solve", payload: ["image": imageBase64], token: token)
        guard let response else { return nil }
        if response["error"] != nil {
            let error = response["error"] as? String ?? ""
            if error == "device_forbidden" || error == "captcha_not_configured" {
                markTokenUnavailable()
            }
            let message = response["message"] as? String ?? error
            CaptchaSolver.log.warning("打码中转拒绝: \(message, privacy: .public)")
            return nil
        }
        let answer = response["code"] as? String ?? ""
        guard CaptchaSolver.isPlausible(answer) else {
            CaptchaSolver.log.warning("识别结果不合法，按失败处理")
            return nil
        }
        lock.lock()
        storedLeftCredits = CaptchaSolver.intValue(response["leftCredits"]) ?? -1
        lock.unlock()
        return SolveResult(code: answer, uniqueCode: response["uniqueCode"] as? String)
    }

    /// 识别结果无效（不是 4 位）或被判错时退分。
    func refund(uniqueCode: String?) async {
        guard let uniqueCode else { return }
        let trimmed = uniqueCode.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isTokenUnavailable else { return }
        guard let token = LicenseManager.entitlementToken() else { return }
        _ = await post(path: "refund", payload: ["uniqueCode": trimmed], token: token)
    }

    // MARK: - 内部

    private func markTokenUnavailable() {
        lock.lock()
        storedTokenUnavailable = true
        lock.unlock()
    }

    /// 不抛：solve / refund 的契约就是"失败返回 nil / 静默结束"。
    private func post(path: String, payload: [String: Any], token: String) async -> [String: Any]? {
        guard let url = LicenseClient.requestURL(base: BuildConfig.captchaAPIBase, path: path) else {
            CaptchaSolver.log.warning("打码服务未配置")
            return nil
        }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(LicenseManager.deviceFingerprint(), forHTTPHeaderField: "X-Device-Id")
        request.setValue(token, forHTTPHeaderField: "X-Device-Token")
        // 识别是慢操作：请求级超时覆盖共享会话的 12s 默认值，避免识别还在跑就被掐断。
        request.timeoutInterval = 30
        request.httpBody = body

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data, encoding: .utf8) ?? ""
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            guard var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                CaptchaSolver.log.warning("打码响应解析失败")
                return nil
            }
            if status != 200, json["error"] == nil {
                json["error"] = "http_\(status)"
            }
            return json
        } catch is CancellationError {
            // 本方法契约是不抛，取消时立即返回 nil；不进入任何重试循环，
            // 调用方靠 Task.isCancelled 自己退出。
            return nil
        } catch {
            CaptchaSolver.log.warning("打码调用异常: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }
}

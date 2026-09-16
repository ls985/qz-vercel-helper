// 对应 Android 侧 com.gotolibrary.app.LicenseClient。
import Foundation
import CryptoKit
import os

enum LicenseClientError: LocalizedError {
    /// 基址不可用或非 https（未显式放行明文时）。文案对齐 Android。
    case notConfigured
    /// 网络层失败且退避重试已用尽。
    case network
    /// 服务端返回的非 200 文案。
    case server(String)
    /// 响应体不是合法 JSON。
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "许可服务未配置"
        case .network: return "网络请求失败，请检查网络后重试"
        case .server(let message): return message
        case .invalidResponse: return "响应解析失败"
        }
    }
}

/// 激活（`activate`）与凭证续签（`entitlement`）接口客户端。
///
/// 信任锚只有 SPKI 指纹本身：许可服务走 IP 直连 + 自签证书，没有 CA 链和域名可依赖，
/// 主机名校验由"证书公钥必须命中指纹"替代 —— 命中即真服务器，否则一律拒绝。
/// 服务器换证书时必须同步更新 `BuildConfig.licenseSPKIPins` 并重新发版。
final class LicenseClient {

    /// 大陆链路对自签 IP 的 TLS 重置是按连接随机的，换连接立刻重试常能通过。
    private static let retryDelays: [TimeInterval] = [0.8, 2.5, 5.0]
    private static let log = Logger(subsystem: "com.gotolibrary.nativeapp", category: "license")

    private let session: URLSession

    init() {
        session = LicenseClient.pinnedSession()
    }

    /// 打码中转与激活同用一台服务器、同一套自签证书，信任锚复用这里的 SPKI 锁定。
    static func pinnedSession() -> URLSession {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if let existing = sharedSession { return existing }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 24
        // 指纹留空时退回系统校验（对齐 Android：CERT_SPKI_SHA256 为空就不装 pinning）。
        let session = BuildConfig.licenseSPKIPins.isEmpty
            ? URLSession(configuration: configuration)
            : URLSession(configuration: configuration,
                         delegate: SPKIPinningDelegate(),
                         delegateQueue: nil)
        sharedSession = session
        return session
    }

    private static let sessionLock = NSLock()
    private static var sharedSession: URLSession?

    /// 拼接基址 + 路径并做协议校验。默认强制 https；仅当 `BuildConfig.licenseAllowHTTP`
    /// 为真（debug 联调）才放行明文本机地址。
    static func requestURL(base: String, path: String) -> URL? {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed + path),
              let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty else { return nil }
        if scheme == "https" { return url }
        if scheme == "http", BuildConfig.licenseAllowHTTP { return url }
        return nil
    }

    // MARK: - 接口

    /// 激活。成功时返回响应 body 原文（调用方负责解析 token 与 serverTime）。
    func activate(code: String, deviceId: String, deviceName: String) async throws -> String {
        try await post("activate", ["code": code.trimmingCharacters(in: .whitespaces),
                                    "deviceId": deviceId,
                                    "deviceName": deviceName])
    }

    func refreshEntitlement(deviceId: String, nonce: String) async throws -> String {
        try await post("entitlement", ["deviceId": deviceId, "nonce": nonce])
    }

    // MARK: - 传输

    private func post(_ path: String, _ payload: [String: Any]) async throws -> String {
        guard let url = LicenseClient.requestURL(base: BuildConfig.licenseAPIBase, path: path) else {
            throw LicenseClientError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw LicenseClientError.invalidResponse
        }
        request.httpBody = body

        var lastError: Error = LicenseClientError.network
        for attempt in 0...LicenseClient.retryDelays.count {
            let result: (Data, URLResponse)
            do {
                result = try await session.data(for: request)
            } catch let error as CancellationError {
                // 取消必须向上传播，不能退化成"重试下一轮"。
                throw error
            } catch {
                LicenseClient.log.error("请求失败 \(url.host ?? "", privacy: .public): \(String(describing: type(of: error)), privacy: .public)")
                lastError = LicenseClientError.network
                if attempt < LicenseClient.retryDelays.count {
                    let delay = LicenseClient.retryDelays[attempt]
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                continue
            }

            let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                // 只有服务端明确给了 message 才用它；解析不出来就当响应不可用。
                guard let json = (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any] else {
                    throw LicenseClientError.invalidResponse
                }
                throw LicenseClientError.server(json["message"] as? String ?? "请求失败（\(status)）")
            }
            return String(data: result.0, encoding: .utf8) ?? ""
        }
        throw lastError
    }

    // MARK: - 证书固定

    /// 自签 IP 证书专用信任判定：不做系统 CA 与主机名校验，只认 SPKI 指纹。
    /// 命中即放行 —— 主机名校验在这里被"公钥必须命中指纹"替代。
    static func trustMatchesPin(_ trust: SecTrust) -> Bool {
        guard !BuildConfig.licenseSPKIPins.isEmpty else { return false }
        let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
        guard !certificates.isEmpty else {
            LicenseClient.log.error("空证书链")
            return false
        }
        for certificate in certificates {
            if let spki = spkiBytes(fromCertificateDER: SecCertificateCopyData(certificate) as Data) {
                let digest = SHA256.hash(data: spki)
                let pin = "sha256/" + Data(digest).base64EncodedString()
                if BuildConfig.licenseSPKIPins.contains(pin) { return true }
            }
        }
        LicenseClient.log.error("证书指纹不匹配")
        return false
    }

    /// 取证书里的 SubjectPublicKeyInfo 原始 DER。
    ///
    /// 不用 `SecKeyCopyExternalRepresentation`：它给的是 x9.63（EC）或 PKCS#1（RSA），
    /// 而服务端与 Android 端算的都是 `PublicKey.getEncoded()`，即带算法标识的
    /// SubjectPublicKeyInfo。两者摘要不同，所以这里从证书 DER 里把该字段原样切出来。
    static func spkiBytes(fromCertificateDER der: Data) -> Data? {
        var index = der.startIndex
        guard let certificate = readTLV(der, &index), certificate.full.first == 0x30 else { return nil }
        var certificateCursor = certificate.content.startIndex
        guard let tbs = readTLV(certificate.content, &certificateCursor),
              tbs.full.first == 0x30 else { return nil }
        var cursor = tbs.content.startIndex
        // [0] version 是可选字段（v3 才有），出现时先跳过。
        if let tag = peekTag(tbs.content, cursor), tag == 0xA0 {
            _ = readTLV(tbs.content, &cursor)
        }
        // serialNumber / signature / issuer / validity / subject
        guard skipTLV(tbs.content, &cursor, expecting: 0x02),
              skipTLV(tbs.content, &cursor, expecting: 0x30),
              skipTLV(tbs.content, &cursor, expecting: 0x30),
              skipTLV(tbs.content, &cursor, expecting: 0x30),
              skipTLV(tbs.content, &cursor, expecting: 0x30),
              let spki = readTLV(tbs.content, &cursor),
              spki.full.first == 0x30 else { return nil }
        return spki.full
    }

    private static func peekTag(_ data: Data, _ index: Data.Index) -> UInt8? {
        index < data.endIndex ? data[index] : nil
    }

    private static func skipTLV(_ data: Data, _ index: inout Data.Index, expecting tag: UInt8) -> Bool {
        guard let element = readTLV(data, &index) else { return false }
        return element.full.first == tag
    }

    /// 读取一个 DER TLV，返回完整字节与内容字节，并把 `index` 推到下一个 TLV。
    private static func readTLV(_ data: Data, _ index: inout Data.Index)
        -> (full: Data, content: Data)? {
        guard index < data.endIndex else { return nil }
        let start = index
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
        let contentStart = index
        let end = data.index(index, offsetBy: length)
        index = end
        return (full: Data(data[start..<end]), content: Data(data[contentStart..<end]))
    }

    /// URLSession 的 server-trust 挑战：命中 SPKI 指纹就交回自己构造的 trust 凭据，
    /// 否则直接取消。这里**不做** SecTrustEvaluateWithError —— 自签 IP 证书本来就
    /// 过不了系统校验，能信它的唯一理由是公钥指纹对上。
    private final class SPKIPinningDelegate: NSObject, URLSessionDelegate {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                                      URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod
                    == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            if LicenseClient.trustMatchesPin(trust) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
}

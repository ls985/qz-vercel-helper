// 对应 Android 侧 com.gotolibrary.app.WechatSessionCodec。
import Foundation

/// 用户从微信授权页复制回来的回调链接。
struct SessionRequest {
    let baseURL: String
    let authURL: String
}

enum SessionCodecError: LocalizedError {
    case invalidURL
    case notLibraryHost
    case requiresHTTPS
    case badEncoding
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "请输入有效的微信回调链接"
        case .notLibraryHost: return "这不是有效的图书馆微信授权回调链接"
        case .requiresHTTPS: return "直接授权链接必须使用 HTTPS"
        case .badEncoding: return "微信回调链接编码无效"
        case .encodeFailed: return "微信回调链接编码失败"
        }
    }
}

enum WechatSessionCodec {

    /// 上游只认这两个域；别的一律拒绝，避免把回调链接送到钓鱼域。
    private static let allowedHosts: Set<String> = ["wechat.v2.traceint.com", "web.traceint.com"]

    /// 解析微信回调链接。
    ///
    /// 用户粘贴的内容通常是"整段聊天记录"或带转义的 JSON 片段，所以先剥掉首尾空白与
    /// 反斜杠，再取**最后一个** http(s) 起点（前面的可能是文案里的示例链接）。
    static func parse(_ callbackURL: String) throws -> SessionRequest {
        let cleaned = extractLastCallbackURL(callbackURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: ""))
        guard let components = URLComponents(string: cleaned) else { throw SessionCodecError.invalidURL }
        guard let rawHost = components.host, let scheme = components.scheme else {
            throw SessionCodecError.invalidURL
        }
        let host = rawHost.lowercased()
        guard allowedHosts.contains(host) else { throw SessionCodecError.notLibraryHost }

        let baseURL = "https://" + host + "/"
        // Java 的 `new URI(...)` 会拒绝不合法的 % 转义（URISyntaxException →
        // "请输入有效的微信回调链接"），而 URLComponents 不校验转义合法性。
        // 微信会截断过长链接，用户粘回来的串常常就是断在 %XX 中间，这里必须显式补上，
        // 否则会走到下面的解码分支报出另一种文案。
        guard hasValidPercentEscapes(components.percentEncodedQuery) else {
            throw SessionCodecError.invalidURL
        }
        let query = try queryParameters(components.percentEncodedQuery)
        let code = (query["code"] ?? "").trimmingCharacters(in: .whitespaces)
        if code.isEmpty {
            guard scheme.lowercased() == "https" else { throw SessionCodecError.requiresHTTPS }
            // 用户已经拿到过授权跳转结果，直接原样转发给服务端换取会话。
            return SessionRequest(baseURL: baseURL, authURL: cleaned)
        }
        let rawState = (query["state"] ?? "").trimmingCharacters(in: .whitespaces)
        let state = rawState.isEmpty ? "1" : rawState
        let target = "https://" + host
        let authURL = target + "/index.php/urlNew/auth.html?r="
            + formEncode(target + "/web/index.html")
            + "&code=" + formEncode(code)
            + "&state=" + formEncode(state)
        // Java 的 URLEncoder 保证输出纯 ASCII；出现非 ASCII 说明编码路径写错了，
        // 这种链接上游会当成未编码处理并直接报错，宁可提前失败。
        guard authURL.allSatisfy({ $0.isASCII }) else { throw SessionCodecError.encodeFailed }
        return SessionRequest(baseURL: baseURL, authURL: authURL)
    }

    /// 把应答里的 Set-Cookie 合并进 cookie 表：只取第一段 name=value，同名覆盖。
    /// 保序由调用方（TraceintClient）用有序表保证，这里不关心顺序。
    static func mergeSetCookies(_ jar: inout [String: String], _ setCookieHeaders: [String]) {
        for header in setCookieHeaders {
            let segment = header.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? ""
            let first = segment.trimmingCharacters(in: .whitespaces)
            guard let separator = first.firstIndex(of: "=") else { continue }
            let name = String(first[first.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(first[first.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            jar[name] = value
        }
    }

    // MARK: - 内部

    private static func extractLastCallbackURL(_ value: String) -> String {
        let lower = value.lowercased()
        let httpIndex = lower.range(of: "http://", options: .backwards)?.lowerBound
        let httpsIndex = lower.range(of: "https://", options: .backwards)?.lowerBound
        let start: String.Index?
        if let http = httpIndex, let https = httpsIndex {
            start = http > https ? http : https
        } else if let http = httpIndex {
            start = http
        } else if let https = httpsIndex {
            start = https
        } else {
            start = nil
        }
        guard let start else { return value }
        let candidate = String(value[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if let end = candidate.firstIndex(where: { $0.isWhitespace || $0 == "\"" || $0 == "'"
            || $0 == "<" || $0 == ">" }) {
            return String(candidate[candidate.startIndex..<end])
        }
        return candidate
    }

    /// 只做 query 拆分，不做 `+` → 空格的还原以外的任何标准化；
    /// 上游对 code 里的大小写与原样字节敏感。
    private static func queryParameters(_ rawQuery: String?) throws -> [String: String] {
        var values: [String: String] = [:]
        guard let rawQuery, !rawQuery.isEmpty else { return values }
        for item in rawQuery.split(separator: "&", omittingEmptySubsequences: false) {
            guard let separator = item.firstIndex(of: "=") else {
                values[try urlDecode(String(item))] = ""
                continue
            }
            let name = String(item[item.startIndex..<separator])
            let value = String(item[item.index(after: separator)...])
            values[try urlDecode(name)] = try urlDecode(value)
        }
        return values
    }

    /// Java `URLDecoder` 语义：`+` 还原为空格，`%XX` 还原为字节，其余字符按 UTF-8 展开。
    /// 非法 `%` 序列抛 badEncoding；非法 UTF-8 字节按替换字符处理（与 Java 的 REPLACE 一致）。
    private static func urlDecode(_ value: String) throws -> String {
        var bytes: [UInt8] = []
        var iterator = value.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            switch scalar.value {
            case 0x2B:  // '+'
                bytes.append(0x20)
            case 0x25:  // '%'
                guard let first = iterator.next(), let second = iterator.next(),
                      let high = hexValue(first), let low = hexValue(second) else {
                    throw SessionCodecError.badEncoding
                }
                bytes.append(UInt8(high << 4 | low))
            case 0x00...0x7F:
                bytes.append(UInt8(scalar.value))
            default:
                bytes.append(contentsOf: Array(String(scalar).utf8))
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 校验 query 里每个 `%` 后面都跟着两个十六进制位。
    /// 只做"能不能解析"的合法性判断，不改动原串 —— 编码还原交给 urlDecode。
    private static func hasValidPercentEscapes(_ value: String?) -> Bool {
        guard let value else { return true }
        var bytes = value.unicodeScalars.makeIterator()
        while let scalar = bytes.next() {
            guard scalar.value == 0x25 else { continue }
            guard let first = bytes.next(), let second = bytes.next(),
                  hexValue(first) != nil, hexValue(second) != nil else { return false }
        }
        return true
    }

    private static func hexValue(_ scalar: UnicodeScalar) -> UInt8? {
        switch scalar.value {
        case 0x30...0x39: return UInt8(scalar.value - 0x30)
        case 0x61...0x66: return UInt8(scalar.value - 0x61 + 10)
        case 0x41...0x46: return UInt8(scalar.value - 0x41 + 10)
        default: return nil
        }
    }

    /// Java `URLEncoder.encode` 的白名单：字母数字与 `.` `-` `*` `_` 原样，
    /// 空格转 `+`，其余按 UTF-8 大写十六进制转义。**不能**换成
    /// `URLComponents` 的默认 query 编码（空格会变 `%20`），上游不认。
    private static func formEncode(_ value: String) -> String {
        var result = ""
        for byte in value.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2E, 0x2D, 0x2A, 0x5F:
                result.append(Character(UnicodeScalar(byte)))
            case 0x20:
                result.append("+")
            default:
                result.append(String(format: "%%%02X", byte))
            }
        }
        return result
    }
}

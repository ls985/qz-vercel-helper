// 对应 Android 侧 com.gotolibrary.app.TraceintClient。
//
// ⚠️ 本文件里的请求头集合是**逆向得到的"微信客户端"指纹**：Host / Referer / Origin /
// sec-ch-ua-platform:"Android" / sec-ch-ua:"Chromium";v="134",... / sec-ch-ua-mobile:"?1" /
// x-requested-with:com.tencent.mm / Sec-Fetch-* 这一整套来自原版 M2.a 拦截器。
// 上游按这套指纹判定"调用方是微信内置浏览器"，**不要为了"更像 iOS"而改动任何一项**
// ——包括看起来自相矛盾的 sec-ch-ua-platform:"Android"。UA 之外只允许改 User-Agent
// （见 httpUserAgent()）。
import Foundation
import CoreFoundation
import Network
import os

/// 图书馆上游接口客户端。语义对齐 Android 的 TraceintClient（OkHttp + 手动 cookie 管理）。
///
/// 与 Android 的差异（都是平台限制，不影响协议语义）：
/// - URLSession 不允许强制 HTTP/1.1（Android 侧锁了 HTTP_1_1），协议版本交给系统协商；
/// - URLSession 会吞掉 Host / Connection 这类受管头部，照抄设置只是尽力而为。
final class TraceintClient: @unchecked Sendable {

    static let graphqlURL = "https://wechat.v2.traceint.com/index.php/graphql/"
    static let loginURL = "https://open.weixin.qq.com/connect/oauth2/authorize"
        + "?appid=wx2996d437cd442527"
        + "&redirect_uri=https%3A%2F%2Fwechat.v2.traceint.com%2Findex.php%2Fgraphql"
        + "&response_type=code&scope=snsapi_userinfo&state=1#wechat_redirect"

    /// WebSocket 握手 UA。Android 侧的 WS 侧写死一条串（HTTP 侧才用动态 UA），
    /// 这里同样写死，保持握手指纹在长跑期间不变。
    static let websocketUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 "
        + "MicroMessenger/8.0.49(0x18003128) NetType/WIFI Language/zh_CN ABI/arm64"

    private static let log = Logger(subsystem: "com.gotolibrary.nativeapp", category: "net")
    private static let libraryHosts: Set<String> = ["wechat.v2.traceint.com", "web.traceint.com"]

    /// 上游按精确的 `application/json` 解析请求体（见 graphqlOnce 的注释），
    /// 所以这里必须是常量而不是从别处拼接出来的字符串。
    private static let contentTypeJSON = "application/json"

    /// 系统 UA：复刻 Android buildHttpUserAgent 的结构，设备信息换成 iOS。
    /// 每个字段都取自本机，让请求指纹就是"这台手机上的微信内置浏览器"。
    static func httpUserAgent() -> String {
        return "Mozilla/5.0 (iPhone; CPU iPhone OS " + operatingSystemVersion
            + " like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 "
            + "MicroMessenger/8.0.49(0x18003128) NetType/" + currentNetType()
            + " Language/" + currentLanguage() + " ABI/arm64"
    }

    private static var operatingSystemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion)_\(version.minorVersion)"
    }

    private static var currentLanguage: String {
        let locale = Locale.current
        guard let language = locale.languageCode, !language.isEmpty else { return "en" }
        guard let region = locale.regionCode, !region.isEmpty else { return language }
        return language + "_" + region
    }

    /// NWPathMonitor 只做一次启动，读 `currentPath` 是同步的。
    /// 首次调用时路径可能还没就绪 —— 这时返回 UNKNOWN 而不是等它，
    /// 上游只是把网络类型写进 UA 指纹，不值得为它阻塞线程。
    private static let pathMonitor: NWPathMonitor = {
        let monitor = NWPathMonitor()
        monitor.start(queue: DispatchQueue(label: "com.gotolibrary.nativeapp.netpath"))
        return monitor
    }()

    private static func currentNetType() -> String {
        let path = pathMonitor.currentPath
        guard path.status == .satisfied else { return "UNKNOWN" }
        if path.usesInterfaceType(.wifi) { return "WIFI" }
        if path.usesInterfaceType(.cellular) { return "4G" }
        return "UNKNOWN"
    }

    // MARK: - 数据模型

    struct Room {
        let id: Int
        let name: String
        let available: Int
        let open: Bool
    }

    /// `status` 保持着上游的原始 JSON 值（布尔/数字/字符串都出现过），
    /// 是否可用的判定集中在 isFree 里，不要在这里提前归一化。
    struct Seat {
        let key: String
        let name: String
        let type: Int
        let status: Any?
        let seatStatus: Int?
    }

    struct TomorrowAvailability {
        let ready: Bool
        let available: Int?
        let seats: [Seat]
    }

    /// 验证码图片（base64）与配套 code，供退码与预约 mutation 使用。
    struct Captcha {
        let code: String
        let imageBase64: String
    }

    /// 预约单次尝试的结构化结果：业务失败以 message 原文返回供上层分派，
    /// 网络层异常才抛出。
    struct ReserveOutcome {
        let success: Bool
        let message: String
    }

    struct CandidateList {
        let list: [Seat]
        let fellBack: Bool
    }

    /// 保活探针结果。invalid = true 表示上游**明确拒绝**该会话。
    struct IndexProbe {
        let invalid: Bool
        let detail: String
        let userId: String
    }

    struct ApiError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - 状态

    private let lock = NSLock()
    private var storedCookie: String
    private let cookieListener: ((String) -> Void)?
    private let session: URLSession

    /// - Parameter onCookieRefreshed: 上游轮换会话 cookie 时回调。
    ///   长生命周期客户端（保活、排队）必须挂这个回调：traceint 会在应答里轮换会话值，
    ///   接不住的话本地永远是登录那一刻的旧 cookie，服务器一换会话就静默死亡。
    init(cookie: String, onCookieRefreshed: ((String) -> Void)? = nil) {
        self.storedCookie = TraceintClient.normalizeCookieHeader(cookie)
        self.cookieListener = onCookieRefreshed
        // 关闭 URLSession 自带的 CookieJar：cookie 的合并/持久化必须由我们自己做，
        // 否则系统会另存一份，两边会各自轮换并互相覆盖。
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 对齐 Android：connect 12s / read 15s / write 15s。
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    var cookie: String {
        lock.lock()
        defer { lock.unlock() }
        return storedCookie
    }

    private func applyServerCookies(_ setCookies: [String]) {
        lock.lock()
        let merged = TraceintClient.mergeServerCookies(storedCookie, setCookies)
        let changed = merged != storedCookie
        if changed { storedCookie = merged }
        let listener = cookieListener
        lock.unlock()
        // 回调在锁外执行：调用方常在回调里写 AppConfig 甚至重建 client，
        // 持锁回调会把锁顺序问题带进来。
        if changed { listener?(merged) }
    }

    // MARK: - 查询

    func fetchRooms() async throws -> [Room] {
        let query = "query list {\n userAuth {\n reserve {\n libs(libType: -1) {\n lib_id\n lib_name\n "
            + "is_open\n lib_rt {\n seats_has\n }\n }\n }\n }\n}"
        let result = try await graphql("list", query, [:], tomorrow: false)
        guard let libraries = TraceintClient.nested(result, "data", "userAuth", "reserve", "libs")
            as? [Any] else { return [] }
        return libraries.compactMap { item in
            guard let room = item as? [String: Any] else { return nil }
            let id = TraceintClient.intValue(room["lib_id"]) ?? 0
            let name = room["lib_name"] as? String ?? "阅览室 \(id)"
            let layout = room["lib_rt"] as? [String: Any]
            return Room(id: id,
                        name: name,
                        available: layout.flatMap { TraceintClient.intValue($0["seats_has"]) } ?? 0,
                        open: TraceintClient.booleanValue(room["is_open"]) ?? false)
        }
    }

    func fetchSeats(roomId: Int) async throws -> [Seat] {
        let query = "query libLayout($libId: Int, $libType: Int) { userAuth { reserve { "
            + "libs(libType: $libType, libId: $libId) { lib_id lib_name lib_floor is_open "
            + "lib_layout { seats_total seats_booking seats_used seats { key name type status seat_status x y } } } } } }"
        let result = try await graphql("libLayout", query, ["libId": roomId, "libType": -1], tomorrow: false)
        guard let libraries = TraceintClient.nested(result, "data", "userAuth", "reserve", "libs")
            as? [Any] else { return [] }
        // 上游可能忽略 libId 返回整个列表，所以按 lib_id 再挑一次；
        // 一个都没匹配上时沿用第 0 个（与 Android 行为一致）。
        var selected: [String: Any]? = libraries.isEmpty ? nil : libraries[0] as? [String: Any]
        for item in libraries {
            guard let room = item as? [String: Any] else { continue }
            if (TraceintClient.intValue(room["lib_id"]) ?? 0) == roomId { selected = room }
        }
        guard let layout = selected?["lib_layout"] as? [String: Any] else { return [] }
        return TraceintClient.parseSeats(layout["seats"] as? [Any])
    }

    func fetchTomorrowAvailability(roomId: Int, includeSeats: Bool) async throws -> TomorrowAvailability {
        let seatFields = includeSeats ? " seats { key name type status seat_status x y }" : ""
        let query = "query libLayout($libId: Int!) { userAuth { prereserve { libLayout(libId: $libId) "
            + "{ seats_booking seats_total seats_used" + seatFields + " } } } }"
        let result = try await graphql("libLayout", query, ["libId": roomId], tomorrow: true)
        guard let layout = TraceintClient.nested(result, "data", "userAuth", "prereserve", "libLayout")
            as? [String: Any] else {
            return TomorrowAvailability(ready: false, available: nil, seats: [])
        }
        let total = TraceintClient.intValue(layout["seats_total"]) ?? 0
        let used = TraceintClient.intValue(layout["seats_used"]) ?? 0
        let booking = TraceintClient.intValue(layout["seats_booking"]) ?? 0
        return TomorrowAvailability(ready: true,
                                    available: max(0, total - used - booking),
                                    seats: TraceintClient.parseSeats(layout["seats"] as? [Any]))
    }

    /// 今日预约。业务失败不抛异常，原文交给上层关键字分派。
    func reserveSeat(roomId: Int, seat: Seat, captcha: String, captchaCode: String) async throws -> ReserveOutcome {
        // 上游字段名本来就是错拼的 reserueSeat，先试错拼再试正确拼写，别"顺手修正"。
        var last: ApiError?
        for field in ["reserueSeat", "reserveSeat"] {
            let variables: [String: Any] = ["libId": roomId,
                                            "seatKey": seat.key,
                                            "captchaCode": captchaCode,
                                            "captcha": captcha]
            let query = "mutation " + field + "($libId: Int!, $seatKey: String!, "
                + "$captchaCode: String, $captcha: String!) { userAuth { reserve { "
                + field + "(libId: $libId, seatKey: $seatKey, captchaCode: $captchaCode, captcha: $captcha) } } }"
            do {
                let result = try await graphql(field, query, variables, tomorrow: false)
                let value = TraceintClient.nested(result, "data", "userAuth", "reserve") as? [String: Any]
                let success = TraceintClient.explicitSuccess(value?[field])
                return ReserveOutcome(success: success,
                                      message: success ? "预约成功" : "服务器未确认预约结果")
            } catch let error as ApiError {
                last = error
                if !error.message.lowercased().contains("field") {
                    return ReserveOutcome(success: false, message: error.message)
                }
            }
        }
        return ReserveOutcome(success: false, message: last?.message ?? "预约接口没有返回结果")
    }

    /// 明日预约。key 必须带尾点，这是 prereserve.save 的格式要求。
    func reserveTomorrow(roomId: Int, seat: Seat, captcha: String, captchaCode: String) async throws -> ReserveOutcome {
        let key = seat.key.hasSuffix(".") ? seat.key : seat.key + "."
        let variables: [String: Any] = ["key": key,
                                        "libid": roomId,
                                        "captchaCode": captchaCode,
                                        "captcha": captcha]
        let query = "mutation save($key: String!, $libid: Int!, $captchaCode: String, $captcha: String) "
            + "{ userAuth { prereserve { save(key: $key, libId: $libid, captcha: $captcha, "
            + "captchaCode: $captchaCode) } } }"
        let result = try await graphql("save", query, variables, tomorrow: true)
        let value = TraceintClient.nested(result, "data", "userAuth", "prereserve") as? [String: Any]
        let success = TraceintClient.explicitSuccess(value?["save"])
        return ReserveOutcome(success: success, message: success ? "预约成功" : "服务器未确认预约结果")
    }

    /// 取一张验证码。code 是这次验证码的唯一标识（退码要用），data 是图片 base64。
    func fetchCaptcha(tomorrow: Bool) async throws -> Captcha {
        let result = try await graphql("captcha", "query captcha { captcha { code data } }", [:],
                                       tomorrow: tomorrow)
        guard let captcha = TraceintClient.nested(result, "data", "captcha") as? [String: Any] else {
            throw ApiError(message: "验证码接口返回为空")
        }
        let code = captcha["code"] as? String ?? ""
        let image = captcha["data"] as? String ?? ""
        guard !image.isEmpty else { throw ApiError(message: "验证码图片为空") }
        return Captcha(code: code, imageBase64: image)
    }

    func fetchUserId() async throws -> String {
        let result = try await graphql("index", "query index { userAuth { currentUser { user_id } } }",
                                       [:], tomorrow: false)
        let user = TraceintClient.nested(result, "data", "userAuth", "currentUser") as? [String: Any]
        return TraceintClient.stringValue(user?["user_id"])
    }

    /// 明日预约结果复核。记录缺失或 lib_id 不符都按"没约上"处理（不抛异常）。
    func verifyTomorrow(roomId: Int, seat: Seat) async throws -> Bool {
        let result = try await graphql("prereserve",
                                       "query prereserve { userAuth { prereserve { prereserve { day lib_id seat_key seat_name is_used } } } }",
                                       [:], tomorrow: true)
        guard let record = TraceintClient.nested(result, "data", "userAuth", "prereserve", "prereserve")
            as? [String: Any] else { return false }
        if (TraceintClient.intValue(record["lib_id"]) ?? 0) != roomId { return false }
        return TraceintClient.trimDot(TraceintClient.stringValue(record["seat_key"])) == TraceintClient.trimDot(seat.key)
    }

    /// 保活探针。只有"上游明确拒绝会话"才算 invalid；网络超时与服务端瞬时错误
    /// 一律重新抛出，交给调用方继续下一轮，不终止保活。
    func indexProbe() async throws -> IndexProbe {
        do {
            let result = try await graphql("index",
                                           "query index { userAuth { currentUser { user_id user_nick } "
                                           + "reserve { reserve { lib_id lib_name seat_name date validate_date status } } } }",
                                           [:], tomorrow: false)
            let user = TraceintClient.nested(result, "data", "userAuth", "currentUser") as? [String: Any]
            let userId = TraceintClient.stringValue(user?["user_id"])
            if userId.trimmingCharacters(in: .whitespaces).isEmpty {
                return IndexProbe(invalid: true, detail: "保活响应缺少用户信息", userId: "")
            }
            return IndexProbe(invalid: false, detail: "", userId: userId)
        } catch let error as ApiError {
            if TraceintClient.isSessionInvalid(error.message) {
                return IndexProbe(invalid: true, detail: error.message, userId: "")
            }
            throw error
        }
    }

    // MARK: - GraphQL 传输

    /// `authorizationMode` 四态重放：带 Authorization 的会话在某些链路上会被
    /// 上游按未转义/未加前缀拒绝，而错误文案固定是 "Unexpected <EOF>"。
    /// 只有这个错误才换下一态，其它错误直接抛出，避免把真实业务错误吞成重放。
    private func graphql(_ operation: String, _ query: String, _ variables: [String: Any],
                         tomorrow: Bool) async throws -> [String: Any] {
        var last: ApiError?
        for mode in 0...3 {
            do {
                return try await graphqlOnce(operation, query, variables,
                                             tomorrow: tomorrow, authorizationMode: mode)
            } catch let error as ApiError {
                last = error
                if !error.message.contains("Unexpected <EOF>") { throw error }
            }
        }
        throw last ?? ApiError(message: "图书馆接口认证失败")
    }

    private func graphqlOnce(_ operation: String, _ query: String, _ variables: [String: Any],
                             tomorrow: Bool, authorizationMode: Int) async throws -> [String: Any] {
        let currentCookie = cookie
        if currentCookie.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ApiError(message: "登录已失效，请重新登录")
        }
        // 花括号配平校验：query 字符串拼错时上游只会回一句没头没尾的语法错误，
        // 在本地拦下来的日志能直接指出是哪个 operation。
        var braces = 0
        for character in query {
            if character == "{" { braces += 1 }
            if character == "}" { braces -= 1 }
            if braces < 0 { break }
        }
        if braces != 0 {
            TraceintClient.log.error("GraphQL \(operation, privacy: .public) 括号不配平: \(braces)")
            throw ApiError(message: "应用请求结构异常，请更新应用")
        }

        let payload: [String: Any] = ["operationName": operation, "query": query, "variables": variables]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw ApiError(message: "应用请求结构异常，请更新应用")
        }
        TraceintClient.log.debug("GraphQL \(operation, privacy: .public) requestBytes=\(body.count) tomorrow=\(tomorrow)")

        guard let endpoint = URL(string: TraceintClient.graphqlURL) else {
            throw ApiError(message: "应用请求结构异常，请更新应用")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        // 必须用 Data 直接作请求体，且 Content-Type 精确为 "application/json"：
        // 带上 "; charset=utf-8" 时上游会把 body 当空处理并返回 "Syntax Error: Unexpected <EOF>"。
        // 这是整个项目最关键的一条，改一个字就会全线失败。
        request.setValue(TraceintClient.contentTypeJSON, forHTTPHeaderField: "Content-Type")
        request.setValue("wechat.v2.traceint.com", forHTTPHeaderField: "Host")
        request.setValue("https://web.traceint.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://web.traceint.com", forHTTPHeaderField: "Origin")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        request.setValue("2.1.5", forHTTPHeaderField: "app-version")
        request.setValue("1", forHTTPHeaderField: "Upgrade-Insecure-Requests")
        request.setValue(TraceintClient.httpUserAgent(), forHTTPHeaderField: "User-Agent")
        request.setValue("\"Android\"", forHTTPHeaderField: "sec-ch-ua-platform")
        request.setValue("\"Chromium\";v=\"134\", \"Not:A-Brand\";v=\"24\", \"Android WebView\";v=\"134\"",
                         forHTTPHeaderField: "sec-ch-ua")
        request.setValue("?1", forHTTPHeaderField: "sec-ch-ua-mobile")
        request.setValue("com.tencent.mm", forHTTPHeaderField: "x-requested-with")
        request.setValue("same-site", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7", forHTTPHeaderField: "accept-language")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("u=1, i", forHTTPHeaderField: "priority")
        request.setValue(currentCookie, forHTTPHeaderField: "Cookie")

        let authorization = TraceintClient.cookieValue(currentCookie, "Authorization")
        if !authorization.isEmpty, authorizationMode > 0 {
            let decoded = TraceintClient.decodeCookieValue(authorization)
            var header = authorizationMode == 1 ? authorization : decoded
            if authorizationMode == 3,
               !decoded.lowercased().hasPrefix("bearer ") {
                header = "Bearer " + decoded
            }
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }

        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw ApiError(message: "网络请求失败：" + error.localizedDescription)
        }
        let data = result.0
        let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""

        // 上游在应答里刷新会话 cookie 时就地合并并持久化（复刻原版 CookieJar 的
        // saveFromResponse）。**必须在状态码判断之前**做：4xx 应答同样可能轮换会话。
        let setCookies = TraceintClient.setCookieHeaders(from: result.1)
        if !setCookies.isEmpty {
            applyServerCookies(setCookies)
        }
        TraceintClient.log.debug("GraphQL \(operation, privacy: .public) status=\(status) authorizationMode=\(authorizationMode)")
        if !text.isEmpty, status >= 400 || text.contains("\"errors\"") {
            TraceintClient.log.debug("GraphQL 响应 \(text, privacy: .public)")
        }
        if !(200...299).contains(status) {
            throw ApiError(message: "图书馆接口 HTTP \(status)")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ApiError(message: "图书馆接口返回了非 JSON 数据（HTTP \(status)）："
                + TraceintClient.snippet(text, 120))
        }
        if let errors = json["errors"] as? [Any], !errors.isEmpty {
            let message = errors.map { item -> String in
                if let object = item as? [String: Any] {
                    return object["message"] as? String ?? object["msg"] as? String
                        ?? String(describing: object)
                }
                if let text = item as? String { return text }
                return String(describing: item)
            }.joined(separator: "；")
            throw ApiError(message: message)
        }
        return json
    }

    // MARK: - 授权换会话

    /// 用用户粘贴的回调链接换一份完整 cookie。
    ///
    /// **不跟随自动重定向**：手工逐跳跟随最多 6 跳，每跳都吃 Set-Cookie。
    /// 跳转目标 host 必须是两个图书馆域之一 —— 回调链接是可以被伪造的，
    /// 放任它跳到任意域等于把会话 cookie 送给第三方。
    static func exchangeCallbackForCookie(_ callbackURL: String) async throws -> String {
        let sessionRequest: SessionRequest
        do {
            sessionRequest = try WechatSessionCodec.parse(callbackURL)
        } catch let error as SessionCodecError {
            throw ApiError(message: error.errorDescription ?? "请输入有效的微信回调链接")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration,
                                 delegate: NoRedirectSessionDelegate(),
                                 delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var jar: [String: String] = [:]
        try await followWithCookies(session: session, url: sessionRequest.baseURL,
                                    jar: &jar, redirectsLeft: 0)
        try await followWithCookies(session: session, url: sessionRequest.authURL,
                                    jar: &jar, redirectsLeft: 6)
        log.debug("Session exchange complete; cookies=\(cookieNames(joinCookieMap(jar)), privacy: .public)")

        // 只有 SERVERID（负载均衡标记）说明授权没走到会话建立那一步，等于登录没成功。
        let hasSession = jar.contains { entry in
            entry.key.caseInsensitiveCompare("SERVERID") != .orderedSame
                && !entry.value.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard hasSession else { throw ApiError(message: "微信授权已失效，请重新获取回调链接") }
        return joinCookieMap(jar)
    }

    private static func followWithCookies(session: URLSession, url: String,
                                          jar: inout [String: String],
                                          redirectsLeft: Int) async throws {
        guard let requestURL = URL(string: url) else {
            throw ApiError(message: "请输入有效的微信回调链接")
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue(httpUserAgent(), forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                         forHTTPHeaderField: "Accept")
        request.setValue(joinCookieMap(jar), forHTTPHeaderField: "Cookie")
        request.setValue("https://web.traceint.com/web/index.html", forHTTPHeaderField: "Referer")

        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw ApiError(message: "网络请求失败：" + error.localizedDescription)
        }
        guard let http = result.1 as? HTTPURLResponse else { return }
        WechatSessionCodec.mergeSetCookies(&jar, setCookieHeaders(from: http))
        log.debug("Session GET host=\(http.url?.host ?? "", privacy: .public) path=\(http.url?.path ?? "", privacy: .public) status=\(http.statusCode) cookies=\(cookieNames(joinCookieMap(jar)), privacy: .public)")

        var next: String?
        if redirectsLeft > 0, let location = http.value(forHTTPHeaderField: "Location"),
           [301, 302, 303, 307, 308].contains(http.statusCode) {
            guard let resolved = URL(string: location, relativeTo: http.url)?.absoluteURL,
                  let host = resolved.host?.lowercased(),
                  libraryHosts.contains(host) else {
                throw ApiError(message: "授权跳转到了非图书馆地址")
            }
            next = resolved.absoluteString
        }
        if let next {
            try await followWithCookies(session: session, url: next,
                                        jar: &jar, redirectsLeft: redirectsLeft - 1)
        }
    }

    /// URLSession 把同名响应头的多个值折叠成**一个**字符串（allHeaderFields 是字典，
    /// 拿不到重复键），所以服务端一次回多个 Set-Cookie 时它们是被逗号拼起来的。
    /// Expires 属性里同样有逗号，只能按"逗号后面紧跟 name=" 这个特征切分。
    private static let setCookieSeparator = try? NSRegularExpression(
        pattern: ",(?=\\s*[!#$%&'*+.^`|~0-9A-Za-z_-]+=)")

    private static func setCookieHeaders(from response: URLResponse) -> [String] {
        guard let http = response as? HTTPURLResponse else { return [] }
        var raw: [String] = []
        for (key, value) in http.allHeaderFields {
            guard let name = key as? String, name.lowercased() == "set-cookie" else { continue }
            if let text = value as? String { raw.append(text) }
        }
        return raw.flatMap { splitSetCookie($0) }
    }

    private static func splitSetCookie(_ value: String) -> [String] {
        guard let regex = setCookieSeparator else { return [value] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        var pieces: [String] = []
        var last = value.startIndex
        regex.enumerateMatches(in: value, options: [], range: range) { match, _, _ in
            guard let match, let comma = Range(match.range, in: value) else { return }
            pieces.append(String(value[last..<comma.lowerBound]))
            last = comma.upperBound
        }
        pieces.append(String(value[last...]))
        return pieces.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: - 文案判定

    static func isRiskMessage(_ message: String?) -> Bool {
        guard let message else { return false }
        return matches(message,
                       "(?is).*(频繁|过快|封禁|限制|风控|验证码|captcha|access denied|denied|非法|黑名单).*")
    }

    static func isSessionExpired(_ message: String?) -> Bool {
        guard let message else { return false }
        return matches(message,
                       "(?is).*(登录.*(过期|失效|超时)|会话.*(过期|失效)|authorization.*(expired|invalid)|未登录).*")
    }

    /// 保活用的失效判定：除会话过期措辞外，还要覆盖上游直接把 40001 / access denied
    /// 塞进 GraphQL errors 的情况。收紧到明确的失效特征，避免瞬时服务端错误掐断保活。
    static func isSessionInvalid(_ message: String?) -> Bool {
        guard let message, !message.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return isSessionExpired(message)
            || matches(message, "(?is).*(access denied|40001|未授权|凭证|token.*(过期|无效|失效)).*")
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: text, options: [],
                                range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
    }

    // MARK: - 座位挑选

    private static let freeStatusValues: Set<String> =
        ["0", "false", "free", "available", "empty", "空闲", "可选"]

    /// `type != 1` 表示不是可选座位；`seatStatus` 优先（服务器给了就信它），
    /// 否则回退看 status 的原始值（历史上出现过布尔、数字、字符串三种形态）。
    static func isFree(_ seat: Seat) -> Bool {
        guard seat.type == 1,
              !seat.key.trimmingCharacters(in: .whitespaces).isEmpty,
              !seat.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if let seatStatus = seat.seatStatus { return seatStatus == 1 }
        guard let status = seat.status else { return false }
        if let number = status as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return !number.boolValue }
            return number.intValue == 0
        }
        if let text = status as? String {
            return freeStatusValues.contains(text.trimmingCharacters(in: .whitespaces).lowercased())
        }
        return false
    }

    static func orderCandidates(_ seats: [Seat], preferred: [String], freeOnly: Bool) -> [Seat] {
        let result = seats.filter { seat in
            (!freeOnly || isFree(seat))
                && (preferred.isEmpty || preferred.contains(seat.name) || preferred.contains(seat.key))
        }
        if preferred.isEmpty {
            // 没指定座位时随机挑，避免所有用户都从第一排第一个座位开始抢。
            return result.shuffled()
        }
        // Java 用稳定排序（List.sort 是 TimSort），Swift 的 sorted 不保证稳定，
        // 所以带上原始下标做次序键，保证同优先级座位的相对顺序不变。
        let indexed = result.enumerated().map { (offset: $0.offset, seat: $0.element) }
        return indexed.sorted { lhs, rhs in
            let left = preferredIndex(lhs.seat, preferred: preferred)
            let right = preferredIndex(rhs.seat, preferred: preferred)
            if left != right { return left < right }
            return lhs.offset < rhs.offset
        }.map { $0.seat }
    }

    private static func preferredIndex(_ seat: Seat, preferred: [String]) -> Int {
        if let index = preferred.firstIndex(of: seat.name) { return index }
        if let index = preferred.firstIndex(of: seat.key) { return index }
        return Int.max
    }

    /// 指定座位里有空位就按用户顺序返回；指定座位全不可用且 allowOther 时
    /// 回退到任意空闲座位（捡漏），并以 fellBack 标记这一轮是捡漏。
    static func chooseCandidates(_ seats: [Seat], preferred: [String],
                                 freeOnly: Bool, allowOther: Bool) -> CandidateList {
        let matched = orderCandidates(seats, preferred: preferred, freeOnly: freeOnly)
        if !matched.isEmpty || preferred.isEmpty || !allowOther {
            return CandidateList(list: matched, fellBack: false)
        }
        let fallback = seats.filter { !freeOnly || isFree($0) }.shuffled()
        return CandidateList(list: fallback, fellBack: !fallback.isEmpty)
    }

    // MARK: - Cookie 工具

    /// 把应答 Set-Cookie 合并进现有 Cookie 头：同名覆盖、新名追加。
    /// 注：iOS 这边用 Dictionary 承载，条目输出顺序与 Android 的 LinkedHashMap 不同，
    /// cookie 按名查找，顺序不影响上游语义。
    static func mergeServerCookies(_ cookieHeader: String, _ setCookies: [String]) -> String {
        var jar = cookieHeader.trimmingCharacters(in: .whitespaces).isEmpty
            ? [String: String]() : parseCookieMap(cookieHeader)
        WechatSessionCodec.mergeSetCookies(&jar, setCookies)
        return joinCookieMap(jar)
    }

    static func cookieNames(_ cookieHeader: String) -> String {
        var names: [String] = []
        for part in cookieHeader.split(separator: ";", omittingEmptySubsequences: false) {
            let item = String(part).trimmingCharacters(in: .whitespaces)
            guard let separator = item.firstIndex(of: "="), separator != item.startIndex else { continue }
            names.append(String(item[item.startIndex..<separator]).trimmingCharacters(in: .whitespaces))
        }
        return names.isEmpty ? "（无）" : names.joined(separator: "、")
    }

    private static func normalizeCookieHeader(_ rawCookie: String?) -> String {
        guard let rawCookie, !rawCookie.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        return joinCookieMap(parseCookieMap(rawCookie))
    }

    /// 解析成 name→value 表；同名（大小写不敏感）后者覆盖前者，
    /// 且保留先出现的那个名字的拼写（对齐 Android 的 LinkedHashMap 行为）。
    private static func parseCookieMap(_ rawCookie: String) -> [String: String] {
        var values: [String: String] = [:]
        for part in rawCookie.split(separator: ";", omittingEmptySubsequences: false) {
            let item = String(part).trimmingCharacters(in: .whitespaces)
            guard let separator = item.firstIndex(of: "="), separator != item.startIndex else { continue }
            let name = String(item[item.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(item[item.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty else { continue }
            if let existing = values.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                values[existing] = value
            } else {
                values[name] = value
            }
        }
        return values
    }

    private static func joinCookieMap(_ values: [String: String]) -> String {
        values.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    private static func cookieValue(_ cookieHeader: String, _ name: String) -> String {
        for part in cookieHeader.split(separator: ";", omittingEmptySubsequences: false) {
            let item = String(part).trimmingCharacters(in: .whitespaces)
            guard let separator = item.firstIndex(of: "="), separator != item.startIndex else { continue }
            let key = String(item[item.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            if key.caseInsensitiveCompare(name) == .orderedSame {
                return String(item[item.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    /// Java `URLDecoder` 语义（`+` → 空格）。cookie 里的 Authorization 常被转义成 %XX，
    /// 原样重放会被上游判定为授权失败。解码失败时原样返回（对齐 Android 的 catch 分支）。
    private static func decodeCookieValue(_ value: String) -> String {
        var bytes: [UInt8] = []
        var iterator = value.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            switch scalar.value {
            case 0x2B:
                bytes.append(0x20)
            case 0x25:
                guard let first = iterator.next(), let second = iterator.next(),
                      let high = hexValue(first), let low = hexValue(second) else { return value }
                bytes.append(UInt8(high << 4 | low))
            case 0x00...0x7F:
                bytes.append(UInt8(scalar.value))
            default:
                bytes.append(contentsOf: Array(String(scalar).utf8))
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hexValue(_ scalar: UnicodeScalar) -> UInt8? {
        switch scalar.value {
        case 0x30...0x39: return UInt8(scalar.value - 0x30)
        case 0x61...0x66: return UInt8(scalar.value - 0x61 + 10)
        case 0x41...0x46: return UInt8(scalar.value - 0x41 + 10)
        default: return nil
        }
    }

    // MARK: - JSON 读取辅助

    /// 逐级取嵌套字典，任一级缺失就返回 nil（等效 Android 的 optJSONObject 链）。
    private static func nested(_ root: Any?, _ keys: String...) -> Any? {
        var current: Any? = root
        for key in keys {
            guard let dictionary = current as? [String: Any] else { return nil }
            current = dictionary[key]
        }
        return current
    }

    private static func stringValue(_ value: Any?) -> String {
        guard let value else { return "" }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    private static func intValue(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    /// 严格布尔：JSON 里的 true/false 由 JSONSerialization 转成 __NSCFBoolean，
    /// 普通数字不是布尔，不能因为 NSNumber 能桥接就当成 true。
    private static func jsonBoolean(_ value: Any?) -> Bool? {
        guard let value, let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// 对应 Android `optBoolean`：真布尔直接用，字符串 "true"/"false" 也认。
    private static func booleanValue(_ value: Any?) -> Bool? {
        if let bool = jsonBoolean(value) { return bool }
        guard let text = value as? String else { return nil }
        if text.caseInsensitiveCompare("true") == .orderedSame { return true }
        if text.caseInsensitiveCompare("false") == .orderedSame { return false }
        return nil
    }

    /// 复刻旧版的成功判定：布尔直接用；对象看 success/status/code；
    /// 其它类型落到文案匹配 —— 先判失败关键字，再判成功关键字。
    private static func explicitSuccess(_ value: Any?) -> Bool {
        if let bool = jsonBoolean(value) { return bool }
        if let object = value as? [String: Any] {
            if booleanValue(object["success"]) == true { return true }
            if booleanValue(object["status"]) == true { return true }
            if object["code"] != nil, intValue(object["code"]) == 0 { return true }
            return false
        }
        let text = (value.map { String(describing: $0) } ?? "null")
            .trimmingCharacters(in: .whitespaces).lowercased()
        if matches(text, "(?is).*(失败|错误|不可|已满|取消|拒绝|不成功|未成功|false|fail|error|denied).*") {
            return false
        }
        return matches(text, "(?is).*(成功|已预约|已经预约|已预定|已经预定).*")
            || matches(text, "^(ok|true|1)$")
    }

    private static func parseSeats(_ values: [Any]?) -> [Seat] {
        guard let values else { return [] }
        var seats: [Seat] = []
        for item in values {
            guard let item = item as? [String: Any] else { continue }
            // 只有字段存在且非 null 才算"服务器给了 seat_status"；缺字段留 nil，
            // 让 isFree 回退去看 status 的原始值。
            let seatStatus: Int? = (item["seat_status"] is NSNull)
                ? nil : intValue(item["seat_status"])
            seats.append(Seat(key: stringValue(item["key"]),
                              name: stringValue(item["name"]),
                              type: intValue(item["type"]) ?? 0,
                              status: item["status"],
                              seatStatus: seatStatus))
        }
        return seats
    }

    private static func trimDot(_ value: String) -> String {
        value.hasSuffix(".") ? String(value.dropLast()) : value
    }

    private static func snippet(_ text: String, _ limit: Int) -> String {
        let compact = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return "（空响应）" }
        return compact.count <= limit ? compact : String(compact.prefix(limit)) + "…"
    }

    /// 授权换会话必须手工逐跳跟随：URLSession 默认自动跟随跳转，而系统 CookieJar
    /// 已被关闭，中间跳的 Set-Cookie 就不会经过我们的合并逻辑。这里把跳转拦下来，
    /// 让每一跳都回到 followWithCookies 的循环里。
    private final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

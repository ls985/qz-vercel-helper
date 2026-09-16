// 对应 Android 侧 com.gotolibrary.app.QueueEngine。
//
// 平台差异（不影响协议语义）：
// - iOS 没有"读线程 + 定时器线程"模型，这里全部用 async/await + Task 承载；
//   可变状态集中在一个 actor 里，避免裸 var 跨并发域读写。
// - URLSessionWebSocketTask 没有 onOpen 回调，用 URLSessionWebSocketDelegate 的
//   didOpenWithProtocol 代替；握手头里 Host / Connection / Upgrade / Sec-WebSocket-Key
//   由系统接管，照抄设置只是尽力而为。
import Foundation
import Network
import os

/// 排队引擎回调。实现方可能在任意执行器上被调用（引擎内部是 actor），
/// 所以实现必须是线程安全的；ReservationRunner 通过一个加锁的桥接对象转成主线程事件。
protocol QueueEngineListener: AnyObject {
    func queueLog(_ message: String)
    func queuePassed()
    func queueAlreadyBooked()
    func queueBlocked(_ message: String)
    func queueExhausted(_ message: String)
}

final class QueueEngine {

    /// 排队通道地址与握手头都照抄 Android（N0/x.java:128-138 的逆向结果）。
    static let queueURL = "wss://wechat.v2.traceint.com/ws?ns=prereserve/queue"
    static let origin = "https://web.traceint.com"
    static let pingPayload = "{\"ns\":\"prereserve/queue\",\"msg\":\"\"}"

    /// 前方人数不超过该值时使用入队间隔，超过则放宽（复刻旧版 U2.g 的 30 人分档）。
    static let crowdedQueueThreshold = 30
    /// 距开放时间超过该秒数时维持低频等待，以内进入 50ms 细倒计时。
    static let fineCountdownWindowSeconds = 13.0
    /// 粗倒计时锚点：开放前 10 秒（再加提前量）。
    static let coarseCountdownLeadMs = 10_000.0
    /// 低频阶段看门狗的触发线：距高频排队不足该毫秒数就直接推进。
    static let coarseGuardTriggerMs = 8_000.0
    static let reconnectBackoffMs: [Double] = [10, 100, 500, 1000, 2000, 4000, 8000]
    static let cookieKeepalivePingMs = 5_000.0
    /// 连接存活超过该时长才认为重连成功，避免服务器反复"握手成功-立刻断开"时把退避重置成 10ms 热循环。
    static let stableConnectionMs = 5_000.0
    /// 重连时仍保留服务器告知的开放时刻的宽容窗口（含刚过开放时刻的情形，便于抓住仍在开放的队列）。
    static let openTimeCarryOverMs = 15 * 60 * 1000.0
    /// 未识别的服务器消息最多记录几条，够排障又不至于冲掉有价值的日志。
    static let maxUnknownMessageLogs = 5
    static let overallTimeoutMs = 30 * 60 * 1000.0
    /// 入队后前方人数 >30 时的放宽间隔（原版 afterIntervalTime 的拥堵档）。
    static let crowdedQueuePingMs = 1000.0
    /// 距开放还早时的低频保活 ping，复刻原版 U2.g 状态 12 的 30s。
    static let coarseWaitPingMs = 30_000.0

    static let ntpHost = "ntp.aliyun.com"
    static let ntpTimeoutMs = 5000

    fileprivate static let log = Logger(subsystem: "com.gotolibrary.nativeapp", category: "queue")

    fileprivate static let openTimeRegex = try? NSRegularExpression(pattern: "(\\d{2}:\\d{2})")
    fileprivate static let unicodeEscapeRegex = try? NSRegularExpression(pattern: "\\\\u([0-9a-fA-F]{4})")

    private let core: QueueEngineCore

    init(cookie: String, userAgent: String, advanceMs: Double, beforeIntervalMs: Double,
         afterIntervalMs: Double, fallbackOpenTime: String?, listener: QueueEngineListener) {
        core = QueueEngineCore(cookie: cookie, userAgent: userAgent, advanceMs: advanceMs,
                               beforeIntervalMs: beforeIntervalMs, afterIntervalMs: afterIntervalMs,
                               fallbackOpenTime: fallbackOpenTime, listener: listener)
    }

    /// 阻塞运行直到排队出结果或被取消；返回前清理所有资源。
    func run() async {
        await core.run()
    }

    /// 立即停止。收敛动作要挤进 actor 里执行（否则 receive() 会一直挂在等待上），
    /// 所以这里是"置标志 + 异步收尾"，调用方不需要等待。
    func cancel() {
        Task { await core.cancel() }
    }

    // MARK: - 纯函数工具

    /// 服务器消息里的 Unicode 转义序列还原，并把 PHP json_encode 转义的 "\/" 还原成 "/"。
    /// 斜杠这一层是必须的：服务器发的是 prereserve\/queue，少这一步整个排队人数分支
    /// 都匹配不上，位置回复会被静默丢弃。
    static func decodeUnicodeEscapes(_ text: String) -> String {
        if !text.contains("\\u") && !text.contains("\\/") { return text }
        let value = text.replacingOccurrences(of: "\\/", with: "/")
        guard value.contains("\\u"), let regex = unicodeEscapeRegex else { return value }
        // 按 UTF-16 码元累积：Java 那边 `(char) 0xD83D` 会落下孤立代理项，两个连续的
        // 转义再拼成一对（即真正的 emoji）。用码元数组才能复刻这个行为。
        var units: [UInt16] = []
        var last = value.startIndex
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        regex.enumerateMatches(in: value, options: [], range: range) { match, _, _ in
            guard let match,
                  let full = Range(match.range, in: value),
                  let digits = Range(match.range(at: 1), in: value),
                  let code = UInt16(value[digits], radix: 16) else { return }
            units.append(contentsOf: value[last..<full.lowerBound].utf16)
            units.append(code)
            last = full.upperBound
        }
        units.append(contentsOf: value[last...].utf16)
        return String(decoding: units, as: UTF16.self)
    }

    /// 从 "prereserve/queue","code":0,"data":<数字> 里取后方数字；解析失败返回 0。
    static func parseQueuePosition(_ text: String) -> Int {
        let marker = "\"data\":"
        guard let markerRange = text.range(of: marker, options: .backwards) else { return 0 }
        var digits = ""
        for character in text[markerRange.upperBound...] {
            guard character.isNumber, character.isASCII else { break }
            digits.append(character)
        }
        return Int(digits) ?? 0
    }

    /// NTP 校时：返回本机时钟相对服务器的毫秒偏差（正数=本机慢）。失败返回 0。
    /// 必须是真实 UDP 往返：本机时区/时区数据库不可信，编造出来的偏差会让提前量算错一整个 RTT。
    static func queryClockOffsetMs(host: String, timeoutMs: Int) async -> Int {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            NtpProbe(continuation).start(host: host, timeoutMs: timeoutMs)
        }
    }

    fileprivate static func readUint32(_ buffer: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(buffer[offset]) << 24) | (UInt32(buffer[offset + 1]) << 16)
            | (UInt32(buffer[offset + 2]) << 8) | UInt32(buffer[offset + 3])
    }

    fileprivate static func writeUint32(_ buffer: inout [UInt8], _ offset: Int, _ value: UInt32) {
        buffer[offset] = UInt8((value >> 24) & 0xFF)
        buffer[offset + 1] = UInt8((value >> 16) & 0xFF)
        buffer[offset + 2] = UInt8((value >> 8) & 0xFF)
        buffer[offset + 3] = UInt8(value & 0xFF)
    }

    fileprivate static func readNtpMillis(_ buffer: [UInt8], _ secondsOffset: Int) -> Double {
        let seconds = Double(readUint32(buffer, secondsOffset))
        let fraction = Double(readUint32(buffer, secondsOffset + 4))
        return (seconds - 2_208_988_800.0) * 1000.0 + (fraction / 4294967.296).rounded()
    }

    /// 距今天（上海时区）HH:mm 的毫秒数；已过则为负值，解析失败返回 0。
    static func millisUntilToday(_ hhmm: String, now: Date = Date()) -> Double {
        let parts = hhmm.split(separator: ":")
        guard parts.count >= 2,
              let hour = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let minute = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { return 0 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0
        components.nanosecond = 0
        guard let target = calendar.date(from: components) else { return 0 }
        return target.timeIntervalSince(now) * 1000
    }

    /// 截断过长的服务器消息，避免把日志环形缓冲挤爆。
    fileprivate static func abbreviate(_ text: String) -> String {
        let compact = text.split(whereSeparator: { $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return compact.count <= 80 ? compact : String(compact.prefix(80)) + "…"
    }
}

// MARK: - NTP 往返

/// 一次 UDP NTP 往返。用 Network.framework 的 NWConnection（.udp）而不是 BSD socket：
/// 与工程里其它网络代码同一套栈，且天然异步。
private final class NtpProbe: @unchecked Sendable {

    private let lock = NSLock()
    private var resumed = false
    private var connection: NWConnection?
    private let continuation: CheckedContinuation<Int, Never>
    private let queue = DispatchQueue(label: "com.gotolibrary.nativeapp.ntp")

    init(_ continuation: CheckedContinuation<Int, Never>) {
        self.continuation = continuation
    }

    func start(host: String, timeoutMs: Int) {
        guard let port = NWEndpoint.Port(rawValue: 123) else { finish(0); return }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .udp)
        lock.lock()
        self.connection = connection
        lock.unlock()

        let deviceBefore = Date().timeIntervalSince1970 * 1000
        var buffer = [UInt8](repeating: 0, count: 48)
        buffer[0] = 0x1B // LI=0, VN=3, Mode=3(client)
        let ntpBefore = deviceBefore + 2_208_988_800_000.0 // 1900→1970 秒差
        QueueEngine.writeUint32(&buffer, 40, UInt32(truncatingIfNeeded: Int64(ntpBefore / 1000)))
        QueueEngine.writeUint32(&buffer, 44, UInt32((ntpBefore.truncatingRemainder(dividingBy: 1000)) * 4294967.296))

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: Data(buffer), completion: .contentProcessed { _ in })
                connection.receiveMessage { data, _, _, _ in
                    guard let data, data.count >= 48 else { self.finish(0); return }
                    let deviceAfter = Date().timeIntervalSince1970 * 1000
                    let bytes = [UInt8](data)
                    let serverReceive = QueueEngine.readNtpMillis(bytes, 32)
                    let serverTransmit = QueueEngine.readNtpMillis(bytes, 40)
                    let roundTrip = (deviceAfter - deviceBefore) - (serverTransmit - serverReceive)
                    let serverNow = serverTransmit + max(0, roundTrip / 2)
                    self.finish(Int(serverNow - deviceAfter))
                }
            case .failed, .cancelled:
                self.finish(0)
            default:
                break
            }
        }
        // 这里的 self 强引用是有意的：调用方不持有 probe，弱引用会让它立刻释放、
        // 请求永远不发出。finish() 一定会被调用（超时兜底），届时拆掉连接释放环。
        queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) { [weak self] in
            self?.finish(0)
        }
        connection.start(queue: queue)
    }

    private func finish(_ value: Int) {
        lock.lock()
        if resumed {
            lock.unlock()
            return
        }
        resumed = true
        let connection = self.connection
        self.connection = nil
        lock.unlock()
        connection?.cancel()
        continuation.resume(returning: value)
    }
}

// MARK: - WebSocket 打开回调

/// URLSessionWebSocketTask 没有 onOpen 事件，只能靠 delegate 的 didOpenWithProtocol。
private final class WebSocketOpenRelay: NSObject, URLSessionWebSocketDelegate {
    private let onOpen: @Sendable () -> Void

    init(onOpen: @escaping @Sendable () -> Void) {
        self.onOpen = onOpen
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        onOpen()
    }
}

// MARK: - 可变状态

/// 引擎的全部可变状态。三阶段位、重连退避、ping 网格基准全在这里，
/// 只允许通过 actor 方法读写。
private actor QueueEngineCore {

    private enum Phase: Int {
        case warmup = 0
        case coarse = 1
        case fine = 2
        case highFreq = 3
    }

    private enum QueueStage {
        case none
        case normal
        case crowded
    }

    private enum Settlement {
        case passed
        case alreadyBooked
        case blocked(String)
        case exhausted(String)
    }

    private let cookie: String
    private let userAgent: String
    private let advanceMs: Double
    private let beforeIntervalMs: Double
    private let afterIntervalMs: Double
    private let fallbackOpenTime: String?
    private let listener: QueueEngineListener

    private var cancelled = false
    private var settled = false
    private var reconnectNeeded = false
    /// 复刻旧版 f2192p 的阶段位，防止服务器重复推送把已提速的阶段降回去。
    private var phase: Phase = .warmup
    private var reconnectAttempt = 0
    /// 本条连接最近一次握手成功的时刻，nil 表示本代连接从未握手成功。
    private var openedAt: Date?
    /// 每次重启 ping 循环自增，用来让上一代循环失效，避免旧任务在取消竞态里继续发请求。
    private var pingGeneration = 0
    /// 每次新建连接自增，丢掉上一代连接迟到的 didOpen 回调。
    private var connectionGeneration = 0
    /// 下一发排队请求的绝对时刻（单调时钟纳秒），网格对齐的基准。
    private var nextPingAtNanos: UInt64 = 0
    /// 当前排队档位，复刻旧版 f2192p 的 19/21 状态，避免同一档位反复重置 ping 循环。
    private var queueStage: QueueStage = .none
    /// 已收到未识别消息的条数，配合 maxUnknownMessageLogs 限流。
    private var unknownMessagesLogged = 0
    /// 开放时刻 "HH:mm"，"0" 表示未知。
    private var openTimeText = "0"
    /// 服务器已明确告知开放时刻（此时 openTimeText 可信）。
    private var serverTimeLearned = false
    private var currentIntervalMs: Double = QueueEngine.cookieKeepalivePingMs

    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var pingTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var guardTask: Task<Void, Never>?

    init(cookie: String, userAgent: String, advanceMs: Double, beforeIntervalMs: Double,
         afterIntervalMs: Double, fallbackOpenTime: String?, listener: QueueEngineListener) {
        self.cookie = cookie
        self.userAgent = userAgent
        self.advanceMs = advanceMs
        self.beforeIntervalMs = beforeIntervalMs
        self.afterIntervalMs = afterIntervalMs
        self.fallbackOpenTime = fallbackOpenTime
        self.listener = listener
    }

    // MARK: - 主循环

    func run() async {
        let deadline = Date().addingTimeInterval(QueueEngine.overallTimeoutMs / 1000)
        while !cancelled && !settled {
            if Date() > deadline {
                settle(.exhausted("排队超时（\(Int(QueueEngine.overallTimeoutMs / 60000)) 分钟），任务终止"))
                return
            }
            await connectOnce()
            if settled || cancelled { return }
            // 只有稳定存活过的连接才把退避重置回 10ms；握手即断的握手风暴要继续升级退避。
            if let openedAt = self.openedAt,
               Date().timeIntervalSince(openedAt) >= QueueEngine.stableConnectionMs / 1000 {
                reconnectAttempt = 0
            }
            let backoff = QueueEngine.reconnectBackoffMs[
                min(reconnectAttempt, QueueEngine.reconnectBackoffMs.count - 1)]
            reconnectAttempt += 1
            listener.queueLog("排队通道断开，\(Int(backoff))ms 后重连（第 \(reconnectAttempt) 次）")
            var waited: Double = 0
            while waited < backoff && !cancelled && !settled {
                let step = min(50, backoff - waited)
                do {
                    try await Task.sleep(nanoseconds: UInt64(step * 1_000_000))
                } catch {
                    // 任务被取消：run() 的签名不抛，置位后直接退出，不再补发任何请求。
                    cancelled = true
                    return
                }
                waited += step
            }
        }
    }

    func cancel() {
        cancelled = true
        settle(nil)
    }

    private func isStopped() -> Bool {
        settled || cancelled
    }

    // MARK: - 单次连接

    private func connectOnce() async {
        currentIntervalMs = QueueEngine.cookieKeepalivePingMs
        reconnectNeeded = false
        openedAt = nil
        phase = .warmup
        queueStage = .none
        // 断线重连时不要把已确认的开放时刻丢掉：丢了会退回按本机目标时刻兜底，
        // 开放瞬间的排队间隔会从 80ms 退化成入队间隔。
        if !openTimeUsableAcrossReconnect() {
            openTimeText = "0"
            serverTimeLearned = false
        }

        guard let url = URL(string: QueueEngine.queueURL) else { return }
        connectionGeneration += 1
        let generation = connectionGeneration

        var request = URLRequest(url: url)
        // 握手头复刻原版 N0/x.java:128-138。Upgrade/Connection/Sec-WebSocket-Key 由系统补，
        // 这里手工带的是 Pragma/Cache-Control/Accept-Encoding/Accept-Language 这几项。
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("wechat.v2.traceint.com", forHTTPHeaderField: "Host")
        request.setValue(QueueEngine.origin, forHTTPHeaderField: "Origin")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("13", forHTTPHeaderField: "Sec-WebSocket-Version")
        request.setValue("gzip, deflate, br, zstd", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")

        let relay = WebSocketOpenRelay { [weak self] in
            guard let self else { return }
            Task {
                await self.handleOpened(generation: generation)
            }
        }
        let configuration = URLSessionConfiguration.default
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        // 长跑连接不能被 resource 超时掐断（Android 侧 readTimeout=0，即无限）。
        configuration.timeoutIntervalForResource = .infinity
        let session = URLSession(configuration: configuration, delegate: relay, delegateQueue: nil)
        let socket = session.webSocketTask(with: request)
        self.session = session
        self.socket = socket
        socket.resume()

        // 阻塞等待本条连接出结果；handleServerMessage 会驱动 settled / 阶段切换 / 重连。
        while !settled && !cancelled && !reconnectNeeded {
            do {
                let message = try await socket.receive()
                switch message {
                case .string(let text):
                    handleServerMessage(QueueEngine.decodeUnicodeEscapes(text))
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleServerMessage(QueueEngine.decodeUnicodeEscapes(text))
                    }
                @unknown default:
                    break
                }
            } catch {
                if !settled && !cancelled {
                    QueueEngine.log.warning("排队通道异常: \(error.localizedDescription, privacy: .public)")
                    listener.queueLog("排队通道异常：\(error.localizedDescription)")
                    // 必须置位让外层退出等待并重连：只打日志的话引擎会干等到 30 分钟总超时。
                    reconnectNeeded = true
                }
                break
            }
        }
        teardownConnection()
    }

    private func handleOpened(generation: Int) async {
        guard generation == connectionGeneration, !isStopped() else { return }
        openedAt = Date()
        listener.queueLog("排队通道已连接，等待服务器确认预约开放时间")
        restartPings(intervalMs: QueueEngine.cookieKeepalivePingMs, sendNow: true)
        // 不等服务器的那条"不在预约时间内"也能开始计时：服务器时间未知时用本机目标时刻兜底。
        planStages(reason: "排队通道已连接")
    }

    private func teardownConnection() {
        pingGeneration += 1
        pingTask?.cancel()
        pingTask = nil
        countdownTask?.cancel()
        countdownTask = nil
        guardTask?.cancel()
        guardTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: - 服务器消息

    /// 分派顺序与 Android 完全一致：任何调换都会让"不在预约时间内"这类驱动计时的分支
    /// 被前面的泛匹配吃掉。
    private func handleServerMessage(_ text: String) {
        if isStopped() { return }
        if text.contains("排队成功") || text.contains("不需要排队") {
            listener.queueLog("排队成功")
            restartPings(intervalMs: 0, sendNow: false)
            settle(.passed)
            return
        }
        // 匹配串与旧版 U2.g 同级：必须紧跟 "data":，否则同一帧里的其他文案会被抢进人数
        // 分支，挡住后面"不在预约时间内"的判断（那个判断才负责驱动三阶段计时）。
        if text.contains("prereserve/queue\",\"code\":0,\"data\":") {
            let position = QueueEngine.parseQueuePosition(text)
            listener.queueLog("排队中，前方还有 \(position) 人（间隔 \(Int(currentIntervalMs))ms）")
            // 已进入高频就不再改档，避免在开放瞬间之前把节奏拉回 500ms/1000ms；
            // 低频等待期同样保持 30s 档，不为排队人数整段时间抬高请求量。
            if phase.rawValue >= Phase.highFreq.rawValue || phase == .coarse { return }
            if position > QueueEngine.crowdedQueueThreshold {
                if queueStage != .crowded {
                    queueStage = .crowded
                    listener.queueLog("前方超过 \(QueueEngine.crowdedQueueThreshold) 人，排队请求间隔放宽到 "
                        + "\(Int(QueueEngine.crowdedQueuePingMs))ms")
                    restartPings(intervalMs: QueueEngine.crowdedQueuePingMs, sendNow: false)
                }
            } else if queueStage != .normal {
                queueStage = .normal
                listener.queueLog("已进入队列且前方不超过 \(QueueEngine.crowdedQueueThreshold)"
                    + " 人，排队请求间隔 \(Int(afterIntervalMs))ms")
                restartPings(intervalMs: afterIntervalMs, sendNow: false)
            }
            return
        }
        if text.contains("不在预约时间内") || text.contains("未开始") {
            if !serverTimeLearned {
                if let regex = QueueEngine.openTimeRegex,
                   let match = regex.firstMatch(in: text, options: [],
                                                range: NSRange(text.startIndex..<text.endIndex, in: text)),
                   let range = Range(match.range(at: 1), in: text) {
                    serverTimeLearned = true
                    openTimeText = String(text[range])
                    listener.queueLog("服务器告知预约开放时间：\(openTimeText)")
                } else {
                    listener.queueLog("服务器未告知具体开放时间，改用本机目标时刻计时")
                }
            }
            planStages(reason: "服务器提示尚未开放")
            upgradeHighFrequencyIfConfirmed()
            return
        }
        if text.contains("被关闭") {
            listener.queueLog("学校明日预约功能已被关闭")
            settle(.blocked("学校明日预约功能已被关闭"))
            return
        }
        if text.contains("你已经成功登记了明天的") || text.contains("已经成功登记") {
            listener.queueLog("服务器反馈已登记过明天的座位")
            settle(.alreadyBooked)
            return
        }
        if text.contains("获取用户信息失败") {
            listener.queueLog("服务器返回获取用户信息失败（请求过频），准备重连")
            restartPings(intervalMs: 0, sendNow: false)
            // 复刻旧版 RealWebSocket.cancel()：强断以触发 receive 失败 → 外层退避重连。
            reconnectNeeded = true
            socket?.cancel(with: .abnormalClosure, reason: nil)
            return
        }
        // 走到这里说明消息没命中任何分支。这种消息以前被静默丢弃，排障时完全看不到服务器到底说了什么。
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && unknownMessagesLogged < QueueEngine.maxUnknownMessageLogs {
            unknownMessagesLogged += 1
            listener.queueLog("未识别的排队消息：" + QueueEngine.abbreviate(text))
        }
    }

    // MARK: - 三阶段

    /// 三阶段规划：由排队通道打开或服务器推送触发，按当前开放时刻决定 ping 档位与倒计时。
    /// 各阶段只推进不后退，重复调用安全。
    private func planStages(reason: String) {
        if phase.rawValue >= Phase.highFreq.rawValue { return }
        if !openTimeUsable() { return }
        let millisUntilOpen = self.millisUntilOpen()
        if millisUntilOpen <= advanceMs {
            enterHighFrequency(logLine: reason + "：已到达开放时间前 \(Int(advanceMs))ms")
            return
        }
        if millisUntilOpen <= QueueEngine.fineCountdownWindowSeconds * 1000 {
            enterFineCountdown(logLine: reason + "：距开放 \(Int(millisUntilOpen / 1000))s")
            return
        }
        if phase.rawValue < Phase.coarse.rawValue {
            phase = .coarse
            let coarseTarget = millisUntilOpen - QueueEngine.coarseCountdownLeadMs - advanceMs
            listener.queueLog(reason + "：距开放 \(Int(millisUntilOpen / 1000))s，低频等待（"
                + "\(Int(QueueEngine.coarseWaitPingMs))ms）+ 粗倒计时 \(Int(coarseTarget))ms")
            restartPings(intervalMs: QueueEngine.coarseWaitPingMs, sendNow: false)
            startCountdown(targetMs: coarseTarget, tickMs: 500, nextPhase: .fine)
            startCoarseGuard()
        }
    }

    /// 距开放毫秒数：服务器告知的时间优先，其次用本机目标时刻兜底。
    /// 两者都没有（或本机目标已过）时返回 0 —— 此时不要据此判断"已开放"。
    private func millisUntilOpen() -> Double {
        if serverTimeLearned { return QueueEngine.millisUntilToday(openTimeText) }
        if let fallbackOpenTime = self.fallbackOpenTime {
            let millis = QueueEngine.millisUntilToday(fallbackOpenTime)
            if millis > 0 { return millis }
        }
        return 0
    }

    /// 是否已有可用的开放时刻：服务器告知，或本机目标时刻尚未过期。
    private func openTimeUsable() -> Bool {
        if serverTimeLearned { return true }
        guard let fallbackOpenTime = self.fallbackOpenTime else { return false }
        return QueueEngine.millisUntilToday(fallbackOpenTime) > 0
    }

    /// 服务器告知的开放时刻是否值得跨重连带过去（含刚过开放时刻的宽容窗口）。
    private func openTimeUsableAcrossReconnect() -> Bool {
        if !serverTimeLearned { return false }
        return QueueEngine.millisUntilToday(openTimeText) > -QueueEngine.openTimeCarryOverMs
    }

    /// 进入细倒计时阶段：按当前时刻重算到"开放前 advanceMs"的剩余量，再起 50ms 粒度倒计时。
    private func enterFineCountdown(logLine: String) {
        if phase.rawValue >= Phase.fine.rawValue { return }
        phase = .fine
        cancelGuard()
        restartPings(intervalMs: QueueEngine.cookieKeepalivePingMs, sendNow: false)
        let target = max(0, millisUntilOpen() - advanceMs)
        listener.queueLog(logLine + "：进入细倒计时，距高频排队还有 \(Int(target))ms")
        startCountdown(targetMs: target, tickMs: 50, nextPhase: .highFreq)
    }

    /// 进入高频排队阶段。服务器已告知开放时间时用高频间隔；
    /// 只靠本机目标时刻兜底时退到入队间隔，因为兜底时刻未必等于真实开放时间。
    private func enterHighFrequency(logLine: String) {
        if phase.rawValue >= Phase.highFreq.rawValue { return }
        phase = .highFreq
        cancelGuard()
        let interval = serverTimeLearned ? beforeIntervalMs : afterIntervalMs
        listener.queueLog(logLine + "，切换高频排队（间隔 \(Int(interval))ms，距开放 "
            + "\(Int(millisUntilOpen() / 1000))s）")
        restartPings(intervalMs: interval, sendNow: false)
    }

    /// 兜底时刻先推进到高频、之后才拿到服务器开放时间时，按高频间隔重排一次。
    private func upgradeHighFrequencyIfConfirmed() {
        if phase.rawValue < Phase.highFreq.rawValue || !serverTimeLearned { return }
        let interval = beforeIntervalMs
        if currentIntervalMs == interval { return }
        if millisUntilOpen() <= advanceMs {
            listener.queueLog("已取得服务器开放时间，排队请求间隔收紧到 \(Int(interval))ms")
            restartPings(intervalMs: interval, sendNow: false)
        }
    }

    /// 以 tickMs 粒度倒计时到 targetMs 之后，无条件推进到 nextPhase。
    ///
    /// 推进只看阶段位、不回查墙钟：到点时刻回查"剩余量 ≤ advanceMs"是错的——粗倒计时到期时
    /// 距开放还有约 10s，条件必然为假，倒计时又已自取消且不重排，于是永久停在低频档。
    /// 这里改用绝对时刻判断而不是逐 tick 累减，定时器被系统冻结或单次回调延迟都不会让
    /// 剩余量算多，恢复后第一拍就能发现已到点。
    private func startCountdown(targetMs: Double, tickMs: Double, nextPhase: Phase) {
        countdownTask?.cancel()
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, targetMs) * 1_000_000)
        let tickNanos = UInt64(max(1, tickMs) * 1_000_000)
        countdownTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, await self.isStopped() == false else { return }
                if DispatchTime.now().uptimeNanoseconds >= deadline { break }
                do {
                    try await Task.sleep(nanoseconds: tickNanos)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, let self, await self.isStopped() == false else { return }
            await self.advanceFromCountdown(nextPhase)
        }
    }

    private func advanceFromCountdown(_ nextPhase: Phase) {
        switch nextPhase {
        case .fine:
            enterFineCountdown(logLine: "粗倒计时结束")
        case .highFreq:
            enterHighFrequency(logLine: "细倒计时结束")
        case .warmup, .coarse:
            break
        }
    }

    /// 低频阶段的独立看门狗，复刻旧版 B1/c.java case 10：每秒按真实时刻重算剩余量，
    /// 进入"距高频排队不足 8s"就推进到细倒计时。倒计时靠 Task 驱动，进程被冻结
    /// （息屏 / 后台）时会一并停摆，这条并行路径保证仍能按真实时间提速。
    private func startCoarseGuard() {
        cancelGuard()
        guardTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
                guard let self, await self.isStopped() == false else { return }
                let shouldAdvance: Bool = await self.checkCoarseGuard()
                if shouldAdvance { return }
            }
        }
    }

    private func checkCoarseGuard() -> Bool {
        if isStopped() || phase.rawValue >= Phase.fine.rawValue { return true }
        if !openTimeUsable() { return false }
        let remainToHighFreq = millisUntilOpen() - advanceMs
        if remainToHighFreq <= QueueEngine.coarseGuardTriggerMs {
            enterFineCountdown(logLine: "看门狗：距高频排队仅 \(Int(remainToHighFreq))ms")
            return true
        }
        return false
    }

    private func cancelGuard() {
        guardTask?.cancel()
        guardTask = nil
    }

    // MARK: - ping 网格

    /// 重置 ping 循环。sendNow 为真时立刻发一次（首连时用，尽快拿到服务器的开放时间），
    /// 之后按 intervalMs 的网格排下一发。
    private func restartPings(intervalMs: Double, sendNow: Bool) {
        currentIntervalMs = intervalMs
        pingGeneration += 1
        pingTask?.cancel()
        pingTask = nil
        guard intervalMs > 0, let socket = self.socket else { return }
        nextPingAtNanos = DispatchTime.now().uptimeNanoseconds
            + (sendNow ? 0 : UInt64(intervalMs * 1_000_000))
        let generation = pingGeneration
        pingTask = Task { [weak self] in
            guard let self else { return }
            await self.runPingGrid(socket: socket, intervalMs: intervalMs, generation: generation)
        }
    }

    /// 复刻旧版 N0.t 的排队 ping 循环：每发完一次就把下一发排在固定的绝对时间网格上，
    /// 落后时对齐到网格的下一点。既不会像累加计时那样越跑越偏，也不会像 fixed-rate 那样
    /// 在系统冻结恢复后连续补发一串请求。
    private func runPingGrid(socket: URLSessionWebSocketTask, intervalMs: Double, generation: Int) async {
        let intervalNanos = UInt64(intervalMs * 1_000_000)
        while !Task.isCancelled && !isStopped() && generation == pingGeneration {
            let now = DispatchTime.now().uptimeNanoseconds
            let delay = nextPingAtNanos > now ? nextPingAtNanos - now : 0
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
            if Task.isCancelled || isStopped() || generation != pingGeneration { return }
            socket.send(.string(QueueEngine.pingPayload)) { _ in
                // 发送失败由 receive 的异常统一走重连，这里不重复处理。
            }
            var next = nextPingAtNanos + intervalNanos
            let after = DispatchTime.now().uptimeNanoseconds
            if after > next {
                let behind = after - next
                next += ((behind + intervalNanos - 1) / intervalNanos) * intervalNanos
            }
            nextPingAtNanos = next
        }
    }

    // MARK: - 收尾

    private func settle(_ result: Settlement?) {
        if settled { return }
        settled = true
        teardownConnection()
        guard !cancelled, let result else { return }
        switch result {
        case .passed:
            listener.queuePassed()
        case .alreadyBooked:
            listener.queueAlreadyBooked()
        case .blocked(let message):
            listener.queueBlocked(message)
        case .exhausted(let message):
            listener.queueExhausted(message)
        }
    }
}

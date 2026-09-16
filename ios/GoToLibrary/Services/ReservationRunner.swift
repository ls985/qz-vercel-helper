// 对应 Android 侧 com.gotolibrary.app.ReservationService（前台服务）。
//
// iOS 平台差异（如实处理，不假装）：
// - 没有前台服务，也没有 WakeLock。这里用 `UIApplication.isIdleTimerDisabled` 让屏幕在
//   任务期间保持常亮（用户锁屏 = 任务停摆），并在启动时申请一次 `beginBackgroundTask`
//   换取约 30 秒的额外后台时间。
// - 后台额度耗尽时把任务状态置为"已挂起"并发一条本地通知让用户回到应用，
//   **不**用音视频后台模式或静默播放去骗后台时间（那既会被审核拒绝，也是欺骗用户）。
//   用户回到前台后任务自动从当前真实时刻重算并继续（所有等待都按绝对时刻判断）。
// - 保活被系统挂起期间，进程冻结，任何 Task 都不再被调度；恢复后第一拍就按墙钟重算。
import Foundation
import Combine
import UIKit

@MainActor
final class ReservationRunner: ObservableObject {

    static let shared = ReservationRunner()

    @Published private(set) var running: Bool = false
    @Published private(set) var statusTitle: String = ""
    @Published private(set) var statusDetail: String = ""
    @Published private(set) var countdownMs: Int = 0

    // 复刻旧版尝试链（H0.v）的共享延迟模型：链起步 1000ms，"重新尝试"每重试一次
    // 在上一等待的基础上 +300ms，"该座位已经被"把共享延迟重置为 1100ms。
    static let chainDelayStartMs: Double = 1000
    static let chainDelayGrowStepMs: Double = 300
    static let seatTakenDelayMs: Double = 1100
    /// 场馆未开放自动等待的重查间隔（旧版 floor_list_refresh_interval，默认 500ms）。
    static let venueRecheckMs: Double = 500
    /// 今日座位表轮询间隔（旧版 seat_list_refresh_interval，默认 600ms）。
    static let todayScanIntervalMs: Double = 600
    /// 同一座位验证码类重试的安全上限（旧版把上限放在打码侧，这里再加一道防死循环）。
    static let captchaRetryCap = 20
    /// 提前接入排队通道的秒数。要覆盖 NTP 校时、WebSocket 握手、拿到服务器开放时间，
    /// 并给断开重连的退避（最长 8s）留余量；实测校时+握手约 200ms，30s 已是十倍余量。
    static let queueLeadSeconds: Double = 30

    private static let tomorrowFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()
    private static let shanghai: TimeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current

    private var task: Task<Void, Never>?
    private var engine: QueueEngine?
    private var bridge: QueueBridge?
    private var solver: CaptchaSolver?
    private var traceintUserId = ""
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    /// 后台额度耗尽后置位；回到前台清除。任务循环本身不停（进程冻结时它也跑不动），
    /// 但状态必须如实显示"已挂起"。
    private var suspendedByBackground = false
    private var observers: [NSObjectProtocol] = []

    private init() {}

    // MARK: - 生命周期

    /// 启动任务。非结构化 Task：不受调用方（通常是某个 View 的 .task）取消影响，
    /// 只能由 stop() 结束，避免用户切页面就把抢座任务带停。
    func start() async {
        if running { return }
        // 执行边界二次校验：门禁只是 UI 层，任务真正下发前必须再验一次签名凭证，
        // 防止会员失效后任务继续占用抢座通道。
        guard LicenseManager.isUsable() else {
            AppConfig.setRunning(false)
            running = false
            updateState("任务已暂停", "会员状态校验未通过，请先激活会员", -1)
            log("预约任务被拒绝：会员状态校验未通过")
            return
        }
        let cookie = AppConfig.cookie()
        if cookie.trimmingCharacters(in: .whitespaces).isEmpty || AppConfig.roomId() == 0 {
            failAndStop(title: "配置不完整", detail: "请重新登录并选择阅览室")
            return
        }
        running = true
        AppConfig.setRunning(true)
        // 锁屏即停摆，先把屏幕常亮打开，让用户至少知道要保持前台。
        UIApplication.shared.isIdleTimerDisabled = true
        beginBackgroundTime()
        registerObservers()
        updateState("正在启动", "正在检查本机配置", -1)
        log("预约任务已启动（iOS 前台运行模式：锁屏或切后台会被系统挂起）")
        task = Task { [weak self] in
            guard let self else { return }
            await self.runConfiguredTask()
        }
    }

    func stop() {
        if !running && !AppConfig.running() { return }
        running = false
        task?.cancel()
        task = nil
        // 排队引擎卡在 WebSocket receive 上，必须显式打断，否则收尾会一直挂在那儿。
        engine?.cancel()
        bridge?.cancelWaiting()
        finishTask(title: "任务已停止", detail: "任务已由用户停止")
    }

    // MARK: - 任务配置与分派

    private func runConfiguredTask() async {
        let roomId = AppConfig.roomId()
        let storedName = AppConfig.roomName()
        let roomName = storedName.trimmingCharacters(in: .whitespaces).isEmpty
            ? String(roomId) : storedName
        let mode = AppConfig.mode()
        let preferred = AppConfig.selectedSeats()

        // 复刻旧版 DoReserveService：明日预约模式下自动开启 Cookie 保活，
        // 否则漫长的等待期会把登录状态耗到失效。
        if mode == AppConfig.modeTomorrow && AppConfig.keepCookieAutoTomorrow()
            && !SessionKeeper.shared.running {
            await SessionKeeper.shared.start()
            log("明日预约模式，已自动开启 Cookie 保活")
        }

        let client = TraceintClient(cookie: AppConfig.cookie()) { refreshed in
            _ = AppConfig.setCookie(refreshed)
        }
        solver = CaptchaSolver()
        traceintUserId = ""

        do {
            if mode == AppConfig.modeTomorrow {
                try await runTomorrow(client: client, roomId: roomId, roomName: roomName, preferred: preferred)
            } else {
                try await runRealtime(client: client, roomId: roomId, roomName: roomName, preferred: preferred)
            }
        } catch is CancellationError {
            // stop() 已经写过终态，这里只需要把取消传播到位、不再覆盖状态。
        } catch {
            guard running else { return }
            let message = friendlyError(error)
            if TraceintClient.isSessionExpired(message) {
                expireSessionAndStop(message)
            } else {
                failAndStop(title: "任务已停止", detail: message)
            }
        }
    }

    // MARK: - 今日模式

    private func runRealtime(client: TraceintClient, roomId: Int, roomName: String,
                             preferred: [String]) async throws {
        var round = 0
        var lastNoSeatLog = Date.distantPast
        var backoff: Double = 0
        log("实时抢座已启动：\(roomName)")
        updateState("实时抢座运行中", roomName + " · 正在监控空位", -1)

        while running {
            do {
                round += 1
                let seats = try await client.fetchSeats(roomId: roomId)
                // 复刻旧版今日模式：只在指定座位（未指定则全部空位）里选，不做捡漏回退；
                // 只有"暂时没有空位"才按 todayScanIntervalMs 继续扫。
                let candidates = TraceintClient.chooseCandidates(seats, preferred: preferred,
                                                                freeOnly: true, allowOther: false).list
                if candidates.isEmpty {
                    if Date().timeIntervalSince(lastNoSeatLog) >= 5 {
                        lastNoSeatLog = Date()
                        log("第 \(round) 轮：暂时没有符合条件的空位")
                    }
                    try await sleepMs(ReservationRunner.todayScanIntervalMs)
                    continue
                }
                updateState("发现空位", "正在尝试 \(candidates.count) 个候选座位", -1)
                let chain = try await runAttemptChain(client: client, roomId: roomId,
                                                      candidates: candidates, tomorrow: false,
                                                      prefetched: nil, roomName: roomName)
                if chain == .finished { return }
                if chain == .venueWait {
                    try await sleepMs(ReservationRunner.venueRecheckMs)
                    continue
                }
                // 复刻旧版 H0.v：今日模式尝试链跑完即结束任务，不回头继续扫。
                failAndStop(title: "已尝试所有座位，均未成功",
                            detail: roomName + " · 空位尝试均未成功，任务结束")
                return
            } catch let error as CancellationError {
                throw error
            } catch {
                if Task.isCancelled || !running { throw CancellationError() }
                let message = friendlyError(error)
                if TraceintClient.isSessionExpired(message) {
                    expireSessionAndStop(message)
                    return
                }
                if TraceintClient.isRiskMessage(message) {
                    failAndStop(title: "账号保护已触发", detail: message)
                    return
                }
                backoff = min(12000, backoff == 0 ? 1500 : (backoff * 1.6).rounded())
                log("轮询失败：\(message)，稍后重试")
                updateState("网络重试中", "将在 \(max(1, Int(backoff / 1000))) 秒后继续", -1)
                try await sleepMs(backoff)
            }
        }
    }

    // MARK: - 明日模式

    private func runTomorrow(client: TraceintClient, roomId: Int, roomName: String,
                             preferred: [String]) async throws {
        var roomSeats = try await client.fetchSeats(roomId: roomId)
        roomSeats.removeAll { $0.type != 1
            || $0.key.trimmingCharacters(in: .whitespaces).isEmpty
            || $0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        if roomSeats.isEmpty { throw TraceintClient.ApiError(message: "当前阅览室没有可预约座位") }

        let target = nextRunAt(AppConfig.tomorrowTime())
        let targetText = ReservationRunner.tomorrowFormatter.string(from: target)
        // 提前 QUEUE_LEAD_SECONDS 接入排队通道，之后由服务器告知的开放时间驱动三阶段计时。
        let connectAt = target.addingTimeInterval(-ReservationRunner.queueLeadSeconds)
        log("明日预约已启动：\(roomName)，\(targetText) 开始监控")

        // 每秒刷新一次：界面倒计时必须实时跳动，不能一分钟才跳一格。
        // 剩余量按绝对目标时刻重算，进程被冻结后恢复也能立刻回到正确剩余量。
        while running {
            let remaining = connectAt.timeIntervalSinceNow * 1000
            if remaining <= 0 { break }
            updateState("等待明日预约",
                        roomName + " · " + targetText + " 开始（还剩 \(formatRemaining(remaining))）",
                        Int(remaining))
            try await sleepMs(min(remaining, 1000))
        }
        if !running { return }

        updateState("进入预约队列", roomName + " · 正在连接排队通道", -1)
        let queue = await runQueueEngine(fallbackOpenTime: hourMinute(target))
        log("排队通道：\(queue.message)")
        if case .alreadyBooked = queue {
            failAndStop(title: "已登记过座位", detail: "服务器反馈该账号已登记明天的座位，任务结束")
            return
        }
        guard case .passed = queue else {
            failAndStop(title: "明日预约未进入队列", detail: queue.message)
            return
        }

        var detailedSupported = true
        // 复刻旧版 prefetchCaptchaTomorrow：排队成功后先备好一张验证码，
        // 命中空位时省掉取图+识别约 1s 的等待。
        let prefetched = PrefetchBox()
        if AppConfig.captchaAutoSolve() && AppConfig.prefetchCaptcha() {
            log("已开启预先获取验证码，正在预先识别…")
            do {
                prefetched.value = try await fetchAndSolveCaptcha(client: client, tomorrow: true, seatName: "预取")
                if let value = prefetched.value {
                    log("预先识别验证码成功：\(value.answer)")
                } else {
                    log("预先获取验证码失败，将在提交时按需识别")
                }
            } catch let error as CancellationError {
                throw error
            } catch {
                if Task.isCancelled || !running { throw CancellationError() }
                let message = friendlyError(error)
                if TraceintClient.isSessionExpired(message) {
                    expireSessionAndStop(message)
                    return
                }
                log("预先获取验证码失败：\(message)")
            }
        }

        // 复刻旧版 N0.u.a/H0.v 的明日模型：排队成功后先选指定座位跑一轮尝试链，
        // 链耗尽或没有指定座位空位时，若开了捡漏就重查一遍全部空位再跑一轮；
        // 两轮都抢不到就结束任务 —— 明日的座位被抢完基本不会回吐，持续轮询没有意义。
        var leakPass = false
        updateState("明日预约运行中", roomName + " · 排队已通过，正在选座", -1)
        while running {
            let availability: TraceintClient.TomorrowAvailability
            do {
                availability = try await client.fetchTomorrowAvailability(roomId: roomId,
                                                                          includeSeats: detailedSupported)
            } catch let error as CancellationError {
                throw error
            } catch {
                if Task.isCancelled || !running { throw CancellationError() }
                let message = friendlyError(error)
                // 服务器不提供座位明细时降级：只用阅览室座位表，不看明日余量。
                if detailedSupported && ReservationRunner.matches(message, "(?is).*(unknown field|cannot query field).*seats.*") {
                    detailedSupported = false
                    log("明日接口不提供座位明细，已切换兼容模式")
                    continue
                }
                if TraceintClient.isSessionExpired(message) {
                    expireSessionAndStop(message)
                    return
                }
                if TraceintClient.isRiskMessage(message) {
                    failAndStop(title: "账号保护已触发", detail: message)
                    return
                }
                log("明日空位读取失败：\(message)")
                try await sleepMs(8000)
                continue
            }

            let pool = detailedSupported ? availability.seats : roomSeats
            var candidates: [TraceintClient.Seat]
            if leakPass {
                candidates = pool.filter { TraceintClient.isFree($0) }
                log("捡漏：全部空闲座位 \(candidates.count) 个")
            } else {
                candidates = TraceintClient.chooseCandidates(pool, preferred: preferred,
                                                             freeOnly: detailedSupported,
                                                             allowOther: false).list
            }
            if let available = availability.available, available == 0 { candidates.removeAll() }

            if candidates.isEmpty {
                if !leakPass && AppConfig.autoGrabOther() {
                    log("指定座位没有空位，开始捡漏其他可用座位（可在设置中关闭）")
                    leakPass = true
                    continue
                }
                failAndStop(title: "明日预约，已无可用空闲座位",
                            detail: roomName + " · " + (leakPass ? "捡漏" : "指定座位") + "均无空位，任务结束")
                return
            }
            updateState("发现明日空位", "正在尝试 \(candidates.count) 个候选座位", -1)
            let chain = try await runAttemptChain(client: client, roomId: roomId,
                                                  candidates: candidates, tomorrow: true,
                                                  prefetched: prefetched, roomName: roomName)
            if chain == .finished { return }
            if chain == .venueWait {
                try await sleepMs(ReservationRunner.venueRecheckMs)
                continue
            }
            if !leakPass && AppConfig.autoGrabOther() {
                log("已尝试所有指定座位，开始捡漏其他可用座位（可在设置中关闭）")
                leakPass = true
                continue
            }
            failAndStop(title: "已尝试所有座位，均未成功",
                        detail: roomName + " · 空位尝试均未成功，任务结束")
            return
        }
    }

    /// 今日/明日的目标时刻：取下一个不早于当前时刻的 "HH:mm:ss"（上海时区），
    /// 解析失败按 20:00 处理（与 Android 的兜底一致）。
    private func nextRunAt(_ value: String) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ReservationRunner.shanghai
        let parts = value.split(separator: ":")
        let hour = parts.count > 0 ? (Int(parts[0].trimmingCharacters(in: .whitespaces)) ?? 20) : 20
        let minute = parts.count > 1 ? (Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0) : 0
        let second = parts.count > 2 ? (Int(parts[2].trimmingCharacters(in: .whitespaces)) ?? 0) : 0
        let now = Date()
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = second
        components.nanosecond = 0
        guard let sameDay = calendar.date(from: components) else { return now }
        if sameDay > now { return sameDay }
        return calendar.date(byAdding: .day, value: 1, to: sameDay) ?? sameDay
    }

    private func hourMinute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = ReservationRunner.shanghai
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func formatRemaining(_ millis: Double) -> String {
        let totalSeconds = max(0, Int(millis / 1000))
        return String(format: "%02d:%02d:%02d", totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60)
    }

    // MARK: - 排队引擎

    /// 连接排队通道并等待出结果；任务被用户停止时返回 failed("任务被停止")。
    private func runQueueEngine(fallbackOpenTime: String) async -> QueueOutcome {
        let advanceMs = await computeAdvanceMs()
        let beforeInterval = Double(AppConfig.queueBeforeInterval())
        let afterInterval = Double(AppConfig.queueAfterInterval())
        log("排队参数：提前量 \(Int(advanceMs))ms，高频间隔 \(Int(beforeInterval))ms，入队间隔 \(Int(afterInterval))ms")

        let bridge = QueueBridge { message in AppConfig.addLog(message) }
        let engine = QueueEngine(cookie: AppConfig.cookie(),
                                 userAgent: TraceintClient.websocketUA,
                                 advanceMs: advanceMs,
                                 beforeIntervalMs: beforeInterval,
                                 afterIntervalMs: afterInterval,
                                 fallbackOpenTime: fallbackOpenTime,
                                 listener: bridge)
        self.bridge = bridge
        self.engine = engine
        let engineTask = Task { await engine.run() }
        let outcome = await bridge.waitForOutcome()
        engine.cancel()
        _ = await engineTask.value
        self.engine = nil
        self.bridge = nil
        return outcome
    }

    /// 复刻旧版 X0.k 的提前量推算：NTP 校时 ntp.aliyun.com，
    /// 本机慢 offset ms → 提前量 = offset + 150ms；本机快 → 350ms − 快的毫秒数；
    /// 手动模式用用户设置值。
    private func computeAdvanceMs() async -> Double {
        if !AppConfig.queueAdvanceAuto() {
            let manual = Double(AppConfig.queueAdvanceMs())
            log("手动设置提前排队时间：\(Int(manual))ms")
            return manual
        }
        let offset = await QueueEngine.queryClockOffsetMs(host: QueueEngine.ntpHost,
                                                          timeoutMs: QueueEngine.ntpTimeoutMs)
        let advance: Double
        if offset > 0 {
            advance = Double(offset) + 150
            log("自动校时：本机比北京时间慢 \(offset)ms")
        } else {
            advance = 350 + Double(offset)
            log("自动校时：本机比北京时间快 \(-offset)ms")
        }
        log("已自动设置提前排队时间为 \(Int(advance))ms")
        return advance
    }

    // MARK: - 尝试链

    private enum ChainResult {
        case exhausted
        case venueWait
        case finished
    }

    private enum BookingAction {
        case success
        case alreadyBooked
        case retrySameSeat
        case retrySameSeatGrow
        case seatTaken
        case nextSeat
        case abort
        case venueClosed
    }

    private struct BookingDecision {
        let action: BookingAction
        let delayMs: Double
        let message: String
    }

    private struct SolvedCaptcha {
        let answer: String
        let serverCode: String
        let uniqueCode: String?
    }

    /// 预取验证码的单槽容器。attemptBooking 消费后置空，与 Android 的数组单槽语义一致。
    private final class PrefetchBox {
        var value: SolvedCaptcha?
    }

    /// 尝试链：逐个座位跑 attemptBooking 并按旧版 N0.u.b/H0.v 的分派推进。
    /// finished 表示已经写下终态（调用方直接收工），venueWait 表示场馆未开放
    /// （调用方按 venueRecheckMs 重查后继续），exhausted 表示候选耗尽
    /// （由调用方决定转捡漏还是结束任务）。
    private func runAttemptChain(client: TraceintClient, roomId: Int,
                                 candidates: [TraceintClient.Seat], tomorrow: Bool,
                                 prefetched: PrefetchBox?, roomName: String) async throws -> ChainResult {
        var seatRetries = 0
        var chainDelayMs = ReservationRunner.chainDelayStartMs
        var index = 0
        while running && index < candidates.count {
            let seat = candidates[index]
            do {
                log("尝试座位 \(seat.name)")
                let decision = try await attemptBooking(client: client, roomId: roomId, seat: seat,
                                                        tomorrow: tomorrow, prefetched: prefetched)
                switch decision.action {
                case .success:
                    if tomorrow {
                        do {
                            let verified = try await client.verifyTomorrow(roomId: roomId, seat: seat)
                            successAndStop(title: verified ? "明日预约成功" : "预约已提交",
                                           detail: roomName + " · " + seat.name
                                               + (verified ? "" : "（请在官方页面复核）"))
                        } catch {
                            log("预约已提交，但结果复核失败：\(friendlyError(error))")
                            successAndStop(title: "预约已提交",
                                           detail: roomName + " · " + seat.name + "（请在官方页面复核）")
                        }
                    } else {
                        successAndStop(title: "预约成功", detail: roomName + " · " + seat.name)
                    }
                    return .finished
                case .alreadyBooked:
                    successAndStop(title: tomorrow ? "已登记过座位" : "已有座位",
                                   detail: roomName + " · 该账号已" + (tomorrow ? "登记" : "预约") + "过座位")
                    return .finished
                case .abort:
                    failAndStop(title: "预约被拒", detail: friendlyMessage(decision.message))
                    return .finished
                case .venueClosed:
                    if !AppConfig.venueAutoWait() {
                        failAndStop(title: "场馆未开放",
                                    detail: friendlyMessage(decision.message)
                                        + "。如需开放后自动预约，请在设置中开启“场馆未开放自动等待”")
                        return .finished
                    }
                    log("场馆尚未开放，\(Int(ReservationRunner.venueRecheckMs))ms 后重查："
                        + friendlyMessage(decision.message))
                    updateState("等待场馆开放", roomName + " · 稍后重试", -1)
                    return .venueWait
                case .retrySameSeat:
                    try await sleepMs(decision.delayMs)
                    seatRetries += 1
                    if seatRetries <= ReservationRunner.captchaRetryCap {
                        continue // 同座位重试
                    }
                    log("座位 \(seat.name) 重试已达上限，转入下一座位")
                    index += 1
                case .retrySameSeatGrow:
                    // 旧版无上限，延迟累进（1000→1300→1600…）本身就会自然放缓。
                    try await sleepMs(chainDelayMs)
                    chainDelayMs += ReservationRunner.chainDelayGrowStepMs
                    continue // 同座位重试
                case .seatTaken:
                    seatRetries = 0
                    chainDelayMs = ReservationRunner.seatTakenDelayMs
                    try await sleepMs(decision.delayMs)
                    index += 1
                case .nextSeat:
                    seatRetries = 0
                    try await sleepMs(decision.delayMs)
                    index += 1
                }
            } catch let error as CancellationError {
                throw error
            } catch {
                if Task.isCancelled || !running { throw CancellationError() }
                let message = friendlyError(error)
                if TraceintClient.isSessionExpired(message) {
                    expireSessionAndStop(message)
                    return .finished
                }
                // 风控文案向上抛，由今日/明日的外层统一判"账号保护已触发"并停任务。
                if TraceintClient.isRiskMessage(message) { throw error }
                log("座位 \(seat.name) 未预约成功：\(message)")
                index += 1
            }
        }
        return .exhausted
    }

    /// 单次预约尝试（含验证码流水线）。响应分派的关键字顺序**必须**与
    /// Android ReservationService.java:554-599 逐条一致，顺序错了行为就变。
    /// prefetched 非空时优先消费预取的验证码（复刻旧版预先获取验证码功能）。
    private func attemptBooking(client: TraceintClient, roomId: Int, seat: TraceintClient.Seat,
                                tomorrow: Bool, prefetched: PrefetchBox?) async throws -> BookingDecision {
        var captchaAnswer = ""
        var captchaServerCode = ""
        var uniqueCode: String?
        var captchaUsed = false
        var solved: SolvedCaptcha?
        if let box = prefetched, let value = box.value {
            solved = value
            box.value = nil
            log("使用预先识别的验证码: \(value.answer)（座位 \(seat.name)）")
        } else if AppConfig.captchaAutoSolve() {
            solved = try await fetchAndSolveCaptcha(client: client, tomorrow: tomorrow, seatName: seat.name)
        }
        if let solved {
            captchaAnswer = solved.answer
            captchaServerCode = solved.serverCode
            uniqueCode = solved.uniqueCode
            captchaUsed = true
        }

        let outcome: TraceintClient.ReserveOutcome
        if tomorrow {
            outcome = try await client.reserveTomorrow(roomId: roomId, seat: seat,
                                                       captcha: captchaAnswer, captchaCode: captchaServerCode)
        } else {
            outcome = try await client.reserveSeat(roomId: roomId, seat: seat,
                                                   captcha: captchaAnswer, captchaCode: captchaServerCode)
        }
        let message = outcome.message
        if outcome.success {
            if captchaUsed { log("预约成功（座位 \(seat.name)），核减一次验证码识别次数。") }
            return BookingDecision(action: .success, delayMs: 0, message: message)
        }
        if message.contains("您已经预定了座位") || message.contains("已经预约")
            || message.contains("已预定") {
            if captchaUsed { log("已预约过座位，核减一次验证码识别次数。") }
            return BookingDecision(action: .alreadyBooked, delayMs: 0, message: message)
        }
        if message.contains("输入验证码") {
            if let uniqueCode { await solver?.refund(uniqueCode: uniqueCode) }
            if !AppConfig.captchaAutoSolve() {
                // 自动识别已关闭：再拿空验证码重试同座位也只会拿到同一句提示，
                // 直接换下一个座位，避免在同一个座位上耗满 20 次重试。
                log("服务器要求验证码，但自动识别已关闭，转入下一座位")
                return BookingDecision(action: .nextSeat, delayMs: 1000, message: message)
            }
            if !captchaUsed {
                log("服务器要求验证码，1 秒后补识别重试同座位")
            } else {
                log("验证码被判错误，已退码，1 秒后重新识别重试")
            }
            return BookingDecision(action: .retrySameSeat, delayMs: 1000, message: message)
        }
        if message.contains("该座位已经被") {
            log("座位 \(seat.name) 已被预约，延迟 \(Int(ReservationRunner.seatTakenDelayMs))ms 后继续下一座位")
            return BookingDecision(action: .seatTaken, delayMs: ReservationRunner.seatTakenDelayMs, message: message)
        }
        if message.contains("重新尝试") {
            // 复刻旧版 N0.u：重试延迟由尝试链内的共享变量累进（1000ms 起步，每次 +300ms），
            // attemptBooking 无状态，具体等待多久由调用方的 chainDelayMs 决定。
            return BookingDecision(action: .retrySameSeatGrow, delayMs: 0, message: message)
        }
        if message.contains("名额已满") || message.contains("不可选座")
            || message.contains("异常预约") {
            return BookingDecision(action: .abort, delayMs: 0, message: message)
        }
        if message.contains("未开放") || message.contains("不开放") {
            return BookingDecision(action: .venueClosed, delayMs: 0, message: message)
        }
        log("预约 \(seat.name) 未成功：\(snippet(message))，尝试下一座位")
        return BookingDecision(action: .nextSeat, delayMs: 1000, message: message)
    }

    /// 取验证码图 → 打码识别 → 4 位合法性校验（无效退码重取），上限 20 次。
    /// 返回 nil 表示本次识别链路不可用，调用方按需回退（不抛，除了取消与会话失效）。
    private func fetchAndSolveCaptcha(client: TraceintClient, tomorrow: Bool,
                                      seatName: String) async throws -> SolvedCaptcha? {
        guard let solver = self.solver else { return nil }
        if traceintUserId.isEmpty {
            do {
                traceintUserId = try await client.fetchUserId()
            } catch let error as CancellationError {
                throw error
            } catch {
                if Task.isCancelled || !running { throw CancellationError() }
                log("获取 traceint user_id 失败：\(friendlyError(error))")
            }
        }
        var attempt = 1
        while running && attempt <= 20 {
            do {
                let captcha = try await client.fetchCaptcha(tomorrow: tomorrow)
                let startedAt = Date()
                let solved = await solver.solve(imageBase64: captcha.imageBase64)
                let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
                guard let solved else {
                    // 打码服务已拒绝本设备（凭证无效或服务未开通）：再取 20 张图也只会
                    // 拿到同样的结果，白等十几秒还会拖过抢座窗口。直接放弃本次识别。
                    if solver.isTokenUnavailable {
                        log("验证码识别服务拒绝了本设备（凭证无效或未开通），放弃本次识别")
                        return nil
                    }
                    log("验证码识别失败（尝试 \(attempt)），500ms 后重试")
                    try await sleepMs(500)
                    attempt += 1
                    continue
                }
                guard CaptchaSolver.isPlausible(solved.code) else {
                    log("识别结果不是 4 位（\(snippet(solved.code))），退码并立即重取")
                    await solver.refund(uniqueCode: solved.uniqueCode)
                    attempt += 1
                    continue
                }
                log("验证码识别结果: \(solved.code)，耗时 \(elapsed)ms (座位: \(seatName), 尝试 \(attempt))")
                return SolvedCaptcha(answer: solved.code, serverCode: captcha.code,
                                     uniqueCode: solved.uniqueCode)
            } catch let error as CancellationError {
                throw error
            } catch {
                if Task.isCancelled || !running { throw CancellationError() }
                let message = friendlyError(error)
                if TraceintClient.isSessionExpired(message) { throw error }
                log("验证码获取失败（尝试 \(attempt)）：\(message)")
                try await sleepMs(500)
                attempt += 1
            }
        }
        return nil
    }

    // MARK: - 状态与收尾

    private func log(_ message: String) {
        AppConfig.addLog(message)
    }

    private func updateState(_ title: String, _ detail: String, _ countdownMs: Int) {
        statusTitle = title
        statusDetail = detail
        self.countdownMs = countdownMs
        AppConfig.setRunning(running)
        AppConfig.setStatus(title: title, detail: detail, countdownMs: countdownMs)
        // Android 每写一次状态就重发前台通知；iOS 的通知不能常驻，每秒刷一条只会刷屏，
        // 所以进度只走 AppConfig + NotificationCenter，用户可见的通知只留终态与"已挂起"。
        NotificationCenter.default.post(name: .goToLibraryStatusChanged, object: nil)
    }

    private func successAndStop(title: String, detail: String) {
        log(title + "：" + detail)
        Task { await NotificationService.postResult(title: title, detail: detail) }
        finishTask(title: title, detail: detail)
    }

    private func failAndStop(title: String, detail: String) {
        log(title + "：" + detail)
        Task { await NotificationService.postResult(title: title, detail: detail) }
        finishTask(title: title, detail: detail)
    }

    private func expireSessionAndStop(_ message: String) {
        AppConfig.clearCookie()
        failAndStop(title: "登录已失效", detail: "请重新微信登录后再启动任务：" + message)
    }

    private func finishTask(title: String, detail: String) {
        running = false
        AppConfig.setRunning(false)
        AppConfig.setStatus(title: title, detail: detail, countdownMs: -1)
        statusTitle = title
        statusDetail = detail
        countdownMs = -1
        NotificationCenter.default.post(name: .goToLibraryStatusChanged, object: nil)
        UIApplication.shared.isIdleTimerDisabled = false
        endBackgroundTime()
        removeObservers()
        suspendedByBackground = false
        // 复刻旧版 DoReserveService.onDestroy：任务结束时关掉自动开启的保活，
        // 用户在设置里显式打开的保活（keepCookie）则保留。
        if !AppConfig.keepCookie() && SessionKeeper.shared.running {
            SessionKeeper.shared.stop()
        }
    }

    /// 所有等待都走这里：只借 Task.sleep，不阻塞主线程，取消时向上抛 CancellationError。
    private func sleepMs(_ milliseconds: Double) async throws {
        guard milliseconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(milliseconds * 1_000_000))
    }

    private func friendlyError(_ error: Error) -> String {
        if let api = error as? TraceintClient.ApiError { return api.message }
        let value = error.localizedDescription
        return value.isEmpty ? String(describing: type(of: error)) : value
    }

    private func friendlyMessage(_ message: String) -> String {
        message.trimmingCharacters(in: .whitespaces).isEmpty ? "服务器未给出原因" : message
    }

    private func snippet(_ text: String) -> String {
        let compact = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return compact.count <= 80 ? compact : String(compact.prefix(80)) + "…"
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: text, options: [],
                                range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
    }

    // MARK: - 前后台

    private func registerObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // 观察闭包非隔离，统一用 Task 跳回主 actor 再改状态。
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.beginBackgroundTime() }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.handleForeground() }
        })
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    /// 申请后台额度。额度耗尽时系统调用 expirationHandler，这里如实把状态改成"已挂起"。
    private func beginBackgroundTime() {
        guard running, backgroundTaskId == .invalid else { return }
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "ReservationRunner") { [weak self] in
            Task { @MainActor in self?.handleBackgroundExpired() }
        }
    }

    private func endBackgroundTime() {
        guard backgroundTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskId)
        backgroundTaskId = .invalid
    }

    private func handleBackgroundExpired() {
        endBackgroundTime()
        guard running else { return }
        suspendedByBackground = true
        log("预约任务已挂起：iOS 后台额度耗尽，系统不再调度，请回到应用继续")
        updateState("任务已挂起", "应用已进入后台且后台额度用尽，系统已暂停任务，请回到应用继续抢座", -1)
        Task {
            await NotificationService.postResult(title: "任务已挂起",
                                                 detail: "应用在后台被系统暂停，请回到应用继续抢座")
        }
    }

    private func handleForeground() {
        endBackgroundTime()
        guard running, suspendedByBackground else { return }
        suspendedByBackground = false
        log("应用已回到前台，任务按当前时刻重新计时")
        updateState(statusTitle, statusDetail, countdownMs)
    }
}

// MARK: - 排队结果

/// 复刻旧版 N0.m 回调的三态：排队成功 / 已登记 / 失败。
private enum QueueOutcome {
    case passed
    case alreadyBooked
    case failed(String)

    var message: String {
        switch self {
        case .passed: return "排队成功"
        case .alreadyBooked: return "已登记过明天的座位"
        case .failed(let message): return message
        }
    }
}

/// QueueEngineListener 会在引擎的 actor（非主线程）上回调，而 ReservationRunner 是
/// @MainActor 的，所以中间加一层加锁的桥接：
/// - 日志直接写 AppConfig（其内部有锁，线程安全），UI 由 .goToLibraryLogsChanged 驱动；
/// - 终态用一次性续体交给等待中的 runQueueEngine。
private final class QueueBridge: QueueEngineListener, @unchecked Sendable {

    private let lock = NSLock()
    private var outcome: QueueOutcome?
    private var waiter: CheckedContinuation<QueueOutcome, Never>?
    private let onLog: (String) -> Void

    init(onLog: @escaping (String) -> Void) {
        self.onLog = onLog
    }

    func queueLog(_ message: String) {
        onLog(message)
    }

    func queuePassed() {
        finish(.passed)
    }

    func queueAlreadyBooked() {
        finish(.alreadyBooked)
    }

    func queueBlocked(_ message: String) {
        finish(.failed(message.isEmpty ? "排队被服务器拦截" : message))
    }

    func queueExhausted(_ message: String) {
        finish(.failed(message.isEmpty ? "排队未成功" : message))
    }

    /// 任务被用户停止时打断等待，让 runQueueEngine 立刻收尾。
    func cancelWaiting() {
        finish(.failed("任务被停止"))
    }

    func waitForOutcome() async -> QueueOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<QueueOutcome, Never>) in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(returning: outcome)
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }

    /// 终态只允许写一次：引擎的多个回调可能在取消竞态里先后到达。
    private func finish(_ value: QueueOutcome) {
        lock.lock()
        if outcome != nil {
            lock.unlock()
            return
        }
        outcome = value
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: value)
    }
}

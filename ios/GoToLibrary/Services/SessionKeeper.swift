// 对应 Android 侧 com.gotolibrary.app.SessionKeeperService（Cookie 保活前台服务）。
//
// iOS 平台限制（与 Android 的最大差异，必须如实呈现）：
// Android 的前台服务可以整夜运行，iOS 不能 —— 应用进入后台后只有几十秒时间，
// 随后进程被系统挂起，任何 Task 都不会再被调度。所以这里的策略是：
//   前台运行即正常保活；进入后台申请一次 beginBackgroundTask 争取额外时间，
//   额度耗尽后**暂停循环**（不假装还在跑），回到前台自动恢复。
// 因此 iOS 上的保活实际只在「用户把应用留在前台」时有效，界面上必须说清这点。
import Foundation
import Combine
import UIKit
import os

@MainActor
final class SessionKeeper: ObservableObject {

    static let shared = SessionKeeper()

    @Published private(set) var running: Bool = false
    @Published private(set) var invalid: Bool = false
    @Published private(set) var pingCount: Int = 0

    /// 低于旧版的节流阈值：距上次请求不足该值就先等满，避免重连风暴。
    static let throttleMs = 2500
    static let minIntervalMs = 5000
    static let intervalSpreadMs = 25000

    /// 失效状态的持久化键。进程被杀后 UI 仍要如实显示"登录已失效"，
    /// 而不是因为 Cookie 文件还在就显示"微信登录有效"。键名沿用 Android。
    static let prefKeepaliveInvalid = KeepalivePrefs.invalidKey

    private static let log = Logger(subsystem: "com.gotolibrary.nativeapp", category: "keepalive")

    /// 复用同一个客户端，避免每轮 ping 都新建连接池。cookie 变更时重建。
    private var client: TraceintClient?
    private var clientCookie = ""

    private var task: Task<Void, Never>?
    private var lastPingAt = Date.distantPast
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    /// 后台额度耗尽后置位，循环停在这里等回到前台。
    private var pausedByBackground = false
    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// 上一轮保活是否判定为登录失效（供界面展示）。
    static func persistedInvalid() -> Bool {
        KeepalivePrefs.isInvalid()
    }

    static func isRunning() -> Bool {
        shared.running
    }

    func start() async {
        if running { return }
        // 执行边界二次校验：保活请求同样受会员凭证约束。
        guard LicenseManager.isUsable() else {
            AppConfig.addLog("Cookie 保活被拒绝：会员状态校验未通过")
            return
        }
        running = true
        invalid = false
        pingCount = 0
        lastPingAt = .distantPast
        pausedByBackground = false
        persistInvalid(false)
        registerObservers()
        AppConfig.addLog("Cookie 保活已启动")
        // 非结构化 Task：不受调用方（通常是某个 View 的 .task）取消影响，
        // 只能由 stop() 停止。
        task = Task { [weak self] in
            guard let self else { return }
            await self.loop()
        }
    }

    func stop() {
        guard running || task != nil else { return }
        running = false
        task?.cancel()
        task = nil
        endBackgroundTime()
        removeObservers()
        AppConfig.addLog("Cookie 保活已由用户停止")
    }

    // MARK: - 循环

    private func loop() async {
        while running {
            do {
                if pausedByBackground {
                    try await Task.sleep(nanoseconds: 500 * 1_000_000)
                    continue
                }
                let now = Date()
                if now.timeIntervalSince(lastPingAt) < Double(SessionKeeper.throttleMs) / 1000 {
                    try await Task.sleep(nanoseconds: UInt64(SessionKeeper.throttleMs) * 1_000_000)
                    continue
                }
                lastPingAt = now
                pingCount += 1
                await probe()
                if !running { return }
                let interval = SessionKeeper.minIntervalMs + Int.random(in: 0..<SessionKeeper.intervalSpreadMs)
                try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000)
            } catch {
                // 睡眠被取消（stop()）或进程收尾：直接结束，不吞掉后继续循环。
                return
            }
        }
    }

    /// 一次保活探针。只有上游明确拒绝会话才终止；其余异常按可重试处理。
    private func probe() async {
        let cookie = AppConfig.cookie()
        guard !cookie.trimmingCharacters(in: .whitespaces).isEmpty else {
            stopInvalid("登录状态为空")
            return
        }
        if client == nil || cookie != clientCookie {
            client = TraceintClient(cookie: cookie) { refreshed in
                _ = AppConfig.setCookie(refreshed)
            }
            clientCookie = cookie
        }
        do {
            guard let client = self.client else { return }
            let result = try await client.indexProbe()
            if result.invalid { stopInvalid(result.detail) }
        } catch {
            // 网络超时或上游瞬时错误：保留保活，下一轮继续。取消/停止不是错误，
            // 由外层循环的 running 判断兜住。
            if Task.isCancelled || !running { return }
            SessionKeeper.log.warning("保活探针异常，下一轮继续: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopInvalid(_ detail: String) {
        invalid = true
        running = false
        persistInvalid(true)
        AppConfig.addLog("Cookie 保活：登录状态已失效，" + detail)
        endBackgroundTime()
        removeObservers()
        task = nil
        Task {
            await NotificationService.postResult(title: "维持登录状态已停止",
                                                 detail: "图书馆登录状态已失效，请重新登录后再开启")
        }
    }

    private func persistInvalid(_ value: Bool) {
        KeepalivePrefs.setInvalid(value)
    }

    // MARK: - 前后台

    /// 进入后台只能靠一次 beginBackgroundTask 争取时间；额度耗尽就暂停循环并如实告知用户，
    /// **不**用音视频后台模式或静默播放来骗后台时间（那会被审核拒绝，也是欺骗用户）。
    private func registerObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // 观察闭包是非隔离的（通知中心不保证执行器），统一用 Task 跳回主 actor，
        // 不要在这里直接碰 @MainActor 状态。
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.handleEnterBackground() }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.handleEnterForeground() }
        })
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    private func handleEnterBackground() {
        guard running else { return }
        guard backgroundTaskId == .invalid else { return }
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "SessionKeeper") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.pausedByBackground = true
                AppConfig.addLog("Cookie 保活已暂停：应用进入后台且后台额度耗尽，回到前台后自动恢复")
                self.endBackgroundTime()
            }
        }
    }

    private func handleEnterForeground() {
        endBackgroundTime()
        guard running, pausedByBackground else { return }
        pausedByBackground = false
        AppConfig.addLog("Cookie 保活已恢复（应用回到前台）")
    }

    private func endBackgroundTime() {
        guard backgroundTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskId)
        backgroundTaskId = .invalid
    }
}

/// 保活失效标记的持久化。独立成非隔离的 helper，避免为了读一个 UserDefaults
/// 键值再把主 actor 的静态成员暴露出去。
private enum KeepalivePrefs {

    static let invalidKey = "keepalive_invalid"
    static let defaults: UserDefaults = UserDefaults(suiteName: AppConfig.prefsSuiteName) ?? .standard

    static func isInvalid() -> Bool {
        guard defaults.object(forKey: invalidKey) != nil else { return false }
        return defaults.bool(forKey: invalidKey)
    }

    static func setInvalid(_ value: Bool) {
        defaults.set(value, forKey: invalidKey)
    }
}

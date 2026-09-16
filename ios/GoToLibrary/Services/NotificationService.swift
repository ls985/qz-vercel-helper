// 对应 Android 侧 ReservationService / SessionKeeperService 里 NotificationChannel
// 与 NotificationManager.notify 的部分（reservation_monitor / reservation_result 两个通道）。
//
// 平台差异：Android 的前台服务通知是常驻的，iOS 没有等价物 —— `postMonitor` 只发一条
// 静默通知（同一 identifier 反复覆盖），用于用户主动开启"常驻提示"时留个痕迹，
// 不能靠它维持进程存活。结果通知（postResult）才是需要用户看到的。
import Foundation
import UserNotifications
import os

enum NotificationService {

    /// 与 Android 的两个 channel 同名，便于两端日志对照。
    static let categoryResult = "reservation_result"
    static let categoryMonitor = "reservation_monitor"

    /// 静默提示固定用同一个 identifier，重复投递即覆盖，不刷屏。
    private static let monitorIdentifier = "reservation_monitor_active"

    private static let log = Logger(subsystem: "com.gotolibrary.nativeapp", category: "notify")

    /// 结果通知的文案（由调用方传入 title，取值与 Android 对齐）：
    /// 成功类 —— "预约成功" / "明日预约成功" / "任务已停止"；
    /// 失败类 —— "登录已失效" / "账号保护已触发" / "明日预约未进入队列"。
    static func requestAuthorization() async -> Bool {
        ensureCategories()
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            NotificationService.log.warning("通知授权请求失败: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// 预约结果通知：高优先级 + 声音 + 震动（category 决定前台展示策略与震动）。
    static func postResult(title: String, detail: String) async {
        ensureCategories()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = detail
        content.sound = .default
        content.categoryIdentifier = categoryResult
        // 每条结果独立 identifier：连续两次终态（比如失败后又手动重启）都应该各自弹出，
        // 不能因为同名互相覆盖。
        let request = UNNotificationRequest(identifier: "reservation_result_" + UUID().uuidString,
                                            content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            NotificationService.log.warning("结果通知投递失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 状态镜像通知：静默（无声音、无震动），同一 identifier 覆盖。
    static func postMonitor(title: String, detail: String) async {
        ensureCategories()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = detail
        content.sound = nil
        content.categoryIdentifier = categoryMonitor
        let request = UNNotificationRequest(identifier: monitorIdentifier, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            NotificationService.log.warning("状态通知投递失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 两个 category 的注册是幂等的，每次投递前调用一次即可，
    /// 免得再去维护"只注册一次"的全局状态（多线程首调时反而容易重入）。
    private static func ensureCategories() {
        let result = UNNotificationCategory(identifier: categoryResult, actions: [],
                                            intentIdentifiers: [], options: [])
        let monitor = UNNotificationCategory(identifier: categoryMonitor, actions: [],
                                             intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([result, monitor])
    }
}

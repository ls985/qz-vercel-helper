// 对应 Android 侧 MainActivity 的启动流程（通知权限申请、启动期更新检查、Cookie 保活拉起）。
import SwiftUI
import UIKit
import UserNotifications

@main
struct GoToLibraryApp: App {

    /// 必须设 `UNUserNotificationCenter.delegate`，否则应用在前台时系统直接丢弃通知。
    /// iOS 上的抢座任务恰恰只能在前台跑（进程一挂起就不做事），终态通知如果被丢掉，
    /// 用户就完全看不到"预约成功 / 登录已失效"这类结果了。
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(ThemeStore.shared)
                .task { await AppBootstrap.run() }
        }
    }
}

/// 启动期一次性工作。独立成非视图类型，避免在 `.task` 闭包里捕获 App 值
/// （闭包带 `@Sendable` 约束，捕获持有 delegate 适配器的 App 只会引入无意义的并发要求）。
@MainActor
private enum AppBootstrap {

    static func run() async {
        _ = await NotificationService.requestAuthorization()

        // 启动期检查不带 force：AppUpdater 内部按 6 小时窗口限流，结果只落日志，
        // 需要弹窗提醒用户的入口在账号页（那里用 force: true）。
        if let release = await AppUpdater.checkForUpdate() {
            AppConfig.addLog("检查到新版本 \(release.version)，可到账号页查看更新")
        }

        // 未登录时没必要保活：SessionKeeper 每轮探针都会因为空 Cookie 直接判失效。
        if AppConfig.keepCookie(), AppConfig.isLoggedIn(), !SessionKeeper.shared.running {
            await SessionKeeper.shared.start()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// 前台展示策略：横幅 + 通知中心列表 + 声音（Android 侧是靠高优先级前台服务通知，iOS 没有等价物）。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

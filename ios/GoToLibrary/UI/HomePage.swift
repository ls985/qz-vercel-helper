// 对应 Android 侧 MainActivity 的首页面板（问候语 / 任务状态卡 / 倒计时 / 快捷入口 / 公告）。
import Foundation
import SwiftUI
import UIKit

/// 首页等页面请求主界面切页。页面选择状态由 `MainView` 持有（不在本文件职责内），
/// 这里不臆造它的构造参数，改用通知解耦：`MainView` 订阅 `.goToLibraryRequestPage`
/// 并读取 object 里的 `MainPage` 即可完成联动。
extension Notification.Name {
    static let goToLibraryRequestPage = Notification.Name("goToLibraryRequestPage")
}

enum MainPageRouter {
    static func open(_ page: MainPage) {
        NotificationCenter.default.post(name: .goToLibraryRequestPage, object: page)
    }
}

@MainActor
struct HomePage: View {

    @ObservedObject private var runner = ReservationRunner.shared
    @ObservedObject private var themeStore = ThemeStore.shared

    private var colors: ThemeColors { themeStore.colors }

    init() {}

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                greetingCard.panelEntrance(0)
                statusCard.panelEntrance(1)
                primaryActionCard.panelEntrance(2)
                quickActionsCard.panelEntrance(3)
                recentLogsCard.panelEntrance(4)
                // 公告为空时整块隐藏（对齐 Android renderAnnouncements 的做法）。
                if !announcements.isEmpty {
                    announcementsCard.panelEntrance(5)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
    }

    // MARK: - 问候与头像

    /// 时段问候前缀照抄 Android updateHomeGreeting 的分档（6/12/18 点三个界）。
    private var greeting: String {
        let name = AppConfig.displayName().trimmingCharacters(in: .whitespaces)
        let hour = Calendar.current.component(.hour, from: Date())
        let prefix = hour < 6 ? "夜深了" : hour < 12 ? "早上好" : hour < 18 ? "下午好" : "晚上好"
        return name.isEmpty ? prefix + "，欢迎回来" : prefix + "，" + name
    }

    private var greetingCard: some View {
        GlassCard {
            HStack(spacing: 14) {
                avatarView
                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting)
                        .font(.title3.weight(.semibold))
                        .foregroundColor(colors.ink)
                    Text(AppConfig.isLoggedIn() ? "微信登录有效" : "尚未登录")
                        .font(.caption)
                        .foregroundColor(colors.secondaryText)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var avatarView: some View {
        Group {
            if let data = AppConfig.avatarData(), let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundColor(colors.secondaryText)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(Circle())
        .accessibilityLabel("本机头像预览")
    }

    // MARK: - 任务状态

    private var statusCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    PulseDot(active: runner.running, color: runner.running ? colors.primary : colors.navIdle)
                    Text(statusTitleText)
                        .font(.headline)
                        .foregroundColor(colors.ink)
                    Spacer()
                    Text(runner.running ? "运行中" : "就绪")
                        .font(.caption)
                        .foregroundColor(colors.secondaryText)
                }
                Text(statusDetailText)
                    .font(.footnote)
                    .foregroundColor(colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                // TimelineView 每秒重绘一次：倒计时存在 AppConfig 里，是服务每秒写一次的持久值，
                // 光靠 @Published 在进程重启/切页面后不会立刻反映到界面。
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(countdownText)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(runner.running ? colors.primary : colors.secondaryText)
                }
            }
        }
    }

    private var statusTitleText: String {
        let live = runner.statusTitle.trimmingCharacters(in: .whitespaces)
        if !live.isEmpty { return live }
        let stored = AppConfig.status().title.trimmingCharacters(in: .whitespaces)
        return stored.isEmpty ? "准备就绪" : stored
    }

    private var statusDetailText: String {
        let live = runner.statusDetail.trimmingCharacters(in: .whitespaces)
        if !live.isEmpty { return live }
        let stored = AppConfig.status().detail.trimmingCharacters(in: .whitespaces)
        if !stored.isEmpty { return stored }
        if !AppConfig.isLoggedIn() { return "请先在预约页完成微信登录" }
        return AppConfig.roomId() == 0 ? "正在读取阅览室" : "完成登录和座位配置后即可启动"
    }

    private var countdownText: String {
        let live = runner.countdownMs
        let stored = AppConfig.status().countdownMs
        let millis = live > 0 ? live : stored
        guard millis > 0 else { return runner.running ? "运行中" : "就绪" }
        let totalSeconds = max(0, millis / 1000)
        return String(format: "%02d:%02d:%02d 后开始",
                      totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60)
    }

    // MARK: - 主操作

    private var primaryActionCard: some View {
        GlassCard {
            VStack(spacing: 12) {
                HStack {
                    PulseDot(active: AppConfig.mode() == AppConfig.modeTomorrow, color: colors.navIdle)
                    Text(AppConfig.mode() == AppConfig.modeTomorrow ? "明日预约" : "实时捡漏")
                        .font(.footnote)
                        .foregroundColor(colors.secondaryText)
                    Spacer()
                }
                if runner.running {
                    Button {
                        runner.stop()
                    } label: {
                        Label("停止任务", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlassPrimaryButtonStyle())
                } else {
                    Button {
                        // 启动前不再做本地预检：ReservationRunner.start() 自己会二次校验
                        // 会员凭证、Cookie 与阅览室，并把拒绝原因写进状态与日志。
                        Task { await runner.start() }
                    } label: {
                        Label("开始抢座", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlassPrimaryButtonStyle())
                }
            }
        }
    }

    private var quickActionsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionBar("快捷入口")
                HStack(spacing: 10) {
                    Button {
                        MainPageRouter.open(.logs)
                    } label: {
                        Label("查看日志", systemImage: "doc.plaintext")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlassSecondaryButtonStyle())

                    Button {
                        // 对齐 Android homeTomorrowButton：切到预约页并切到明日模式，
                        // 具体时间仍由用户在预约页确认后保存。
                        AppConfig.setMode(AppConfig.modeTomorrow)
                        MainPageRouter.open(.booking)
                    } label: {
                        Label("预约明日座位", systemImage: "calendar.badge.clock")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlassSecondaryButtonStyle())
                }
            }
        }
    }

    // MARK: - 最近记录与公告

    /// logsText() 里最新一条在最前（addLog 插到头部），首页摘要取前 5 行即可。
    private var recentLogLines: [String] {
        let text = AppConfig.logsText()
        guard text != "暂无运行记录" else { return [] }
        return text.split(separator: "\n").prefix(5).map(String.init)
    }

    private var recentLogsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionBar("运行记录")
                if recentLogLines.isEmpty {
                    Text("暂无运行记录")
                        .font(.footnote)
                        .foregroundColor(colors.secondaryText)
                } else {
                    ForEach(recentLogLines.indices, id: \.self) { index in
                        Text("●  " + recentLogLines[index])
                            .font(.caption)
                            .foregroundColor(colors.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Button {
                    MainPageRouter.open(.logs)
                } label: {
                    Text("查看全部记录").frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassSecondaryButtonStyle())
            }
        }
    }

    private var announcements: [String] {
        AppConfig.announcements()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var announcementsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionBar("站内公告")
                ForEach(announcements.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 6) {
                        if index > 0 {
                            Divider()
                        }
                        Text(announcements[index])
                            .font(.footnote)
                            .foregroundColor(colors.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

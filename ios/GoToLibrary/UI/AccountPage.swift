// 对应 Android 侧 MainActivity 的账号页（头像 / 昵称 / 主题 / 玻璃通透度 / 会话 / 保活 / 会员 / 更新）。
import SwiftUI
import PhotosUI
import UIKit

@MainActor
struct AccountPage: View {

    @ObservedObject private var themeStore = ThemeStore.shared
    @ObservedObject private var keeper = SessionKeeper.shared
    @ObservedObject private var runner = ReservationRunner.shared

    private var colors: ThemeColors { themeStore.colors }

    @State private var avatarItem: PhotosPickerItem?
    @State private var avatarData: Data? = AppConfig.avatarData()
    @State private var displayName: String = AppConfig.displayName()
    @State private var glassOpacity: Double = Double(AppConfig.glassOpacity())
    @State private var loggedIn: Bool = AppConfig.isLoggedIn()
    @State private var licenseState: LicenseState = .none
    @State private var update: AppUpdater.Release?
    @State private var showUpdateAlert = false
    @State private var message: String?

    /// 昵称长度上限对齐 Android boundedDisplayName（超长截断，空值落到"用户"）。
    private static let maxDisplayNameLength = 20

    init() {}

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                profileCard.panelEntrance(0)
                appearanceCard.panelEntrance(1)
                sessionCard.panelEntrance(2)
                keepAliveCard.panelEntrance(3)
                membershipCard.panelEntrance(4)
                updateCard.panelEntrance(5)
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(colors.secondaryText)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .onAppear {
            avatarData = AppConfig.avatarData()
            displayName = AppConfig.displayName()
            glassOpacity = Double(AppConfig.glassOpacity())
            loggedIn = AppConfig.isLoggedIn()
            licenseState = LicenseManager.currentState()
        }
        .alert("发现新版本 \(update?.version ?? "")", isPresented: $showUpdateAlert) {
            Button("下载更新") { openUpdatePage() }
            Button("稍后再说", role: .cancel) { }
        } message: {
            Text(updateNotes)
        }
    }

    // MARK: - 账号个性化

    private var profileCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionBar("账号个性化")
                HStack(spacing: 14) {
                    avatarView
                    VStack(alignment: .leading, spacing: 6) {
                        Text("头像")
                            .font(.footnote)
                            .foregroundColor(colors.secondaryText)
                        Text("选择本地图片作为账号头像")
                            .font(.caption)
                            .foregroundColor(colors.secondaryText)
                        PhotosPicker(selection: $avatarItem, matching: .images) {
                            Text("更换头像")
                        }
                        .buttonStyle(GlassSecondaryButtonStyle())
                    }
                    Spacer()
                }
                HStack {
                    Text("昵称")
                        .font(.footnote)
                        .foregroundColor(colors.secondaryText)
                    TextField("设置显示昵称", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                }
                Button("保存个性化设置") { saveProfile() }
                    .buttonStyle(GlassPrimaryButtonStyle())
            }
        }
        .onChange(of: avatarItem) { item in
            guard let item else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        message = "图片无法读取"
                        return
                    }
                    AppConfig.setAvatarData(data)
                    avatarData = data
                    AppConfig.addLog("头像已更新（仅保存在本机）")
                    message = "头像已更新（仅保存在本机）"
                } catch {
                    message = "图片无法读取：" + error.localizedDescription
                }
            }
        }
    }

    @ViewBuilder
    private var avatarView: some View {
        Group {
            if let data = avatarData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundColor(colors.secondaryText)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(Circle())
        .accessibilityLabel("本机头像预览")
    }

    private func saveProfile() {
        let trimmed = displayName.trimmingCharacters(in: .whitespaces)
        let bounded = String(trimmed.prefix(AccountPage.maxDisplayNameLength))
        displayName = bounded.isEmpty ? "用户" : bounded
        AppConfig.setDisplayName(displayName)
        AppConfig.addLog("已保存本机昵称")
        message = "已保存本机昵称和个性化设置"
    }

    // MARK: - 界面外观

    private var appearanceCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionBar("界面外观")
                Text("界面主题")
                    .font(.footnote)
                    .foregroundColor(colors.secondaryText)
                ForEach(AppTheme.allCases) { theme in
                    Button {
                        applyTheme(theme)
                    } label: {
                        HStack {
                            Text(theme.title)
                                .foregroundColor(colors.ink)
                            Spacer()
                            if themeStore.theme == theme {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(colors.primary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlassSecondaryButtonStyle())
                }

                Divider()

                HStack {
                    Text("玻璃通透度")
                        .font(.footnote)
                        .foregroundColor(colors.secondaryText)
                    Spacer()
                    Text("\(Int(glassOpacity))%")
                        .font(.footnote)
                        .foregroundColor(colors.primary)
                }
                Slider(value: $glassOpacity, in: 0...100, step: 1)
                    .tint(colors.primary)
                    .onChange(of: glassOpacity) { value in
                        AppConfig.setGlassOpacity(Int(value))
                    }
                Text("0 最实，100 最透；作用于卡片与按钮，不含底部导航。")
                    .font(.caption)
                    .foregroundColor(colors.secondaryText)
            }
        }
    }

    private func applyTheme(_ theme: AppTheme) {
        // 主题状态由 ThemeStore 持有（它是 UI 层的唯一来源），同时落盘供下次启动读取。
        themeStore.theme = theme
        AppConfig.setTheme(theme.rawValue)
    }

    // MARK: - 图书馆会话

    private var sessionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionBar("图书馆微信会话")
                HStack(spacing: 8) {
                    PulseDot(active: loggedIn, color: loggedIn ? colors.primary : colors.navIdle)
                    Text(loggedIn ? "微信登录有效" : "尚未登录")
                        .font(.subheadline)
                        .foregroundColor(loggedIn ? colors.ink : colors.danger)
                }
                Text("重新登录：复制登录链接 → 微信内完成授权 → 把跳转后的完整地址粘贴回预约页。")
                    .font(.caption)
                    .foregroundColor(colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("重新微信登录") { MainPageRouter.open(.booking) }
                        .buttonStyle(GlassSecondaryButtonStyle())
                        .disabled(runner.running)
                    Button("清除登录") {
                        AppConfig.clearCookie()
                        loggedIn = false
                        AppConfig.addLog("已清除本机登录会话")
                        message = "已清除登录"
                    }
                    .buttonStyle(GlassSecondaryButtonStyle())
                    .disabled(!loggedIn || runner.running)
                }
            }
        }
    }

    // MARK: - Cookie 保活

    private var keepAliveCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionBar("Cookie 保活")
                Toggle("维持登录状态", isOn: Binding(
                    get: { keeper.running },
                    set: { on in
                        Task { @MainActor in
                            if on {
                                await keeper.start()
                            } else {
                                keeper.stop()
                            }
                        }
                    }
                ))
                .tint(colors.primary)

                Text("定时请求接口，保持 Cookie 有效。")
                    .font(.caption)
                    .foregroundColor(colors.secondaryText)
                // 平台差异必须写在界面上：Android 的前台服务可以整夜保活，iOS 的进程
                // 进后台几十秒后就被挂起，保活只能在应用停留在前台时真正生效。
                Text("iOS 不能在后台常驻：切到后台且系统额度用尽后保活会暂停，回到应用后自动恢复。")
                    .font(.caption)
                    .foregroundColor(colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("已完成 \(keeper.pingCount) 次保活请求")
                        .font(.caption)
                        .foregroundColor(colors.secondaryText)
                    Spacer()
                    Text(keeper.running ? "运行中" : "已停止")
                        .font(.caption)
                        .foregroundColor(colors.secondaryText)
                }
                // persistedInvalid 是上次运行落盘的失效标记：进程被杀后 Cookie 文件还在，
                // 只有这个标记能如实说明"登录已经失效"。
                if keeper.invalid || SessionKeeper.persistedInvalid() {
                    Text("登录已失效，请重新登录")
                        .font(.caption)
                        .foregroundColor(colors.danger)
                }
            }
        }
    }

    // MARK: - 会员状态

    private var membershipCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionBar("会员状态")
                Text(licenseState == .active ? "尊享会员生效中" : "未开通会员")
                    .font(.headline)
                    .foregroundColor(licenseState == .active ? colors.ink : colors.danger)
                Text(membershipExpiryText)
                    .font(.footnote)
                    .foregroundColor(colors.secondaryText)
                Text("上次复验：\(lastRefreshText)")
                    .font(.caption)
                    .foregroundColor(colors.secondaryText)
                Text("本机设备码：\(LicenseManager.displayDeviceCode())")
                    .font(.caption)
                    .foregroundColor(colors.secondaryText)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    Button("刷新状态") {
                        // 手动复验：重新走一遍验签 + 信任时钟判定，并刷新界面上的会员信息。
                        licenseState = LicenseManager.currentState()
                        loggedIn = AppConfig.isLoggedIn()
                        AppConfig.addLog("已重新校验会员状态")
                        message = "会员状态已重新校验"
                    }
                    .buttonStyle(GlassSecondaryButtonStyle())
                    Button("复制设备码") {
                        UIPasteboard.general.string = LicenseManager.displayDeviceCode()
                        message = "设备码已复制"
                    }
                    .buttonStyle(GlassSecondaryButtonStyle())
                }
                HStack(spacing: 10) {
                    Button("续费会员") {
                        BuildConfig.openPaymentChannel()
                    }
                    .buttonStyle(GlassSecondaryButtonStyle())
                    Button("使用教程与帮助") {
                        if let url = URL(string: BuildConfig.tutorialURL) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(GlassSecondaryButtonStyle())
                }
            }
        }
    }

    private var membershipExpiryText: String {
        let expiresAt = LicenseManager.membershipExpiresAt()
        guard expiresAt > 0 else { return "会员有效期：未激活" }
        let date = Date(timeIntervalSince1970: expiresAt)
        return "有效期至：" + AccountPage.dateFormatter.string(from: date)
    }

    private var lastRefreshText: String {
        guard let last = LicenseManager.lastRefreshAt() else { return "尚未复验" }
        return AccountPage.dateTimeFormatter.string(from: last)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - 应用更新

    private var updateCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionBar("应用更新")
                Text("当前版本 \(BuildConfig.appVersion)（Build \(BuildConfig.appBuild)）")
                    .font(.footnote)
                    .foregroundColor(colors.secondaryText)
                if let update {
                    Text("发现新版本 \(update.version)")
                        .font(.subheadline)
                        .foregroundColor(colors.primary)
                    if !update.notes.isEmpty {
                        Text(update.notes)
                            .font(.caption)
                            .foregroundColor(colors.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("下载更新") { openUpdatePage() }
                        .buttonStyle(GlassPrimaryButtonStyle())
                }
                Button("检查更新") { Task { await checkUpdate() } }
                    .buttonStyle(GlassSecondaryButtonStyle())
            }
        }
    }

    private var updateNotes: String {
        guard let update else { return "" }
        return update.notes.isEmpty ? "新版本已发布，点击前往下载页。" : update.notes
    }

    private func checkUpdate() async {
        // force: true —— 这是用户主动点击的检查，不受 AppUpdater 的 6 小时节流限制。
        guard let release = await AppUpdater.checkForUpdate(force: true) else {
            AppConfig.addLog("检查更新：已是最新版本")
            message = "已是最新版本"
            return
        }
        update = release
        showUpdateAlert = true
        AppConfig.addLog("检查更新：发现新版本 \(release.version)")
    }

    private func openUpdatePage() {
        // iOS 不能自安装更新：没有 DownloadManager，也无法安装 App Store 之外的包。
        // 这里只能把用户送到下载页 / App Store，安装那一步由用户自己完成。
        guard let release = update, let url = URL(string: release.url) else { return }
        UIApplication.shared.open(url)
    }
}

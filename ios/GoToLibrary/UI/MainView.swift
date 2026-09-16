// 对应 Android 侧 activity_main.xml 与 MainActivity 导航框架逻辑。
import SwiftUI
import UIKit

/// 主导航页面枚举：首页、预约、日志、我的。
enum MainPage: String, CaseIterable, Identifiable {
    case home, booking, logs, account

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "首页"
        case .booking: return "预约"
        case .logs: return "日志"
        case .account: return "我的"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .booking: return "calendar.badge.clock"
        case .logs: return "doc.text.fill"
        case .account: return "person.fill"
        }
    }
}

/// 主容器视图：负责全屏光斑底衬、四个功能页面切换与底部胶囊导航。
struct MainView: View {
    @ObservedObject private var themeStore = ThemeStore.shared
    @State private var selectedPage: MainPage = .home
    @State private var isLicenseUsable: Bool = LicenseManager.isUsable()
    /// 续签请求的去重标志：onAppear 与前台通知可能几乎同时触发。
    @State private var renewingEntitlement: Bool = false
    @Namespace private var navNamespace

    /// Android 对应常量：高度 64dp、左右外边距 14dp、与内容区留空 48dp
    private let bottomNavHeight: CGFloat = 64
    private let bottomNavMargin: CGFloat = 14
    private let bottomNavContentGap: CGFloat = 48

    init() {}

    var body: some View {
        ZStack {
            // 全屏液态光斑背景：全景沉浸且无缝适配刘海与安全区
            GlassBackdrop()

            // 页面主内容区
            VStack(spacing: 0) {
                activePageView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // 底部预留充足留白：导航高度 64 + 间隙 48 = 112pt，确保滚动到底部不被遮挡
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: bottomNavHeight + bottomNavContentGap)
            }

            // 悬浮胶囊导航栏
            VStack {
                Spacer()
                capsuleNavigationBar
                    .padding(.horizontal, bottomNavMargin)
                    .padding(.bottom, 8)
            }

            // 会员门禁全屏覆盖：未激活或过期时锁定界面，激活后淡出
            if !isLicenseUsable {
                LicenseGateView()
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        .onAppear {
            refreshLicenseState()
            renewEntitlementIfNeeded()
        }
        // 应用切到前台时立即重新校验会员状态（对齐 Android onResume 校验）
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refreshLicenseState()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshLicenseState()
            renewEntitlementIfNeeded()
        }
        // 门禁页激活成功后会广播这个通知；没有订阅者的话界面不会重算，门禁会一直盖着。
        .onReceive(NotificationCenter.default.publisher(for: .goToLibraryLicenseChanged)) { _ in
            renewingEntitlement = false
            refreshLicenseState()
        }
        // 响应来自快捷入口（如 HomePage 快捷跳转）的跨页路由通知
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("goToLibraryRequestPage"))) { notification in
            if let target = notification.object as? MainPage {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.80)) {
                    selectedPage = target
                }
            }
        }
    }

    // MARK: - 页面分发与入场动效

    @ViewBuilder
    private var activePageView: some View {
        switch selectedPage {
        case .home:
            HomePage()
                .panelEntrance(0)
                .id(MainPage.home)
        case .booking:
            BookingPage()
                .panelEntrance(0)
                .id(MainPage.booking)
        case .logs:
            LogsPage()
                .panelEntrance(0)
                .id(MainPage.logs)
        case .account:
            AccountPage()
                .panelEntrance(0)
                .id(MainPage.account)
        }
    }

    // MARK: - 底部胶囊导航

    /// 胶囊导航栏：根据 Android 设计约定，不受通透度滑块影响，保持稳固视觉基底。
    private var capsuleNavigationBar: some View {
        let colors = themeStore.colors
        let isDark = themeStore.theme == .ocean

        return HStack(spacing: 0) {
            ForEach(MainPage.allCases) { page in
                let isSelected = selectedPage == page
                Button {
                    guard selectedPage != page else { return }
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.80)) {
                        selectedPage = page
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: page.systemImage)
                            .font(.system(size: 19, weight: isSelected ? .semibold : .regular))
                        Text(page.title)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    }
                    .foregroundColor(isSelected ? colors.primary : colors.navIdle)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .contentShape(Rectangle())
                    .background {
                        if isSelected {
                            // 选中胶囊滑块：对齐 Android bg_bottom_nav_item_active 的 0x48CF7558 胶囊底
                            Capsule()
                                .fill(colors.primary.opacity(isDark ? 0.24 : 0.16))
                                .overlay {
                                    Capsule()
                                        .strokeBorder(
                                            LinearGradient(
                                                colors: [
                                                    colors.primary.opacity(0.40),
                                                    colors.primary.opacity(0.12)
                                                ],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            ),
                                            lineWidth: 1
                                        )
                                }
                                .matchedGeometryEffect(id: "navActiveIndicator", in: navNamespace)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: bottomNavHeight)
        .background {
            // 胶囊主材质：对齐 Android bg_bottom_nav 的 34dp 全圆角磨砂玻璃底
            Capsule()
                .fill(.ultraThinMaterial)
        }
        .background {
            Capsule()
                .fill(isDark ? Color.black.opacity(0.40) : Color.white.opacity(0.35))
        }
        .overlay {
            Capsule()
                .strokeBorder(
                    isDark ? Color.white.opacity(0.14) : Color.white.opacity(0.45),
                    lineWidth: 0.8
                )
        }
        .shadow(color: Color.black.opacity(isDark ? 0.40 : 0.08), radius: 18, x: 0, y: 8)
    }

    // MARK: - 会员状态校验

    private func refreshLicenseState() {
        let usable = LicenseManager.isUsable()
        if isLicenseUsable != usable {
            withAnimation(.easeInOut(duration: 0.25)) {
                isLicenseUsable = usable
            }
        }
    }

    /// 复刻 Android onResume → maybeRefreshLicense 的静默续签。
    /// 少了这一步，凭证里的 refreshNotAfter（72 小时窗口）一过状态就变 .stale、
    /// 界面被门禁锁死，而凭证本身还是好的 —— 用户没有任何自愈路径。
    private func renewEntitlementIfNeeded() {
        guard !renewingEntitlement, LicenseManager.shouldRefresh(),
              LicenseManager.entitlementToken() != nil else { return }
        renewingEntitlement = true
        Task { @MainActor in
            do {
                let body = try await LicenseClient().refreshEntitlement(
                    deviceId: LicenseManager.deviceFingerprint(),
                    nonce: String(Int(Date().timeIntervalSince1970 * 1000)))
                switch LicenseManager.acceptResponse(body) {
                case .stored:
                    AppConfig.addLog("会员凭证已静默续签")
                case .invalidPayload:
                    AppConfig.addLog("会员凭证续签响应异常，稍后重试")
                case .rejected:
                    AppConfig.addLog("会员凭证续签被拒，请在会员页重新激活")
                }
            } catch {
                // 网络失败保持现状：窗口内还会再试，不该因为一次续签失败就把用户挡在门外。
                AppConfig.addLog("会员凭证续签失败：" + error.localizedDescription)
            }
            renewingEntitlement = false
            refreshLicenseState()
        }
    }
}

// 对应 Android 侧 GlassBackdropView、PulseDotView 以及 bg_field / bg_primary_button 等玻璃质感控件。
import SwiftUI

/// 全屏动态渐变光斑背景：多层柔光斑缓慢漂移（对应 GlassBackdropView）。
/// 纯原生 SwiftUI 实现，兼顾 iOS 16.0 兼容性与微小能耗。
struct GlassBackdrop: View {
    @ObservedObject private var themeStore = ThemeStore.shared
    @State private var shifted = false

    init() {}

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let colors = themeStore.colors
            let isDark = themeStore.theme == .ocean

            ZStack {
                // 底层基色：与系统及 Android 完全对齐的纯色底
                colors.appBackground
                    .ignoresSafeArea()

                // Blob A：左上漂移光斑（主调暖色/海蓝/淡草）
                Circle()
                    .fill(colors.blobA.opacity(isDark ? 0.32 : 0.42))
                    .frame(width: size.width * 0.88, height: size.width * 0.88)
                    .blur(radius: 64)
                    .offset(
                        x: shifted ? -size.width * 0.22 : -size.width * 0.06,
                        y: shifted ? -size.height * 0.16 : -size.height * 0.26
                    )

                // Blob B：右侧腰部光斑（辅助高亮光斑）
                Circle()
                    .fill(colors.blobB.opacity(isDark ? 0.28 : 0.38))
                    .frame(width: size.width * 0.92, height: size.width * 0.92)
                    .blur(radius: 72)
                    .offset(
                        x: shifted ? size.width * 0.24 : size.width * 0.36,
                        y: shifted ? size.height * 0.08 : size.height * 0.24
                    )

                // Blob C：左下腹光斑（沉底柔和光晕）
                Circle()
                    .fill(colors.blobC.opacity(isDark ? 0.22 : 0.32))
                    .frame(width: size.width * 0.78, height: size.width * 0.78)
                    .blur(radius: 68)
                    .offset(
                        x: shifted ? -size.width * 0.16 : size.width * 0.08,
                        y: shifted ? size.height * 0.46 : size.height * 0.36
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .ignoresSafeArea()
            .onAppear {
                // 周期 9 秒缓慢往返漂移，营造液态光感
                withAnimation(.easeInOut(duration: 9.0).repeatForever(autoreverses: true)) {
                    shifted = true
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// 玻璃卡片容器：提供统一内边距、圆角与磨砂质感。
struct GlassCard<Content: View>: View {
    private let padding: CGFloat
    private let cornerRadius: CGFloat
    private let content: Content

    init(padding: CGFloat = 18, cornerRadius: CGFloat = 22, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .glassPanel(padding: padding, cornerRadius: cornerRadius)
    }
}

/// 主按钮样式（primary 实心底 + 玻璃高光）。
struct GlassPrimaryButtonStyle: ButtonStyle {
    @ObservedObject private var themeStore = ThemeStore.shared
    @Environment(\.isEnabled) private var isEnabled

    init() {}

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.white)
            .padding(.vertical, 13)
            .padding(.horizontal, 18)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(themeStore.colors.primary.opacity(isEnabled ? (configuration.isPressed ? 0.86 : 1.0) : 0.38))
            }
            .overlay {
                // 上半部微弱玻璃反光描边，对齐 bg_primary_button 高光层
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.36), Color.white.opacity(0.04)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

/// 次按钮样式（玻璃底 + 描边）。
struct GlassSecondaryButtonStyle: ButtonStyle {
    @ObservedObject private var themeStore = ThemeStore.shared
    @Environment(\.isEnabled) private var isEnabled
    @AppStorage(AppConfig.KEY_GLASS_OPACITY, store: UserDefaults(suiteName: AppConfig.prefsSuiteName))
    private var glassOpacity: Int = AppConfig.DEFAULT_GLASS_OPACITY

    init() {}

    func makeBody(configuration: Configuration) -> some View {
        let isDark = themeStore.theme == .ocean
        // solidRatio: 0 最实 (1.0), 100 最透 (0.0)
        let solidRatio = 1.0 - (Double(min(100, max(0, glassOpacity))) / 100.0)
        let baseTint = isDark ? Color(white: 0.12) : Color.white
        let baseAlpha = isDark ? (0.28 + solidRatio * 0.54) : (0.16 + solidRatio * 0.68)
        let strokeTint = themeStore.colors.primary.opacity(isEnabled ? (isDark ? 0.50 : 0.38) : 0.18)

        return configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundColor(isEnabled ? themeStore.colors.primary : themeStore.colors.secondaryText)
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(baseTint.opacity(baseAlpha))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(strokeTint, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

/// 呼吸状态灯（对应 PulseDotView）：active 时脉冲，静止时恒定。
struct PulseDot: View {
    let active: Bool
    let color: Color

    @State private var phase: CGFloat = 0.0

    init(active: Bool, color: Color) {
        self.active = active
        self.color = color
    }

    var body: some View {
        ZStack {
            if active {
                // 脉冲扩散光环：对应 Android PulseDotView 的 1400ms 扩散周期与 ringAlpha 衰减
                Circle()
                    .stroke(color.opacity(max(0, 0.65 * (1.0 - phase))), lineWidth: 1.8)
                    .frame(width: 9 + 13 * phase, height: 9 + 13 * phase)
            }
            // 中心核心点（直径 9pt，对齐 Android 4.5dp 半径）
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            // 外圈高光微描边（对齐 Android 的 1dp 0x40FFFFFF stroke）
            Circle()
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                .frame(width: 12, height: 12)
        }
        .frame(width: 24, height: 24)
        .onAppear {
            if active { startAnimation() }
        }
        .onChange(of: active) { isActive in
            if isActive {
                startAnimation()
            } else {
                phase = 0.0
            }
        }
    }

    private func startAnimation() {
        phase = 0.0
        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
            phase = 1.0
        }
    }
}

/// 区块标题栏（对应 bg_section_bar 的左侧色条）。
struct SectionBar: View {
    let title: String

    @ObservedObject private var themeStore = ThemeStore.shared

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(themeStore.colors.primary)
                .frame(width: 4, height: 16)
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundColor(themeStore.colors.ink)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - View 扩展与修饰器

extension View {
    /// 玻璃卡片修饰器，等价 GlassCard 的样式但适用于任意视图。
    func glassPanel(padding: CGFloat = 18, cornerRadius: CGFloat = 22) -> some View {
        modifier(GlassPanelModifier(padding: padding, cornerRadius: cornerRadius))
    }

    /// 入场动效：向上位移 14pt + 淡入，按 index 交错 26ms
    /// （对应 Android 的 PANEL_ENTRANCE_OFFSET_DP=14 / PANEL_ENTRANCE_STAGGER_MS=26）。
    func panelEntrance(_ index: Int) -> some View {
        modifier(PanelEntranceModifier(index: index))
    }
}

// MARK: - 内部修饰器实现

private struct GlassPanelModifier: ViewModifier {
    let padding: CGFloat
    let cornerRadius: CGFloat

    @ObservedObject private var themeStore = ThemeStore.shared
    @AppStorage(AppConfig.KEY_GLASS_OPACITY, store: UserDefaults(suiteName: AppConfig.prefsSuiteName))
    private var glassOpacity: Int = AppConfig.DEFAULT_GLASS_OPACITY

    func body(content: Content) -> some View {
        let isDark = themeStore.theme == .ocean
        // 通透度 0...100：0 最实 (solidRatio = 1.0)，100 最透 (solidRatio = 0.0)
        let solidRatio = 1.0 - (Double(min(100, max(0, glassOpacity))) / 100.0)
        let overlayColor = isDark ? Color(white: 0.10) : Color.white
        let overlayAlpha = isDark ? (0.30 + solidRatio * 0.60) : (0.12 + solidRatio * 0.76)
        let strokeColor = isDark
            ? Color.white.opacity(0.12 + solidRatio * 0.18)
            : Color.white.opacity(0.36 + solidRatio * 0.38)
        let shadowAlpha = isDark ? 0.36 : (0.04 + solidRatio * 0.04)

        return content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(overlayColor.opacity(overlayAlpha))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: 0.8)
            }
            .shadow(color: Color.black.opacity(shadowAlpha), radius: 14, x: 0, y: 6)
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                let current = AppConfig.glassOpacity()
                if current != glassOpacity {
                    glassOpacity = current
                }
            }
    }
}

/// 入场动画修饰器：实现向上 14pt 位移 + 淡入与交错延迟。
private struct PanelEntranceModifier: ViewModifier {
    let index: Int
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .offset(y: appeared ? 0 : 14)
            .opacity(appeared ? 1 : 0)
            .task {
                // 对应 Android 的 PANEL_ENTRANCE_STAGGER_MS=26 级联启动间隔
                let delayNanoseconds = UInt64(max(0, index)) * 26_000_000
                if delayNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: delayNanoseconds)
                }
                // stiffness 350, dampingRatio 0.85 弹簧，对应 iOS response: 0.42, damping: 0.85
                withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
                    appeared = true
                }
            }
    }
}

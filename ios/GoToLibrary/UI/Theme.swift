// 对应 Android 侧 res/values/colors.xml 与 MainActivity 主题换色逻辑。
import SwiftUI

/// 主题调色板：聚合界面各层级语义色彩与背景光斑三色。
struct ThemeColors {
    let appBackground: Color
    let surface: Color
    let ink: Color
    let secondaryText: Color
    let primary: Color
    let primaryDark: Color
    let danger: Color
    let navIdle: Color
    /// 背景光斑用的三色（对应 Android 的 GlassBackdropView）
    let blobA: Color
    let blobB: Color
    let blobC: Color
}

/// 界面主题枚举：包含暖阳（默认）、海洋、薄荷三套视觉方案。
enum AppTheme: String, CaseIterable, Identifiable {
    case warm, ocean, mint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .warm: return "暖阳"
        case .ocean: return "海洋"
        case .mint: return "薄荷"
        }
    }

    var colors: ThemeColors {
        switch self {
        case .warm:
            // 暖阳主题：严格照抄 Android colors.xml 原作色值。
            // 背景为暖宣纸色 #F6F2EA，文字与表面为温润炭褐 #1D1B18，主强调为陶瓦橙 #BF552F。
            return ThemeColors(
                appBackground: Color(hex: 0xF6F2EA),
                surface: Color(hex: 0x1D1B18),
                ink: Color(hex: 0x1D1B18),
                secondaryText: Color(hex: 0x7A736C),
                primary: Color(hex: 0xBF552F),
                primaryDark: Color(hex: 0x2A1711),
                danger: Color(hex: 0xC84F55),
                navIdle: Color(hex: 0x746F67),
                blobA: Color(hex: 0xF4A261),
                blobB: Color(hex: 0xF3C68F),
                blobC: Color(hex: 0xDDA15E)
            )
        case .ocean:
            // 海洋主题：对应 Android MainActivity 的深色模式方案（background 0x0B131D / ink 0xF0F4F8）。
            // 暗底配高明度冰白字（对比度 > 12:1），强调色为 Android 设定的湖青 #349E7C。
            return ThemeColors(
                appBackground: Color(hex: 0x0B131D),
                surface: Color(hex: 0xF0F4F8),
                ink: Color(hex: 0xF0F4F8),
                secondaryText: Color(hex: 0x8FA1B0),
                primary: Color(hex: 0x349E7C),
                primaryDark: Color(hex: 0x174E3E),
                danger: Color(hex: 0xE05D65),
                navIdle: Color(hex: 0x758A99),
                blobA: Color(hex: 0x1B4965),
                blobB: Color(hex: 0x2E6F7E),
                blobC: Color(hex: 0x14324A)
            )
        case .mint:
            // 薄荷主题：对应 Android MainActivity 的薄荷方案（background 0xEEF6F2 / ink 0x0F261D）。
            // 清新柔草绿底，深墨绿正文，强调色为 Android 设定的薄荷绿 #288E65。
            return ThemeColors(
                appBackground: Color(hex: 0xEEF6F2),
                surface: Color(hex: 0x0F261D),
                ink: Color(hex: 0x0F261D),
                secondaryText: Color(hex: 0x546B5F),
                primary: Color(hex: 0x288E65),
                primaryDark: Color(hex: 0x0F3B2A),
                danger: Color(hex: 0xC84F55),
                navIdle: Color(hex: 0x637D71),
                blobA: Color(hex: 0x7BC9A6),
                blobB: Color(hex: 0xA3E4D7),
                blobC: Color(hex: 0x9FD3B6)
            )
        }
    }

    static func from(_ raw: String) -> AppTheme {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch trimmed {
        case "ocean": return .ocean
        case "mint": return .mint
        default: return .warm
        }
    }
}

/// 主题状态中枢：持有当前主题，并在变更时同步持久化回 AppConfig。
@MainActor
final class ThemeStore: ObservableObject {
    static let shared: ThemeStore = ThemeStore()

    @Published var theme: AppTheme {
        didSet {
            AppConfig.setTheme(theme.rawValue)
        }
    }

    var colors: ThemeColors {
        theme.colors
    }

    private init() {
        self.theme = AppTheme.from(AppConfig.theme())
    }
}

// MARK: - 内部颜色辅助

private extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

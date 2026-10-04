import AppKit
import SwiftUI

/// 固定使用 Dracula 配色；强调色另由资源 `AccentColor` 提供给系统控件（列表选中等）。
enum Theme {
    static let window = Color(hex: 0x282A36)
    static let titleBar = Color(hex: 0x44475A)
    static let border = Color(hex: 0x44475A)
    static let badge = Color(hex: 0x6272A4)
    static let foreground = Color(hex: 0xF8F8F2)
    static let accent = Color(hex: 0xBD93F9)
    static let added = Color(hex: 0xBD93F9)
    static let deleted = Color(hex: 0xFF5555)
    static let orange = Color(hex: 0xFFB86C)
    static let green = Color(hex: 0x50FA7B)
    static let graph = [0xFF5555, 0xFFB86C, 0xF1FA8C, 0x50FA7B, 0xBD93F9].map { Color(hex: $0) }
    /// 不在 HEAD 历史中的提交。
    static let notMergedOpacity = 0.4
    static let nsBorder = NSColor(srgbRed: 0x44 / 255, green: 0x47 / 255, blue: 0x5A / 255, alpha: 1)
}

private extension Color {
    init(hex: Int) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// config.json `appearance` 的字体；视图 body 读取后随配置热加载刷新。
@MainActor @Observable
final class Typography {
    static let shared = Typography()

    private(set) var appearance = AppConfig.Appearance()
    @ObservationIgnored private var cache: [String: NSFont] = [:]

    var fontSize: CGFloat {
        CGFloat(appearance.fontSize)
    }

    var editorFontSize: CGFloat {
        CGFloat(appearance.editorFontSize)
    }

    /// 返回未安装字体的说明，供错误横幅提示。
    func apply(_ value: AppConfig.Appearance) -> String? {
        if value != appearance {
            appearance = value
            cache = [:]
        }
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        let missing = [("appearance.fontFamily", value.fontFamily),
                       ("appearance.monospaceFontFamily", value.monospaceFontFamily)]
            .filter { !$0.1.isEmpty && !installed.contains($0.1) }
            .map { "\($0.0)：未安装「\($0.1)」，已改用系统字体" }
        return missing.isEmpty ? nil : missing.joined(separator: "\n")
    }

    func font(mono: Bool, size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let key = "\(mono)|\(size)|\(weight.rawValue)"
        if let font = cache[key] {
            return font
        }
        let family = mono ? appearance.monospaceFontFamily : appearance.fontFamily
        let manager = NSFontManager.shared
        // 字体族缺少所需字重时退回常规字重，再退回系统字体。
        let font = family.isEmpty ? nil
            : manager.font(withFamily: family, traits: [], weight: Self.managerWeight(weight), size: size)
            ?? manager.font(withFamily: family, traits: [], weight: 5, size: size)
        let resolved = font ?? (mono ? .monospacedSystemFont(ofSize: size, weight: weight)
            : .systemFont(ofSize: size, weight: weight))
        cache[key] = resolved
        return resolved
    }

    /// NSFontManager 字重 0–15，5 为常规。
    private static func managerWeight(_ weight: NSFont.Weight) -> Int {
        switch weight {
        case .medium: 6
        case .semibold: 8
        case .bold: 9
        case .heavy, .black: 10
        case .light, .thin, .ultraLight: 3
        default: 5
        }
    }
}

extension Font {
    /// 界面字体，`offset` 相对 appearance.fontSize。
    @MainActor
    static func ui(_ offset: CGFloat = 0, weight: NSFont.Weight = .regular) -> Font {
        let typography = Typography.shared
        return Font(typography.font(mono: false, size: typography.fontSize + offset, weight: weight) as CTFont)
    }

    /// 界面中的等宽文字（哈希 / 状态码），字号同界面。
    @MainActor
    static func mono(_ offset: CGFloat = 0, weight: NSFont.Weight = .regular) -> Font {
        let typography = Typography.shared
        return Font(typography.font(mono: true, size: typography.fontSize + offset, weight: weight) as CTFont)
    }

    /// 代码文本（差异 / 提交信息），字号为 appearance.editorFontSize。
    @MainActor
    static func code(weight: NSFont.Weight = .regular) -> Font {
        let typography = Typography.shared
        return Font(typography.font(mono: true, size: typography.editorFontSize, weight: weight) as CTFont)
    }
}

/// overlay 默认延伸进安全区，会盖住隐藏标题栏区域里的顶部条，因此不忽略安全区。
struct ThemedDivider: View {
    var body: some View {
        Divider().overlay(Theme.border, ignoresSafeAreaEdges: [])
    }
}

extension View {
    /// 每个独立 NSHostingView（分栏 / 弹窗 / 浮层）的根都要调用：环境值不跨宿主传递。
    func themed() -> some View {
        modifier(ThemedRoot())
    }
}

private struct ThemedRoot: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.ui()).foregroundStyle(Theme.foreground).tint(Theme.accent)
            .background(Theme.window.ignoresSafeArea())
    }
}

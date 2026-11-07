import AppKit
import CswapCore
import SwiftUI

// 风格取自 NetHub（Sources/NetHubUI/Theme.swift）：字体、色板、开关、分段、卡片、悬停高亮。
// 复制过来按 docs/03 调整（警告 / 危险色深一档、进度条底、输入框底），不跨仓库依赖。

/// 字体：用 NSFont 构造，固定字号，不随系统「文字大小」缩放（面板按设计稿精确排版）
public enum F {
    public static func sys(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> Font {
        Font(NSFont.systemFont(ofSize: size, weight: weight))
    }
    /// 等宽数字：会跳动的数字用它，避免左右抖动
    public static func num(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> Font {
        Font(NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight))
    }
}

extension Color {
    /// 随深浅色切换的颜色
    static func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: .dyn(light, dark))
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static func dyn(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]).map { [.darkAqua, .vibrantDark].contains($0) } == true ? dark : light
        }
    }
}

/// 设计稿 a4 的色板
public enum T {
    static let t2 = Color.dyn(.black.withAlphaComponent(0.58), .white.withAlphaComponent(0.64))
    static let t3 = Color.dyn(.black.withAlphaComponent(0.45), .white.withAlphaComponent(0.48))
    static let sep = Color.dyn(.black.withAlphaComponent(0.085), .white.withAlphaComponent(0.085))
    static let hover = Color.dyn(.black.withAlphaComponent(0.05), .white.withAlphaComponent(0.07))
    static let card = Color.dyn(.white.withAlphaComponent(0.60), .white.withAlphaComponent(0.06))
    static let track = Color.dyn(.black.withAlphaComponent(0.075), .white.withAlphaComponent(0.10))
    static let field = Color.dyn(.white.withAlphaComponent(0.75), .white.withAlphaComponent(0.08))
    static let ok = Color.dyn(NSColor(hex: 0x2FB350), NSColor(hex: 0x32D74B))
    /// 警告与危险比 NetHub 原色深一档，保证浅色下文字对比度 ≥ 4.5
    static let warn = Color.dyn(NSColor(hex: 0xC46F00), NSColor(hex: 0xFFB340))
    static let bad = Color.dyn(NSColor(hex: 0xD3271C), NSColor(hex: 0xFF6961))
    static let off = Color.dyn(.black.withAlphaComponent(0.30), .white.withAlphaComponent(0.32))
    static let accent = Color(nsColor: .controlAccentColor)
    /// 5 小时进度：系统蓝
    static let fiveHour = Color(nsColor: NSColor(hex: 0x0A84FF))
    /// 本周进度：绿
    static let week = ok

    static func level(_ l: Level) -> Color {
        switch l {
        case .ok: return ok
        case .warn: return warn
        case .bad: return bad
        case .off: return t2
        }
    }

    static func bar(_ tint: BarTint, kind: WindowKind) -> Color {
        switch tint {
        case .native: return kind == .fiveHour ? fiveHour : week
        case .warn: return warn
        case .bad: return bad
        }
    }
}

/// 动效：只在页面推入 / 返回、开关切换时有；尊重「减少动态效果」
enum Motion {
    static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static func ease(_ d: Double = 0.18) -> Animation? { reduce ? nil : .easeOut(duration: d) }
}

/// 鼠标悬停状态放在 ObservableObject 里（不用 @State：macOS 27 SDK 起它是宏，命令行工具构建不了）
final class HoverState: ObservableObject {
    @Published var on = false
}

struct HoverHighlight: ViewModifier {
    var radius: CGFloat = 7
    var color: Color = T.hover
    @StateObject private var hover = HoverState()

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(hover.on ? color : .clear))
            .onHover { hover.on = $0 }
    }
}

extension View {
    func hoverHighlight(radius: CGFloat = 7) -> some View { modifier(HoverHighlight(radius: radius)) }
}

/// 可点击处鼠标变小手。macOS 15 起用系统的指针样式；14 退回悬停时切换光标
struct HandCursor: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(.link)
        } else {
            content.onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }
}

extension View {
    func handCursor() -> some View { modifier(HandCursor()) }
}

/// 细分隔线
struct Hairline: View {
    var inset: CGFloat = 12
    var body: some View {
        Rectangle().fill(T.sep).frame(height: 0.5).padding(.horizontal, inset)
    }
}

/// 卡片底：半透明 + 0.5pt 细边
struct CardBackground: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(T.card))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(T.sep, lineWidth: 0.5))
    }
}

extension View {
    func card(_ radius: CGFloat = 9) -> some View { modifier(CardBackground(radius: radius)) }
}

/// 分段选择器（自绘）：系统分段控件在面板不抢焦点时会画成「非激活」的灰色
struct Segmented<V: Hashable>: View {
    let options: [(V, String)]
    let selection: V
    let onSelect: (V) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, title in
                let on = value == selection
                Text(title)
                    .font(F.sys(10.5, on ? .semibold : .medium))
                    .foregroundStyle(on ? Color.white : T.t2)
                    .lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 2.5)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(on ? T.accent : .clear))
                    .contentShape(Rectangle())
                    .handCursor()
                    .onTapGesture { if !on { onSelect(value) } }
            }
        }
        .padding(1.5)
        .card(6.5)
        .fixedSize()
    }
}

/// 开关（自绘），与分段同用系统强调色
struct Switch: View {
    let isOn: Bool
    var enabled = true
    let onChange: (Bool) -> Void

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? T.accent : T.off)
            Circle().fill(.white).frame(width: 12, height: 12)
                .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
                .padding(1.5)
        }
        .frame(width: 26, height: 15)
        .opacity(enabled ? 1 : 0.5)
        .contentShape(Rectangle())
        .handCursor()
        .onTapGesture { if enabled { onChange(!isOn) } }
        .animation(Motion.ease(0.15), value: isOn)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "开" : "关")
    }
}

/// 小号文字按钮（行内「切换」「刷新」、详情页按钮）
struct SmallButtonStyle: ButtonStyle {
    enum Kind { case normal, primary, danger }
    var kind: Kind = .normal
    var stretch = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(F.sys(11, .medium))
            .lineLimit(1)
            .foregroundStyle(kind == .primary ? Color.white : kind == .danger ? T.bad : Color.primary)
            .padding(.horizontal, 10).padding(.vertical, stretch ? 5 : 3)
            .frame(maxWidth: stretch ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(kind == .primary ? T.accent : T.card))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(kind == .primary ? .clear : T.sep, lineWidth: 0.5))
            .contentShape(Rectangle())
            .handCursor()
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// 图标按钮（底部工具栏、返回、「⋯」）
struct IconButtonStyle: ButtonStyle {
    var size = CGSize(width: 26, height: 24)
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(T.t2)
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .handCursor()
            .hoverHighlight(radius: 6)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

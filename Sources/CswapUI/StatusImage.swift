import AppKit
import CswapCore

/// 状态栏图标：Claude 托盘模板图 + 百分比（一个数单行；两个数上下两行，上 5 小时、下本周）。
/// 全部正常时画成模板图，由系统按菜单栏深浅色着色、带原生的半透明质感；
/// 有橙 / 红时才画彩色图：图标与正常的数用 labelColor（绘制时按菜单栏外观解析），橙 / 红的数用警告 / 危险色。做法同 NetHub
@MainActor
public enum StatusImage {
    static let iconSize: CGFloat = 18
    static let gap: CGFloat = 4
    static let singleFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    static let stackedFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    static let stackedLineHeight: CGFloat = 10

    static func color(_ level: Level, fallback: NSColor) -> NSColor {
        switch level {
        case .warn: return .dyn(NSColor(hex: 0xC46F00), NSColor(hex: 0xFFB340))
        case .bad: return .dyn(NSColor(hex: 0xD3271C), NSColor(hex: 0xFF6961))
        default: return fallback
        }
    }

    public static func make(_ label: MenuBarLabel, height: CGFloat = NSStatusBar.system.thickness) -> NSImage {
        let colored = label.items.contains { $0.level == .warn || $0.level == .bad }
        let stacked = label.items.count > 1
        let font = stacked ? stackedFont : singleFont
        let textW = label.items.map { ceil(($0.text as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
        let size = NSSize(width: iconSize + gap + textW, height: height)
        let tray = Assets.tray

        let image = NSImage(size: size, flipped: false) { rect in
            let fg: NSColor = colored ? .labelColor : .black
            let iconRect = NSRect(x: 0, y: (rect.height - iconSize) / 2, width: iconSize, height: iconSize)
            let tinted = NSImage(size: iconRect.size, flipped: false) { r in
                tray.draw(in: r)
                fg.set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: iconRect)

            let x0 = iconSize + gap
            let lineH = stacked ? stackedLineHeight : rect.height
            let textH = ("0" as NSString).size(withAttributes: [.font: font]).height
            let blockH = lineH * CGFloat(label.items.count - 1) + textH
            var y = (rect.height + blockH) / 2 - textH
            for item in label.items {
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color(item.level, fallback: fg)]
                let w = (item.text as NSString).size(withAttributes: attrs).width
                // 两行时右对齐，个位数与十位数的百分号对齐
                let x = stacked ? x0 + textW - w : x0
                (item.text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
                y -= lineH
            }
            return true
        }
        image.isTemplate = !colored
        image.accessibilityDescription = label.tooltip
        return image
    }
}

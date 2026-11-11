import CswapCore
import SwiftUI

// MARK: - 头像与档位徽章

/// 圆形 Claude 头像：当前账号彩色；其他灰度 45%；不参与自动切换 / 登录失效灰度 25%
struct AvatarView: View {
    let style: AvatarStyle
    let size: CGFloat

    var body: some View {
        Image(nsImage: Assets.avatar)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .grayscale(style == .color ? 0 : 1)
            .opacity(style == .color ? 1 : style == .idle ? 0.45 : 0.25)
            .accessibilityHidden(true)
    }
}

/// 档位徽章（高 16，圆角 5，左侧 9pt 星形 + 文字），样式见 docs/03 §5
struct TierBadgeView: View {
    let badge: TierBadge

    private static let proText = Color.dyn(NSColor(hex: 0xC2501F), NSColor(hex: 0xFF9A72))
    private static let proFill = Color.dyn(NSColor(hex: 0xEC6B41, alpha: 0.14), NSColor(hex: 0xEC6B41, alpha: 0.20))
    private static let teamText = Color.dyn(NSColor(hex: 0x2E6BD6), NSColor(hex: 0x7DA8FF))
    private static let teamFill = Color.dyn(NSColor(hex: 0x2E6BD6, alpha: 0.13), NSColor(hex: 0x5082FF, alpha: 0.20))

    var body: some View {
        HStack(spacing: 3) {
            icon.frame(width: 9, height: 9)
            if !badge.name.isEmpty {
                Text(badge.name).foregroundStyle(textColor)
            }
            if badge.expired {
                Text("已到期").foregroundStyle(T.warn)
            }
        }
        .font(F.sys(9.5, .semibold))
        .lineLimit(1)
        .padding(.leading, 4).padding(.trailing, 6)
        .frame(height: 16)
        .background(background)
        .overlay(border)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var icon: some View {
        if badge.style == .team && !badge.expired {
            Image(systemName: "person.2.fill").resizable().scaledToFit().foregroundStyle(Self.teamText)
        } else {
            Image(nsImage: Assets.star).resizable().renderingMode(.template).foregroundStyle(starColor)
        }
    }

    private var textColor: Color {
        if badge.expired { return T.t2 }
        switch badge.style {
        case .free, .unknown: return T.t2
        case .pro: return Self.proText
        case .max5: return .white
        case .max20: return Color(nsColor: NSColor(hex: 0xFFE1C8))
        case .team: return Self.teamText
        }
    }

    private var starColor: Color {
        if badge.expired { return T.t3 }
        switch badge.style {
        case .free, .unknown: return T.t3
        case .pro: return Self.proText
        case .max5: return .white
        case .max20: return Color(nsColor: NSColor(hex: 0xFF9A62))
        case .team: return Self.teamText
        }
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 5, style: .continuous) }

    @ViewBuilder private var background: some View {
        if badge.expired {
            shape.fill(T.track)
        } else {
            switch badge.style {
            case .free, .unknown: Color.clear
            case .pro: shape.fill(Self.proFill)
            case .max5: shape.fill(LinearGradient(colors: [Color(nsColor: NSColor(hex: 0xEE8460)), Color(nsColor: NSColor(hex: 0xE2582E))],
                                                  startPoint: .top, endPoint: .bottom))
            case .max20: shape.fill(LinearGradient(colors: [Color(nsColor: NSColor(hex: 0x3A2219)), Color(nsColor: NSColor(hex: 0x22130D))],
                                                   startPoint: .top, endPoint: .bottom))
            case .team: shape.fill(Self.teamFill)
            }
        }
    }

    @ViewBuilder private var border: some View {
        if !badge.expired && (badge.style == .free || badge.style == .unknown) {
            shape.strokeBorder(T.off, lineWidth: 0.5)
        } else if !badge.expired && badge.style == .max20 {
            shape.strokeBorder(Color(nsColor: NSColor(hex: 0xFFAA78, alpha: 0.55)), lineWidth: 0.5)
        }
    }
}

// MARK: - 进度条与用量卡

/// 进度条：已用量；本周卡带均速竖线
struct UsageBar: View {
    let pct: Double?
    let tint: BarTint
    let kind: WindowKind
    var pace: Double?
    var height: CGFloat = 5

    var body: some View {
        // 均速竖线比条高：画在 overlay 里，不参与布局（否则会把整条撑高）
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(T.track).frame(height: height)
                Capsule().fill(T.bar(tint, kind: kind))
                    .frame(width: max(0, min(1, (pct ?? 0) / 100)) * w, height: height)
            }
            .overlay(alignment: .leading) {
                if let pace {
                    RoundedRectangle(cornerRadius: 1).fill(T.t2)
                        .frame(width: 1.5, height: height + 6)
                        .offset(x: max(0, min(1, pace / 100)) * w - 0.75)
                }
            }
        }
        .frame(height: height)
    }
}

struct UsageCardView: View {
    let card: UsageCard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.kind.label).font(F.sys(10, .semibold)).foregroundStyle(T.t3)
                Spacer(minLength: 2)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(card.value).font(F.num(12.5, .semibold))
                    Text("%").font(F.sys(9.5, .medium)).foregroundStyle(T.t2)
                }
            }
            UsageBar(pct: card.pct, tint: card.tint, kind: card.kind, pace: card.pace).padding(.top, 7)
            CardFoot(foot: card.foot, alert: card.exhaustion).padding(.top, 6)
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(9)
        .accessibilityElement(children: .combine)
    }
}

/// 用量卡底行：有「预计 X 用完」时与「X 刷新」轮流显示，各停 3 秒；
/// 切换用「向上推」：旧的一行往上淡出、新的一行从下面淡入（同一个位置，像滚动的提示牌），
/// 两行字长短不一也不跳动。减少动态效果时改成原地淡入淡出。
struct CardFoot: View {
    let foot: String
    let alert: String?
    static let hold: TimeInterval = 3

    var body: some View {
        if let alert {
            TimelineView(.periodic(from: .now, by: Self.hold)) { ctx in
                let showAlert = Int(ctx.date.timeIntervalSinceReferenceDate / Self.hold) % 2 == 0
                ZStack(alignment: .leading) {
                    line(showAlert ? alert : foot, warn: showAlert)
                        .id(showAlert)
                        .transition(Motion.reduce ? .opacity : .asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                .animation(.smooth(duration: 0.45), value: showAlert)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(alert)，\(foot)")
        } else {
            line(foot, warn: false)
        }
    }

    private func line(_ text: String, warn: Bool) -> some View {
        Text(text).font(F.num(9.5, .medium)).foregroundStyle(warn ? T.warn : T.t2).lineLimit(1)
    }
}

/// 两张用量卡并排（试过各占一行，用户不要，见 docs/07）
struct UsageCards: View {
    let cards: [UsageCard]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(cards, id: \.kind.label) { UsageCardView(card: $0) }
        }
        .padding(.horizontal, 10)
    }
}

/// 账号行里的迷你条：30pt 宽的细条 + 「5 小时 0%」
/// 账号行里的一列：上「▬ 5 小时 30%」，下刷新时间。
/// 定宽（够放「23 时 59 分后刷新」），各行的第二列才能上下对齐
struct MiniBarView: View {
    let bar: MiniBar
    static let width: CGFloat = 92
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                UsageBar(pct: bar.pct, tint: bar.tint, kind: bar.kind, height: 3).frame(width: 24)
                Text(bar.text).font(F.num(10, .medium)).foregroundStyle(T.t2).fixedSize()
            }
            Text(bar.foot).font(F.num(9.5)).foregroundStyle(T.t3).fixedSize()
        }
        .frame(minWidth: Self.width, alignment: .leading)
    }
}

// MARK: - 设置页零件

/// 分组标题
struct GroupTitle: View {
    let text: String
    var body: some View {
        Text(text).font(F.sys(10.5, .semibold)).foregroundStyle(T.t3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.top, 10)
    }
}

/// 分组下的说明文字
struct GroupNote: View {
    let text: String
    var body: some View {
        Text(text).font(F.sys(10, .medium)).foregroundStyle(T.t3).lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.top, 5)
    }
}

/// 卡片分组；行与行之间放 RowSeparator（Group(subviews:) 要 macOS 15，最低系统是 14）
struct GroupBox<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .card(9)
        .padding(.horizontal, 10).padding(.top, 8)
    }
}

/// 分组内行与行之间的细线
struct RowSeparator: View {
    var body: some View { Rectangle().fill(T.sep).frame(height: 0.5) }
}

/// 设置行：标题 + 可选副标题 + 右侧控件
struct SettingRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var subtitleColor: Color = T.t2
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(F.sys(12, .medium))
                if let subtitle {
                    Text(subtitle).font(F.sys(10.5)).foregroundStyle(subtitleColor).lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(minHeight: 30)
        .contentShape(Rectangle())
    }
}

/// 行尾的右箭头
struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(T.t3)
            .padding(.leading, 2)
    }
}

/// 右侧数值文字
struct ValueText: View {
    let text: String
    var color: Color = T.t2
    var body: some View {
        Text(text).font(F.num(11.5, .medium)).foregroundStyle(color).lineLimit(1)
    }
}

/// 单选圆点
struct Radio: View {
    let on: Bool
    var body: some View {
        Circle()
            .strokeBorder(on ? T.accent : T.off, lineWidth: on ? 4.5 : 1.2)
            .frame(width: 14, height: 14)
    }
}

/// − 数值 + 步进器
struct StepperView: View {
    let value: String
    let onMinus: () -> Void
    let onPlus: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onMinus) { Text("−").frame(width: 24, height: 20).contentShape(Rectangle()) }.buttonStyle(.plain).handCursor()
            Rectangle().fill(T.sep).frame(width: 0.5, height: 20)
            Text(value).font(F.num(11.5, .medium)).frame(minWidth: 30).padding(.horizontal, 4)
            Rectangle().fill(T.sep).frame(width: 0.5, height: 20)
            Button(action: onPlus) { Text("+").frame(width: 24, height: 20).contentShape(Rectangle()) }.buttonStyle(.plain).handCursor()
        }
        .font(F.sys(12, .medium))
        .card(6)
        .fixedSize()
    }
}

/// 拖动中的临时值（不用 @State：命令行工具构建不了宏）
final class DragValue: ObservableObject {
    @Published var value: Double?
}

/// 百分比滑块（自绘：系统滑块在不抢焦点的面板里画成非激活色）。拖动时只改显示，松手才提交
struct PctSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    let onCommit: (Double) -> Void
    /// 拖动中实时回报（右侧数字跟着变）
    var onDrag: (Double?) -> Void = { _ in }
    @StateObject private var drag = DragValue()

    var body: some View {
        GeometryReader { g in
            let w = g.size.width - 14
            let shown = drag.value ?? value
            let x = CGFloat((shown - range.lowerBound) / (range.upperBound - range.lowerBound)) * w
            ZStack(alignment: .leading) {
                Capsule().fill(T.track).frame(height: 3).padding(.horizontal, 7)
                Capsule().fill(T.accent).frame(width: max(0, x), height: 3).padding(.leading, 7)
                Circle().fill(.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                    .frame(width: 14, height: 14)
                    .offset(x: x)
            }
            .frame(height: 18)
            .contentShape(Rectangle())
            .handCursor()
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let raw = range.lowerBound + Double(max(0, min(w, v.location.x - 7)) / max(w, 1)) * (range.upperBound - range.lowerBound)
                    let snapped = min(range.upperBound, max(range.lowerBound, (raw / step).rounded() * step))
                    drag.value = snapped
                    onDrag(snapped)
                }
                .onEnded { _ in
                    if let v = drag.value, v != value { onCommit(v) }
                    drag.value = nil
                    onDrag(nil)
                })
        }
        .frame(height: 18)
        .accessibilityElement()
        .accessibilityValue("\(Fmt.pct(value))%")
        .accessibilityAdjustableAction { dir in
            let next = dir == .increment ? value + step : value - step
            onCommit(min(range.upperBound, max(range.lowerBound, next)))
        }
    }
}

/// 状态点 + 文字（头部）
struct StatusPill: View {
    let verdict: Verdict
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(T.level(verdict.level)).frame(width: 6, height: 6)
            Text(verdict.text).font(F.sys(10.5, .semibold)).lineLimit(1)
        }
        .foregroundStyle(T.level(verdict.level))
        .fixedSize()
    }
}

/// 提示框（橙 / 红底）
struct AlertBox<Actions: View>: View {
    let text: String
    var level: Level = .warn
    @ViewBuilder var actions: Actions

    var body: some View {
        let c = T.level(level)
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 10.5, weight: .semibold)).padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                Text(text).font(F.sys(10.5, .medium)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                actions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(c)
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(c.opacity(0.1)))
        .padding(.horizontal, 10).padding(.top, 6)
    }
}

extension AlertBox where Actions == EmptyView {
    init(text: String, level: Level = .warn) {
        self.init(text: text, level: level) { EmptyView() }
    }
}

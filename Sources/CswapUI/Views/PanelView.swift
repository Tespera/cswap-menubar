import CswapCore
import SwiftUI

/// 面板内容（宽 320pt）。主面板 + 推入式子页（账号详情、自动切换、通用设置、切换记录）
public struct PanelView: View {
    let model: PanelModel
    public static let width: CGFloat = 320

    public init(model: PanelModel) { self.model = model }

    public var body: some View {
        ZStack(alignment: .top) {
            switch model.pages.last {
            case nil:
                MainPage(model: model).transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading)))
            case .detail(let n)?:
                SubPage(model: model, title: "账号详情") { AccountDetailView(model: model, number: n) }
                    .transition(.move(edge: .trailing))
            case .autoSwitch?:
                SubPage(model: model, title: "自动切换") { AutoSwitchView(model: model) }.transition(.move(edge: .trailing))
            case .settings?:
                SubPage(model: model, title: "设置") { GeneralSettingsView(model: model) }.transition(.move(edge: .trailing))
            case .history?:
                SubPage(model: model, title: "切换记录") { HistoryView(model: model) }.transition(.move(edge: .trailing))
            }
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        // 内容一律贴顶：窗口高度跟上之前若有一瞬不一致，也只是底边在动，内容不会上下跳
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped()
        .animation(Motion.ease(), value: model.pages)
        .font(F.sys(12))
    }
}

// MARK: - 子页外壳

/// 子页：左上角返回 + 标题 + 下方细线；内容超出屏幕可用高度时滚动
struct SubPage<Content: View>: View {
    let model: PanelModel
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { model.pop() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(IconButtonStyle(size: CGSize(width: 22, height: 22)))
                .padding(.leading, -4)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("返回")
                Text(title).font(F.sys(13, .semibold))
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
            Rectangle().fill(T.sep).frame(height: 0.5)
            Scrollable(model: model, reserved: 42) {
                VStack(spacing: 0) {
                    content
                    if let t = model.toast { ToastLine(toast: t).padding(.top, 8) }
                }
                .padding(.bottom, 12)
            }
        }
    }
}

/// 高度上限布局：内容理想高度不超过 limit 时按内容高，超过时截到 limit（里面的滚动视图开始滚动）。
/// 一次布局就定下尺寸：不用「先量内容高度、下一轮再设」，那样每次内容变化都会多出一帧中间态（闪烁）
struct CapHeight: Layout {
    var limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, limit))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// 不超过面板最大高度时原样显示，超出时滚动。截图工具里不用滚动视图（ImageRenderer 画不出来）
struct Scrollable<Content: View>: View {
    let model: PanelModel
    var reserved: CGFloat = 0
    @ViewBuilder let content: Content

    var body: some View {
        if model.isPreview {
            content
        } else {
            CapHeight(limit: max(200, model.maxHeight - reserved)) {
                ScrollView(.vertical) { content }
                    .scrollBounceBehavior(.basedOnSize)
            }
        }
    }
}

/// 底部 / 子页里的临时提示
struct ToastLine: View {
    let toast: Toast
    var body: some View {
        Text(toast.text)
            .font(F.sys(10.5, .medium))
            .foregroundStyle(toast.level == .ok ? T.t2 : T.level(toast.level))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
    }
}

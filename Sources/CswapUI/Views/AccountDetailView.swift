import CswapCore
import SwiftUI

/// 局部界面状态（不用 @State）
final class DetailState: ObservableObject {
    @Published var aliasDraft: String?
    @Published var dragging: Double?
}

/// 账号详情：用量、登录、自动切换（参与、单独阈值、优先级）、别名、操作
struct AccountDetailView: View {
    let model: PanelModel
    let number: Int
    @StateObject private var state = DetailState()

    var body: some View {
        if let d = model.detail(number) {
            content(d)
        } else {
            Text("这个账号已经不在了").font(F.sys(12)).foregroundStyle(T.t2).padding(20)
        }
    }

    @ViewBuilder private func content(_ d: AccountDetail) -> some View {
        let r = d.row
        let busy = model.busy.contains(number)
        HStack(spacing: 11) {
            AvatarView(style: r.avatar, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(r.name).font(F.sys(13.5, .semibold)).lineLimit(1).truncationMode(.middle)
                    if let t = r.tier { TierBadgeView(badge: t) }
                }
                Text(r.email).font(F.sys(11, .medium)).foregroundStyle(T.t2).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            // 占位固定：转圈出现 / 消失时不挤动布局
            ProgressView().controlSize(.small).opacity(busy ? 1 : 0)
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)

        if r.isBroken {
            AlertBox(text: "登录已失效，在终端重新登录后点刷新", level: .bad) {
                Button("刷新") { model.relogin(number) }.buttonStyle(SmallButtonStyle()).disabled(busy)
            }
        } else if !d.cards.isEmpty {
            UsageCards(cards: d.cards).padding(.top, 6)
        }

        GroupTitle(text: "登录")
        GroupBox {
            SettingRow(title: "有效期至") { ValueText(text: d.loginExpiry) }
            RowSeparator()
            SettingRow(title: "令牌状态") {
                ValueText(text: d.tokenStatus.text, color: d.tokenStatus.level == .ok ? T.t2 : T.level(d.tokenStatus.level))
            }
        }

        GroupTitle(text: "自动切换")
        GroupBox {
            SettingRow(title: "参与自动切换") {
                Switch(isOn: d.participates) { model.setParticipates(number, $0) }
            }
            RowSeparator()
            thresholdRows(d)
            RowSeparator()
            SettingRow(title: "优先级", subtitle: "仅「按我排的顺序」时生效") {
                StepperView(value: d.priority.map(String.init) ?? "—",
                            onMinus: { model.setPriority(number, (d.priority ?? 0) - 1) },
                            onPlus: { model.setPriority(number, (d.priority ?? 0) + 1) })
            }
        }

        GroupTitle(text: "别名")
        GroupBox {
            HStack(spacing: 6) {
                aliasField(d)
                if let draft = state.aliasDraft, draft != d.alias {
                    Button("保存") { saveAlias(d) }.buttonStyle(SmallButtonStyle(kind: .primary))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
        }
        actions(d, busy: busy)
    }

    /// 别名输入框（系统控件：截图工具画不出来，截图时画成静态文字）
    @ViewBuilder private func aliasField(_ d: AccountDetail) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Group {
            if model.isPreview {
                Text(d.alias.isEmpty ? "起个短名字，例如「备用号」" : d.alias)
                    .foregroundStyle(d.alias.isEmpty ? T.t3 : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("起个短名字，例如「备用号」", text: Binding(
                    get: { state.aliasDraft ?? d.alias },
                    set: { state.aliasDraft = $0 }))
                    .textFieldStyle(.plain)
                    .onSubmit { saveAlias(d) }
            }
        }
        .font(F.sys(12, .medium))
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(shape.fill(T.field))
        .overlay(shape.strokeBorder(T.sep, lineWidth: 0.5))
    }

    @ViewBuilder private func actions(_ d: AccountDetail, busy: Bool) -> some View {
        let r = d.row
        HStack(spacing: 6) {
            if !r.isCurrent && !r.isBroken {
                Button("切换到这个账号") { model.switchTo(number) }.buttonStyle(SmallButtonStyle(kind: .primary, stretch: true))
            }
            Button("用它开终端") { model.openTerminal(number) }.buttonStyle(SmallButtonStyle(stretch: true))
        }
        .disabled(busy)
        .padding(.horizontal, 10).padding(.top, 12)
        HStack {
            Button("移除账号…") { model.remove(number) }.buttonStyle(SmallButtonStyle(kind: .danger, stretch: true))
        }
        .disabled(busy)
        .padding(.horizontal, 10).padding(.top, 6)
    }

    /// 单账号阈值：开关「单独设切换阈值」，打开后出现滑块（与自动切换页「本周额度单独设阈值」同一种做法）。
    /// 关闭 = 跟随全局；打开时从全局值起步
    @ViewBuilder private func thresholdRows(_ d: AccountDetail) -> some View {
        let global = model.config?.threshold ?? 90
        SettingRow(title: "单独设切换阈值",
                   subtitle: d.threshold == nil ? "关闭时跟随全局 \(Fmt.pct(global))%" : "用到多少就从这个号换走") {
            Switch(isOn: d.threshold != nil) { on in model.setAccountThreshold(number, on ? global : nil) }
        }
        if let t = d.threshold {
            RowSeparator()
            VStack(spacing: 6) {
                HStack {
                    Text("切换阈值").font(F.sys(12, .medium))
                    Spacer()
                    ValueText(text: "\(Command.number(state.dragging ?? t))%")
                }
                PctSlider(value: t, range: 50...99.5, step: 0.5,
                          onCommit: { model.setAccountThreshold(number, $0) },
                          onDrag: { state.dragging = $0 })
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
        }
    }

    private func saveAlias(_ d: AccountDetail) {
        guard let draft = state.aliasDraft?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        state.aliasDraft = nil
        guard draft != d.alias else { return }
        model.setAlias(number, draft)
    }
}

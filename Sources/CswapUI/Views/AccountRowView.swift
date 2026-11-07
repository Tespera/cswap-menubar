import CswapCore
import SwiftUI

/// 账号行（Wi‑Fi 菜单式）：当前账号整行浅蓝底；整行点进详情；「切换」「刷新」按钮各自响应；右键出账号菜单。
/// 不放「⋯」按钮：里面的操作账号详情里都有（用户 2026-11-07）
struct AccountRowView: View {
    let model: PanelModel
    let row: AccountRow

    var body: some View {
        let busy = model.busy.contains(row.number)
        HStack(spacing: 9) {
            AvatarView(style: row.avatar, size: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(row.name).font(F.sys(12, .medium)).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(row.isDisabled || row.isBroken ? T.t2 : .primary)
                    if let t = row.tier { TierBadgeView(badge: t) }
                    if row.isDisabled {
                        Image(systemName: "pause.fill").font(.system(size: 8.5)).foregroundStyle(T.t3)
                            .accessibilityLabel("不参与自动切换")
                    }
                }
                meta
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if busy {
                ProgressView().controlSize(.mini).frame(width: 22)
            } else if let action = row.action {
                switch action {
                case .switchTo:
                    Button("切换") { model.switchTo(row.number) }.buttonStyle(SmallButtonStyle())
                case .relogin:
                    Button { model.relogin(row.number) } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .semibold))
                            Text("刷新")
                        }
                    }
                    .buttonStyle(SmallButtonStyle())
                    .help("在终端重新登录这个号之后点这里")
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background {
            if row.isCurrent {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.accent.opacity(0.12))
            }
        }
        .contentShape(Rectangle())
        .hoverHighlight(radius: 8)
        .handCursor()
        .padding(.horizontal, 4)
        .onTapGesture { model.push(.detail(row.number)) }
        .contextMenu { AccountMenuItems(model: model, row: row) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.name)\(row.isCurrent ? "，当前账号" : "")")
    }

    @ViewBuilder private var meta: some View {
        Group {
            switch row.meta {
            case .usage(let bars):
                HStack(spacing: 10) { ForEach(bars, id: \.kind.label) { MiniBarView(bar: $0) } }
            case .disabled(let bar):
                HStack(spacing: 10) {
                    Text("不参与自动切换").foregroundStyle(T.t2)
                    if let bar { MiniBarView(bar: bar) }
                }
            case .broken(let text):
                Text(text).foregroundStyle(T.bad).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            case .note(let text):
                Text(text).foregroundStyle(T.t2)
            }
        }
        .font(F.sys(10, .medium))
        .lineLimit(1)
    }
}

/// 账号右键菜单
struct AccountMenuItems: View {
    let model: PanelModel
    let row: AccountRow

    var body: some View {
        Button("切换到这个账号") { model.switchTo(row.number) }
            .disabled(row.isCurrent || row.isBroken)
        Divider()
        Button("账号详情…") { model.push(.detail(row.number)) }
        Button("设置别名…") { model.editAlias(row.number) }
        Toggle("不参与自动切换", isOn: Binding(get: { row.isDisabled }, set: { model.setParticipates(row.number, !$0) }))
        Divider()
        Button("用这个号开一个终端") { model.openTerminal(row.number) }
        Button("复制邮箱") { model.copyEmail(row.number) }
        Divider()
        Button("移除账号…", role: .destructive) { model.remove(row.number) }
    }
}

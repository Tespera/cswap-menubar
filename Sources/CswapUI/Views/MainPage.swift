import CswapCore
import SwiftUI

/// 主面板：头部 → 两张用量卡 → 节奏提示 → 账号列表 → 自动切换行 → 底部工具栏
struct MainPage: View {
    let model: PanelModel

    var body: some View {
        let o = model.overview
        VStack(spacing: 0) {
            if let blocker = o.blocker {
                BlockerView(model: model, blocker: blocker)
            } else {
                content(o)
            }
            Toolbar(model: model, footer: o.footer)
        }
    }

    @ViewBuilder private func content(_ o: Overview) -> some View {
        if let h = o.header {
            HStack(spacing: 8) {
                AvatarView(style: .color, size: 22)
                Text(h.name).font(F.sys(13, .semibold)).lineLimit(1).truncationMode(.middle)
                if let t = h.tier { TierBadgeView(badge: t) }
                Spacer(minLength: 4)
                StatusPill(verdict: h.verdict)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 9)
        }
        if !o.cards.isEmpty { UsageCards(cards: o.cards) }
        if let v = model.cswapVersion, CswapVersion.isOlder(v, than: CswapVersion.minimum) {
            AlertBox(text: "cswap \(v) 太旧，部分信息可能显示不全，建议升级到 \(CswapVersion.minimum) 以上") {
                Button("升级") { model.upgrade() }.buttonStyle(SmallButtonStyle()).disabled(model.upgrading)
            }
        }

        HStack {
            Text("账号").font(F.sys(10.5, .semibold)).foregroundStyle(T.t3)
            Spacer()
            Button { model.addAccount() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
                    Text("添加").font(F.sys(10.5, .medium))
                }
                .foregroundStyle(T.t2)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .hoverHighlight(radius: 5)
            }
            .buttonStyle(.plain)
            .handCursor()
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)

        Scrollable(model: model, reserved: 330) {
            VStack(spacing: 4) {
                ForEach(o.rows) { AccountRowView(model: model, row: $0) }
            }
        }

        Hairline().padding(.top, 6)
        AutoSwitchRow(model: model, row: o.autoRow)
    }
}

/// 自动切换行：开关直接切换；点开关以外区域进入设置页
struct AutoSwitchRow: View {
    let model: PanelModel
    let row: AutoRow

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.left.arrow.right").font(.system(size: 13, weight: .medium)).foregroundStyle(T.t2)
                .frame(width: RowMetrics.leading)
            VStack(alignment: .leading, spacing: 4) {
                Text("自动切换").font(F.sys(12, .medium))
                Text(row.subtitle).font(F.sys(10.5)).lineLimit(2)
                    .foregroundStyle(row.level == .warn || row.level == .bad ? T.level(row.level) : T.t2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Switch(isOn: model.autoEnabled, enabled: model.cli == .ready) { model.setAutoEnabled($0) }
            Chevron()
        }
        .frame(minHeight: RowMetrics.contentHeight)
        .padding(.horizontal, 10).padding(.vertical, RowMetrics.vPadding)
        .contentShape(Rectangle())
        .hoverHighlight(radius: 8)
        .handCursor()
        .padding(.horizontal, 4)
        .padding(.top, Toolbar.topGap)  // 与下方工具栏自带的间隙相等，上下离分割线一样远
        .onTapGesture { model.push(.autoSwitch) }
    }
}

/// 底部：刷新、更新时间（或操作提示）、齿轮
struct Toolbar: View {
    let model: PanelModel
    let footer: Footer

    var body: some View {
        HStack(spacing: 4) {
            Button { Task { await model.refresh() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium))
                    .rotationEffect(.degrees(model.refreshing ? 360 : 0))
                    .animation(model.refreshing && !Motion.reduce ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                               value: model.refreshing)
            }
            .buttonStyle(IconButtonStyle())
            .disabled(model.cli != .ready)
            .help("刷新")
            .accessibilityLabel("刷新")

            Group {
                if let t = model.toast {
                    Text(t.text).foregroundStyle(t.level == .ok ? T.t2 : T.level(t.level))
                } else if let v = model.justUpdated {
                    // 新版第一次打开面板：安静的一行，关掉面板后不再出现
                    HStack(spacing: 0) {
                        Text("已更新到 \(v) · ").foregroundStyle(T.t2)
                        Button { model.push(.changelog) } label: { Text("更新日志").foregroundStyle(T.accent) }
                            .buttonStyle(.plain).handCursor()
                    }
                } else {
                    Text(footer.text).foregroundStyle(footer.level == .warn ? T.warn : T.t3)
                }
            }
            .font(F.num(10, .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)

            Button { model.push(.settings) } label: {
                Image(systemName: "gearshape").font(.system(size: 13, weight: .regular))
                    // 有要动手的更新（关了自动更新时的新版本、更新失败）：右上角小红点
                    .overlay(alignment: .topTrailing) {
                        if model.settingsBadge {
                            Circle().fill(T.bad).frame(width: 6, height: 6).offset(x: 2.5, y: -1.5)
                        }
                    }
            }
            .buttonStyle(IconButtonStyle())
            .help(model.settingsBadge ? "设置（有新版本）" : "设置")
            .accessibilityLabel(model.settingsBadge ? "设置，有新版本" : "设置")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .overlay(alignment: .top) { Rectangle().fill(T.sep).frame(height: 0.5) }
        .padding(.top, Self.topGap)
    }

    /// 工具栏分割线上方的间隙
    static let topGap: CGFloat = 6
}

/// 整个面板的特殊状态：找不到命令行、读取中、不兼容、没有账号、读不到
struct BlockerView: View {
    let model: PanelModel
    let blocker: Overview.Blocker

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch blocker {
            case .locating, .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(blocker == .locating ? "正在查找 cswap…" : "正在读取账号…").font(F.sys(12, .medium)).foregroundStyle(T.t2)
                }
                .frame(maxWidth: .infinity, minHeight: 60)
            case .missingCLI:
                title("没找到 cswap 命令行", icon: "terminal")
                body("这个 App 靠 cswap 干活。在终端运行下面的命令安装，装好后点「重新查找」。")
                Text(PanelModel.installCommand)
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(7)
                HStack {
                    Button("复制命令") { model.copyInstallCommand() }.buttonStyle(SmallButtonStyle())
                    Button("重新查找") { Task { await model.locate() } }.buttonStyle(SmallButtonStyle(kind: .primary))
                }
            case .incompatible(let why):
                title("cswap 版本不兼容", icon: "exclamationmark.triangle")
                body("\(why)。升级 cswap 后再试。")
                Button(model.upgrading ? "升级中…" : "升级 cswap") { model.upgrade() }
                    .buttonStyle(SmallButtonStyle(kind: .primary)).disabled(model.upgrading)
            case .noAccounts:
                title("还没有账号", icon: "person.crop.circle.badge.plus")
                body("先在 Claude Code 里登录一个号，再点「添加」把它交给 cswap 管理。")
                Button("添加当前登录的账号") { model.addAccount() }.buttonStyle(SmallButtonStyle(kind: .primary))
            case .failed(let why):
                title("读不到账号", icon: "exclamationmark.triangle")
                body(why)
                Button("重试") { Task { await model.refresh() } }.buttonStyle(SmallButtonStyle())
            }
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 4)
    }

    private func title(_ s: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(T.t2)
            Text(s).font(F.sys(13, .semibold))
        }
    }

    private func body(_ s: String) -> some View {
        Text(s).font(F.sys(11, .medium)).foregroundStyle(T.t2).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
    }
}

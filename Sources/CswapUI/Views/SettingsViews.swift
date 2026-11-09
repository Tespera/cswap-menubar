import CswapCore
import SwiftUI

/// 滑块拖动中的实时数值
final class LiveValues: ObservableObject {
    @Published var fiveHour: Double?
    @Published var week: Double?
}

// MARK: - 自动切换设置

struct AutoSwitchView: View {
    let model: PanelModel
    @StateObject private var live = LiveValues()

    static let strategies: [(Strategy, String, String)] = [
        (.best, "余量最多的", "默认，最稳"),
        (.weeklyFirst, "本周最先刷新的", "到线才换，先用掉快作废的额度"),
        (.consumeFirst, "始终用最先刷新的", "不到线也会换，尽量不浪费"),
        (.priorityConsumeFirst, "按我排的顺序", "先用完优先级高的，在账号详情里排"),
    ]

    static let cooldowns: [(Double, String)] = [(60, "1 分钟"), (300, "5 分钟"), (600, "10 分钟"), (1800, "30 分钟")]

    var body: some View {
        let row = model.overview.autoRow
        GroupBox {
            SettingRow(title: "自动切换", subtitle: subtitle(row), subtitleColor: row.level == .bad ? T.bad : T.t2) {
                Switch(isOn: model.autoEnabled, enabled: model.cli == .ready) { model.setAutoEnabled($0) }
            }
        }
        .padding(.top, 2)

        if let c = model.config {
            settings(c)
        } else {
            Text("正在读取 cswap 的设置…").font(F.sys(11)).foregroundStyle(T.t2).padding(14)
        }
    }

    private func subtitle(_ row: AutoRow) -> String {
        switch model.autoSwitch {
        case .failed(let why): return "没在运行：\(why)"
        case .starting: return "正在启动…"
        default: return "快用完时自动换到另一个号"
        }
    }

    @ViewBuilder private func settings(_ c: AutoSwitchConfig) -> some View {
        GroupTitle(text: "切换阈值")
        GroupBox {
            VStack(spacing: 6) {
                HStack {
                    Text("5 小时额度").font(F.sys(12, .medium))
                    Spacer()
                    ValueText(text: "\(Command.number(live.fiveHour ?? c.threshold))%")
                }
                PctSlider(value: c.threshold, range: 50...99, step: 1,
                          onCommit: { model.setConfig(ConfigKey.threshold, Command.number($0)) },
                          onDrag: { live.fiveHour = $0 })
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            RowSeparator()
            SettingRow(title: "本周额度单独设阈值", subtitle: "关闭时，本周额度和 5 小时用同一个阈值") {
                Switch(isOn: c.weeklyThreshold != nil) { on in
                    model.setConfig(ConfigKey.weeklyThreshold, on ? Command.number(min(99.5, max(c.threshold, 95))) : nil)
                }
            }
            if let wk = c.weeklyThreshold {
                RowSeparator()
                VStack(spacing: 6) {
                    HStack {
                        Text("本周额度").font(F.sys(12, .medium))
                        Spacer()
                        ValueText(text: "\(Command.number(live.week ?? wk))%")
                    }
                    PctSlider(value: wk, range: 50...99.5, step: 0.5,
                              onCommit: { model.setConfig(ConfigKey.weeklyThreshold, Command.number($0)) },
                              onDrag: { live.week = $0 })
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
            }
        }
        GroupNote(text: "本周额度到期就作废，阈值可以比 5 小时设得高些，尽量用满。")

        GroupTitle(text: "切换优先级")
        GroupBox {
            ForEach(Array(Self.strategies.enumerated()), id: \.offset) { k, s in
                if k > 0 { RowSeparator() }
                HStack(spacing: 9) {
                    Radio(on: c.strategy == s.0)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.1).font(F.sys(12, .medium))
                        Text(s.2).font(F.sys(10.5)).foregroundStyle(T.t2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .contentShape(Rectangle())
                .handCursor()
                .onTapGesture { if c.strategy != s.0 { model.setConfig(ConfigKey.strategy, s.0.rawValue) } }
                .accessibilityAddTraits(c.strategy == s.0 ? [.isButton, .isSelected] : .isButton)
            }
        }

        GroupTitle(text: "其他")
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("切换冷却").font(F.sys(12, .medium))
                    Text("换号后这段时间内不再自动换，免得来回跳").font(F.sys(10.5)).foregroundStyle(T.t2)
                }
                Segmented(options: Self.cooldowns, selection: c.cooldownSeconds) {
                    model.setConfig(ConfigKey.cooldown, Command.number($0))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 7)
            // 没有任何账号报告模型周限额时整行隐藏
            if !model.scopedModels.isEmpty {
                RowSeparator()
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("也看模型周限额").font(F.sys(12, .medium))
                        Text("某个模型单独用完时也换号").font(F.sys(10.5)).foregroundStyle(T.t2)
                    }
                    Segmented(options: [("", "不看")] + model.scopedModels.map { ($0, $0) }, selection: c.model ?? "") {
                        model.setConfig(ConfigKey.model, $0.isEmpty ? nil : $0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 7)
            }
            RowSeparator()
            SettingRow(title: "API Key 账号也参与", subtitle: "按用量计费，只在别的号都用完时才换过去") {
                Switch(isOn: c.includeApiKeyAccounts) { model.setConfig(ConfigKey.includeApiKey, $0 ? "true" : "false") }
            }
        }
    }
}

// MARK: - 通用设置

struct GeneralSettingsView: View {
    let model: PanelModel

    var body: some View {
        GroupTitle(text: "菜单栏")
        GroupBox {
            SettingRow(title: "显示") {
                Segmented(options: MenuBarDisplay.allCases.map { ($0, $0.title) }, selection: model.display) { model.setDisplay($0) }
            }
            RowSeparator()
            SettingRow(title: "刷新频率") {
                Segmented(options: [(30, "30 秒"), (60, "1 分钟"), (300, "5 分钟")], selection: model.refreshSeconds) {
                    model.setRefreshSeconds($0)
                }
            }
        }

        GroupTitle(text: "通知")
        GroupBox {
            SettingRow(title: "自动换号后") { Switch(isOn: model.notifySwitch) { model.setNotify(.notifySwitch, $0) } }
            RowSeparator()
            SettingRow(title: "所有账号都用完时") { Switch(isOn: model.notifyExhausted) { model.setNotify(.notifyExhausted, $0) } }
            RowSeparator()
            SettingRow(title: "登录快过期时", subtitle: "提前 7 天提醒") {
                Switch(isOn: model.notifyExpiry) { model.setNotify(.notifyExpiry, $0) }
            }
        }

        GroupTitle(text: "通用")
        GroupBox {
            SettingRow(title: "登录时打开") { Switch(isOn: model.launchAtLogin) { model.setLaunchAtLogin($0) } }
            RowSeparator()
            SettingRow(title: "切换记录") {
                ValueText(text: "最近 10 次")
                Chevron()
            }
            .hoverHighlight(radius: 0)
            .handCursor()
            .onTapGesture { model.push(.history) }
            RowSeparator()
            SettingRow(title: "cswap 命令行", subtitle: model.versionText,
                       subtitleColor: model.versionLevel == .off ? T.t2 : T.level(model.versionLevel)) {
                if model.upgrading {
                    HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("升级中").font(F.sys(11)).foregroundStyle(T.t2) }
                } else if model.upgradeBlocked != nil {
                    Button("复制命令") { model.copyReinstallCommand() }.buttonStyle(SmallButtonStyle(kind: .primary))
                        .help(model.upgradeBlocked?.reinstallCommand ?? "")
                } else if model.canUpgrade {
                    Button("升级") { model.upgrade() }.buttonStyle(SmallButtonStyle(kind: .primary))
                } else {
                    Button(model.checkingUpdate ? "检查中…" : "检查更新") { model.checkUpdate() }
                        .buttonStyle(SmallButtonStyle()).disabled(model.checkingUpdate || model.cli != .ready)
                }
            }
            RowSeparator()
            appRow
            if !model.isDevBuild {
                RowSeparator()
                SettingRow(title: "自动更新", subtitle: "有新版本时自动更新") {
                    Switch(isOn: model.autoUpdate) { model.setAutoUpdate($0) }
                }
            }
        }

        HStack {
            Button { model.push(.changelog) } label: {
                Text(model.appVersion).font(F.num(10.5, .medium))
            }
            .buttonStyle(.plain).handCursor().help("更新日志")
            .disabled(model.changelog.isEmpty)
            Spacer()
            Button("退出") { model.quit() }.buttonStyle(.plain).foregroundStyle(T.t2).handCursor()
                .keyboardShortcut("q", modifiers: .command)
        }
        .font(F.sys(10.5, .medium))
        .foregroundStyle(T.t3)
        .padding(.horizontal, 14).padding(.top, 12)
    }
}

extension GeneralSettingsView {
    /// 「cswap App」：版本 + 更新状态 + 按钮（状态到文案的映射在 CswapCore/AppUpdate.swift）
    @ViewBuilder var appRow: some View {
        let r = model.appUpdateRow
        SettingRow(title: "cswap App", subtitle: r.subtitle, subtitleColor: r.level == .off ? T.t2 : T.level(r.level)) {
            if r.spinning {
                ProgressView().controlSize(.mini)
            } else {
                switch r.action {
                case .check, .checking:
                    Button(r.action == .checking ? "检查中…" : "检查更新") { model.appUpdateAction(.check) }
                        .buttonStyle(SmallButtonStyle()).disabled(r.action == .checking)
                case .update:
                    Button("更新") { model.appUpdateAction(.update) }.buttonStyle(SmallButtonStyle(kind: .primary))
                case .installNow:
                    Button("立即更新") { model.appUpdateAction(.installNow) }.buttonStyle(SmallButtonStyle(kind: .primary))
                case .retry:
                    Button("重试") { model.appUpdateAction(.retry) }.buttonStyle(SmallButtonStyle())
                case .openPage:
                    Button("去下载") { model.appUpdateAction(.openPage) }.buttonStyle(SmallButtonStyle(kind: .primary))
                case .none:
                    EmptyView()
                }
            }
        }
    }
}

// MARK: - 更新日志

/// 打包时放进 App 的 CHANGELOG.md，新的在前
struct ChangelogView: View {
    let model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(model.changelog) { s in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(s.version).font(F.num(13, .semibold))
                        Text(s.date).font(F.num(10.5, .medium)).foregroundStyle(T.t3)
                        if s.version == AppVersion.current {
                            Text("当前").font(F.sys(9.5, .semibold)).foregroundStyle(T.t2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(T.t3.opacity(0.18)))
                        }
                    }
                    ForEach(Array(Self.lines(s.body).enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if line.bullet { Text("·").font(F.sys(11.5, .bold)).foregroundStyle(T.t3) }
                            Text(Self.markdown(line.text)).font(F.sys(11.5)).foregroundStyle(line.bullet ? Color.primary : T.t2)
                                .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    struct Line { var bullet: Bool; var text: String }

    /// 每行一条：「- 」开头的是列表项，其余是说明文字；空行丢掉
    static func lines(_ body: String) -> [Line] {
        body.split(separator: "\n").compactMap { raw in
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            return t.hasPrefix("- ") ? Line(bullet: true, text: String(t.dropFirst(2))) : Line(bullet: false, text: t)
        }
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

// MARK: - 切换记录

struct HistoryView: View {
    let model: PanelModel

    var body: some View {
        if model.history.isEmpty {
            Text("还没有切换记录").font(F.sys(11.5)).foregroundStyle(T.t2).padding(.vertical, 24)
        } else {
            GroupBox {
                ForEach(Array(model.history.enumerated()), id: \.offset) { k, item in
                    if k > 0 { RowSeparator() }
                    SettingRow(title: item.title, subtitle: item.source) { ValueText(text: item.time) }
                }
            }
            .padding(.top, 2)
            GroupNote(text: "经面板换的标「面板」，自动切换的标「自动」；cswap 日志不区分来源，App 没记到的标「命令行」。")
        }
    }
}

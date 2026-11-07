import AppKit
import CswapCore
import Foundation
import Observation

/// 面板内的页面（推入式导航，左上角返回）
public enum Page: Hashable, Sendable {
    case detail(Int)
    case autoSwitch
    case settings
    case history
}

/// 底部的临时提示（操作结果、错误），几秒后消失
public struct Toast: Equatable, Sendable {
    public var text: String
    public var level: Level

    public init(text: String, level: Level) {
        self.text = text
        self.level = level
    }
}

/// 面板与状态栏共用的数据和操作。视图只读它、只调它的方法；判断逻辑在 CswapCore/Overview.swift
@MainActor
@Observable
public final class PanelModel {
    // MARK: 数据
    public private(set) var cli: CLIState = .locating
    public private(set) var list: AccountList?
    private var listFetchedAt: Date?
    public private(set) var fetchError: String?
    public private(set) var refreshing = false
    private var nextRefreshAt: Date?
    public private(set) var config: AutoSwitchConfig?
    /// 优先级（解析 `cswap priority` 文字输出）；nil = 读不到，详情页隐藏当前值
    public private(set) var priorities: [Int: Int]?
    public private(set) var autoSwitch: AutoSwitchState = .off
    public private(set) var history: [HistoryItem] = []
    public private(set) var cswapVersion: String?
    public private(set) var latestVersion: String?
    public private(set) var upgrading = false
    public private(set) var checkingUpdate = false
    public private(set) var now = Date()

    // MARK: 交互状态
    public var pages: [Page] = []
    public private(set) var busy: Set<Int> = []
    public private(set) var toast: Toast?
    public var panelVisible = false
    /// 面板最大高度（跟随屏幕可用高度），超出时子页滚动
    public var maxHeight: CGFloat = 720
    /// 截图工具：不用滚动视图（ImageRenderer 画不出来）
    public let isPreview: Bool

    // MARK: 偏好
    public private(set) var display = Preferences.display
    public private(set) var refreshSeconds = Preferences.refreshSeconds
    public private(set) var notifySwitch = Preferences.flag(.notifySwitch, default: true)
    public private(set) var notifyExhausted = Preferences.flag(.notifyExhausted, default: true)
    public private(set) var notifyExpiry = Preferences.flag(.notifyExpiry, default: true)
    public private(set) var autoEnabled = Preferences.flag(.autoSwitch, default: false)
    public private(set) var launchAtLogin = LaunchAgent.isInstalled

    // MARK: 服务
    @ObservationIgnored private var cswap: CswapCLI?
    @ObservationIgnored private var env: CswapEnvironment?
    @ObservationIgnored private let auto = AutoSwitchService()
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var clock: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// 已提醒过的「都用完了」（按最早刷新时间区分），换号后清掉
    @ObservationIgnored private var exhaustedNotified: String?
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var appRecords: [HistoryRecord] = []
    @ObservationIgnored private var appNames = AppNames.load()

    init(preview: Bool) { isPreview = preview }

    /// 实际运行：定位 cswap、开始定时刷新、按开关启动自动切换
    public static func live() -> PanelModel {
        let m = PanelModel(preview: false)
        m.start()
        return m
    }

    // MARK: 派生

    public var overview: Overview {
        OverviewBuilder.build(Inputs(cli: cli, list: list, listFetchedAt: listFetchedAt, fetchError: fetchError,
                                     nextRefreshAt: nextRefreshAt, refreshing: refreshing, config: config,
                                     priorities: priorities ?? [:], autoSwitch: autoSwitch, display: display, now: now))
    }

    public func account(_ n: Int) -> Account? { list?.accounts.first { $0.number == n } }

    public func detail(_ n: Int) -> AccountDetail? {
        account(n).map { AccountDetail.build($0, activeNumber: list?.active?.number, config: config, priorities: priorities, now: now) }
    }

    /// 也看模型周限额的可选模型：各账号 scoped 窗口的模型名
    public var scopedModels: [String] {
        var seen: [String] = []
        for a in list?.accounts ?? [] {
            for w in a.usage?.scoped ?? [] { if let n = w.name, !seen.contains(n) { seen.append(n) } }
        }
        return seen
    }

    public var versionText: String {
        guard let v = cswapVersion else { return cli == .missing ? "没找到" : "读取中" }
        if CswapVersion.isOlder(v, than: CswapVersion.minimum) { return "\(v)，低于 \(CswapVersion.minimum)，建议升级" }
        if let l = latestVersion, CswapVersion.isOlder(v, than: l) { return "\(v)，可升级到 \(l)" }
        if latestVersion != nil { return "\(v)，已是最新" }
        return v
    }

    public var versionLevel: Level {
        guard let v = cswapVersion else { return .off }
        if CswapVersion.isOlder(v, than: CswapVersion.minimum) { return .warn }
        if let l = latestVersion, CswapVersion.isOlder(v, than: l) { return .warn }
        return .off
    }

    public var canUpgrade: Bool {
        guard let v = cswapVersion else { return false }
        return CswapVersion.isOlder(v, than: latestVersion ?? CswapVersion.minimum)
    }

    /// 「版本 0.1.0（构建 12）」；不在打包的 App 里运行（swift run、截图工具）时标为开发版
    public var appVersion: String {
        guard let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String else { return "版本 \(AppVersion.current)（开发版）" }
        return "版本 \(AppVersion.current)（构建 \(build)）"
    }

    // MARK: 启动与刷新

    private func start() {
        appRecords = HistoryStore.load()
        auto.onEvent = { [weak self] e in self?.handle(e) }
        auto.onState = { [weak self] s in self?.autoSwitch = s }
        notifier.requestAuthorization()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                self?.now = Date()
            }
        }
        Task { await locate() }
    }

    /// 找 cswap；找不到时面板显示安装引导，用户装好后点「重新查找」
    public func locate() async {
        cli = .locating
        guard let found = await CswapLocator.locate() else {
            cli = .missing
            auto.configure(nil)
            return
        }
        env = found
        cswap = CswapCLI(found)
        auto.configure(found)
        cli = .ready
        restartLoop()
        if autoEnabled { auto.setEnabled(true) }
        await loadVersion()
        await loadConfig()
        Task { latestVersion = await UpdateCheck.latest() }
    }

    private func restartLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let wait = self.refreshSeconds
                self.nextRefreshAt = Date().addingTimeInterval(TimeInterval(wait))
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    /// 读一次 list。已在读时只记下「读完再读一次」：操作完成后的刷新不能被定时刷新吞掉
    public func refresh() async {
        guard let cswap else { return }
        guard !refreshing else { refreshAgain = true; return }
        refreshing = true
        defer {
            refreshing = false
            if refreshAgain { refreshAgain = false; Task { await refresh() } }
        }
        do {
            var l = try await cswap.json(.list, as: AccountList.self)
            applyNames(&l)
            list = l
            listFetchedAt = Date()
            now = Date()
            fetchError = nil
            if case .incompatible = cli { cli = .ready }
            reloadHistory()
            checkExpiry(l)
        } catch let e as CLIError {
            fetchError = e.message
            if e.message.contains("不兼容") { cli = .incompatible(e.message) }
        } catch {
            fetchError = error.localizedDescription
        }
    }

    public func panelDidShow() {
        panelVisible = true
        now = Date()
        if Date().timeIntervalSince(listFetchedAt ?? .distantPast) > 5 { Task { await refresh() } }
    }

    public func panelDidHide() {
        panelVisible = false
        pages.removeAll()
    }

    private func loadVersion() async {
        guard let cswap, let out = try? await cswap.run(.version) else { return }
        cswapVersion = CswapVersion.parse(out.stdoutText + out.stderrText)
    }

    public func loadConfig() async {
        guard let cswap else { return }
        if let c = try? await cswap.json(.configList, as: ConfigList.self) { config = c.autoSwitch }
    }

    public func loadPriorities() async {
        guard let cswap, let out = try? await cswap.run(.priorities) else { return }
        priorities = PriorityParser.parse(out.stdoutText)
    }

    /// 合并 App 自己存的显示名
    private func applyNames(_ l: inout AccountList) {
        for k in l.accounts.indices { l.accounts[k].appName = appNames[l.accounts[k].email.lowercased()] }
    }

    /// 先在界面上改，命令完成后的刷新再读回真实值（避免开关、滑块先跳回旧值再跳到新值）
    private func optimistic(_ n: Int, _ change: (inout Account) -> Void) {
        guard let k = list?.accounts.firstIndex(where: { $0.number == n }) else { return }
        change(&list!.accounts[k])
    }

    private func reloadHistory() {
        let names = Dictionary((list?.accounts ?? []).map { ($0.number, OverviewBuilder.displayName($0)) }, uniquingKeysWith: { a, _ in a })
        history = SwitchLog.merge(log: HistoryStore.readLog(), records: appRecords, names: names, now: Date())
    }

    // MARK: 导航

    public func push(_ p: Page) {
        pages.append(p)
        switch p {
        case .detail: Task { await loadPriorities(); await loadConfig() }
        case .autoSwitch: Task { await loadConfig(); await loadPriorities() }
        case .history: reloadHistory()
        case .settings: break
        }
    }

    public func pop() { _ = pages.popLast() }

    // MARK: 账号操作

    /// 执行一个写命令：标记忙、出错时提示，完成后刷新
    private func perform(_ command: Command, account n: Int? = nil, success: String? = nil) async -> CommandOutput? {
        guard let cswap else { flash(CLIError.missing.message, .bad); return nil }
        if let n { busy.insert(n) }
        defer { if let n { busy.remove(n) } }
        do {
            let out = try await cswap.run(command)
            if let success { flash(success, .ok) }
            await refresh()
            return out
        } catch {
            flash("\(error)", .bad)
            await refresh()
            return nil
        }
    }

    public func switchTo(_ n: Int) {
        guard let target = account(n) else { return }
        let from = list?.active?.number
        Task {
            guard let out = await perform(.switchTo(n), account: n) else { return }
            let r = try? CswapJSON.decode(SwitchResult.self, from: out.stdout)
            if r?.switched != false {
                record(HistoryRecord(at: Date(), from: from, to: n, toEmail: target.email, source: .panel))
                flash("已换到 \(OverviewBuilder.displayName(target))", .ok)
            }
            if let w = r?.warnings?.first { flash(w, .warn) }
        }
    }

    /// 登录失效后的「刷新」（C9）：先核对当前登录的就是这个号，再存回它原来的位置；
    /// 不是同一个号时不执行（否则会把别的号写进这个位置）
    public func relogin(_ n: Int) {
        guard let a = account(n), let cswap else { return }
        let name = OverviewBuilder.displayName(a)
        Task {
            busy.insert(n)
            let status = try? await cswap.json(.status, as: StatusResponse.self)
            busy.remove(n)
            guard let current = status?.active?.email, current.lowercased() == a.email.lowercased() else {
                flash("当前登录的不是 \(name)，请先在终端用它登录", .warn)
                return
            }
            _ = await perform(.addSlot(n), account: n, success: "已刷新 \(name) 的登录")
        }
    }

    public func addAccount() {
        guard let cswap else { return }
        Task {
            let status = try? await cswap.json(.status, as: StatusResponse.self)
            let email = status?.active?.email
            guard let alias = Dialogs.confirmAdd(currentEmail: email, alreadyAdded: isManaged(email)) else { return }
            // 再核对一次：用户可能在对话框开着时换了登录
            let now = try? await cswap.json(.status, as: StatusResponse.self)
            guard let added = now?.active?.email else { flash("读不到当前登录的账号", .bad); return }
            if isManaged(added) { flash("\(added) 已经在列表里了", .warn); return }
            // 别名由 App 保存（cswap 的别名不支持大小写和中文），不传给 cswap
            if !alias.isEmpty { AppNames.set(alias, for: added); appNames = AppNames.load() }
            _ = await perform(.add(alias: nil), success: "已添加 \(alias.isEmpty ? added : alias)")
        }
    }

    private func isManaged(_ email: String?) -> Bool {
        guard let e = email?.lowercased() else { return false }
        return list?.accounts.contains { $0.email.lowercased() == e } == true
    }

    public func remove(_ n: Int) {
        guard let a = account(n) else { return }
        let name = OverviewBuilder.displayName(a)
        guard Dialogs.confirmRemove(name: name, email: a.email) else { return }
        Task {
            if await perform(.remove(n), account: n, success: "已移除 \(name)") != nil, pages.last == .detail(n) { pop() }
        }
    }

    public func editAlias(_ n: Int) {
        guard let a = account(n),
              let name = Dialogs.askAlias(name: OverviewBuilder.displayName(a), current: a.appName ?? a.alias ?? "") else { return }
        setAlias(n, name)
    }

    /// 别名由 App 保存（按邮箱）：cswap 的别名只能用小写字母、数字和 _.-，会被强制转小写。空字符串 = 清除
    public func setAlias(_ n: Int, _ name: String) {
        guard let a = account(n), name != (a.appName ?? a.alias ?? "") else { return }
        AppNames.set(name, for: a.email)
        appNames = AppNames.load()
        optimistic(n) { $0.appName = name.isEmpty ? nil : name }
        reloadHistory()
    }

    public func setParticipates(_ n: Int, _ on: Bool) {
        optimistic(n) { $0.disabled = on ? nil : true }
        Task { _ = await perform(on ? .enable(n) : .disable(n)) }
    }

    public func setAccountThreshold(_ n: Int, _ pct: Double?) {
        optimistic(n) { $0.threshold = pct }
        Task { _ = await perform(.threshold(n, pct)) }
    }

    public func setPriority(_ n: Int, _ tier: Int) {
        let clamped = min(1000, max(0, tier))
        priorities = (priorities ?? [:]).merging([n: clamped]) { _, b in b }
        Task {
            _ = await perform(.priority(n, clamped))
            await loadPriorities()
        }
    }

    public func openTerminal(_ n: Int) {
        guard let env else { return }
        do { try TerminalLauncher.open(account: n, env: env) } catch { flash("打不开终端：\(error.localizedDescription)", .bad) }
    }

    public func copyEmail(_ n: Int) {
        guard let a = account(n) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(a.email, forType: .string)
        flash("已复制 \(a.email)", .ok)
    }

    // MARK: 自动切换

    public func setAutoEnabled(_ on: Bool) {
        autoEnabled = on
        Preferences.set(.autoSwitch, on)
        auto.setEnabled(on)
    }

    /// 改 cswap 的 autoswitch.* 设置；改完重读并重启子进程
    public func setConfig(_ key: String, _ value: String?) {
        config = config.map { applying($0, key, value) }
        Task {
            _ = await perform(value.map { .configSet(key, $0) } ?? .configUnset(key))
            await loadConfig()
            auto.restart()
        }
    }

    /// 先在界面上显示新值，避免等命令时滑块跳回
    private func applying(_ c: AutoSwitchConfig, _ key: String, _ value: String?) -> AutoSwitchConfig {
        var c = c
        switch key {
        case ConfigKey.threshold: c.threshold = value.flatMap(Double.init) ?? 90
        case ConfigKey.weeklyThreshold: c.weeklyThreshold = value.flatMap(Double.init)
        case ConfigKey.cooldown: c.cooldownSeconds = value.flatMap(Double.init) ?? 300
        case ConfigKey.strategy: c.strategy = value.flatMap(Strategy.init(rawValue:)) ?? .best
        case ConfigKey.model: c.model = value
        case ConfigKey.includeApiKey: c.includeApiKeyAccounts = value == "true"
        default: break
        }
        return c
    }

    private func handle(_ e: AutoEvent) {
        switch e {
        case .switched(let from, let to, _, let dryRun, let at):
            guard !dryRun, let n = to?.number else { return }
            let fromAccount = from?.number.flatMap { account($0) }
            let notice = Notices.switched(to: account(n), toEmail: to?.email, from: fromAccount)
            record(HistoryRecord(at: at ?? Date(), from: from?.number, to: n, toEmail: to?.email, source: .auto,
                                 reason: Notices.reason(from: fromAccount)))
            exhaustedNotified = nil
            if notifySwitch { notifier.post(notice) }
            Task { await refresh() }
        case .allExhausted(let reset):
            // 用完期间每一轮都会报一次：同一次（最早刷新时间相同）只提醒一次
            let key = reset.map { "\($0.timeIntervalSince1970)" } ?? "unknown"
            guard key != exhaustedNotified else { return }
            exhaustedNotified = key
            if notifyExhausted { notifier.post(Notices.allExhausted(list: list, earliestResetAt: reset, now: Date())) }
        case .quarantined(let n, let email, _):
            let name = n.flatMap { account($0) }.map(OverviewBuilder.displayName) ?? email
            notifier.post(Notices.quarantined(name: name))
            Task { await refresh() }
        case .unquarantined:
            Task { await refresh() }
        default:
            break
        }
    }

    private func record(_ r: HistoryRecord) {
        appRecords.append(r)
        HistoryStore.append(r)
        reloadHistory()
    }

    /// 登录快过期（≤ 7 天）：每个账号每天最多一次
    private func checkExpiry(_ l: AccountList) {
        guard notifyExpiry else { return }
        for a in l.accounts {
            if let n = Notices.loginExpiring(a, now: Date()), ExpiryReminder.shouldRemind(email: a.email, now: Date()) {
                notifier.post(n, id: "expiry-\(a.email)")
            }
        }
    }

    // MARK: 通用设置

    public func setDisplay(_ d: MenuBarDisplay) {
        display = d
        Preferences.display = d
    }

    public func setRefreshSeconds(_ s: Int) {
        refreshSeconds = s
        Preferences.refreshSeconds = s
        restartLoop()
    }

    func setNotify(_ key: Preferences.Key, _ on: Bool) {
        Preferences.set(key, on)
        switch key {
        case .notifySwitch: notifySwitch = on
        case .notifyExhausted: notifyExhausted = on
        case .notifyExpiry: notifyExpiry = on
        default: break
        }
    }

    public func setLaunchAtLogin(_ on: Bool) {
        LaunchAgent.set(on)
        launchAtLogin = LaunchAgent.isInstalled
    }

    public func checkUpdate() {
        checkingUpdate = true
        Task {
            await loadVersion()
            latestVersion = await UpdateCheck.pypi() ?? latestVersion
            checkingUpdate = false
            if !canUpgrade, latestVersion != nil { flash("cswap 已是最新", .ok) }
            if latestVersion == nil { flash("查不到最新版本（网络不通？）", .warn) }
        }
    }

    /// 升级 cswap：完成后显示前后版本、重启自动切换
    public func upgrade() {
        let before = cswapVersion
        upgrading = true
        Task {
            let ok = await perform(.upgrade) != nil
            await loadVersion()
            upgrading = false
            guard ok else { return }
            if let b = before, let a = cswapVersion, a != b { flash("已从 \(b) 升级到 \(a)", .ok) }
            else { flash("cswap 已是最新", .ok) }
            auto.restart()
        }
    }

    public func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.installCommand, forType: .string)
        flash("已复制安装命令", .ok)
    }

    public static let installCommand = "uv tool install 'claude-swap[menubar]' --index-url https://mirrors.aliyun.com/pypi/simple/"

    public func quit() {
        auto.shutdown()
        NSApp.terminate(nil)
    }

    /// App 退出时结束自动切换子进程
    public func shutdown() { auto.shutdown() }

    public func flash(_ text: String, _ level: Level) {
        toast = Toast(text: text, level: level)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(level == .bad ? 6 : 3.5))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: 截图 / 调试

    /// 截图工具：用给定数据，不启动任何采集
    public static func preview(list: AccountList?, config: AutoSwitchConfig? = AutoSwitchConfig(), priorities: [Int: Int]? = nil,
                               autoSwitch: AutoSwitchState = .off, cli: CLIState = .ready, fetchError: String? = nil,
                               pages: [Page] = [], history: [HistoryItem] = [], version: String? = "0.30.0",
                               latest: String? = "0.30.0", toast: Toast? = nil, now: Date,
                               forImageRenderer: Bool = true) -> PanelModel {
        let m = PanelModel(preview: forImageRenderer)
        m.cli = cli
        m.list = list
        m.listFetchedAt = now
        m.fetchError = fetchError
        m.config = config
        m.priorities = priorities
        m.autoSwitch = autoSwitch
        m.autoEnabled = autoSwitch != .off
        m.pages = pages
        m.history = history
        m.cswapVersion = version
        m.latestVersion = latest
        m.toast = toast
        m.now = now
        m.display = .both
        m.refreshSeconds = 60
        m.notifySwitch = true
        m.notifyExhausted = true
        m.notifyExpiry = true
        m.launchAtLogin = true
        return m
    }

    /// `--dump`：打印对当前状态的理解（调试用，不显示界面）
    public var debugSummary: String {
        let o = overview
        var lines = ["cswap：\(env?.executable.path ?? "未找到")，版本 \(cswapVersion ?? "?")，最新 \(latestVersion ?? "?")",
                     "菜单栏：\(o.menuBar.items.map { "\($0.text)(\($0.level))" }.joined(separator: " / "))"]
        if let h = o.header { lines.append("当前：\(h.name) \(h.tier?.name ?? "") \(h.tier?.expired == true ? "已到期" : "") · \(h.verdict.text)") }
        lines += o.cards.map { "  \($0.kind.label) \($0.value)% \($0.foot)\($0.pace.map { " 均速 \($0)" } ?? "")" }
        if let p = o.paceNote { lines.append("  \(p)") }
        lines += o.rows.map { "账号 \($0.number) \($0.name) \($0.tier?.name ?? "") \($0.isCurrent ? "[当前]" : "") \($0.meta)" }
        lines.append("自动切换：\(o.autoRow.subtitle)")
        lines.append("底部：\(o.footer.text)")
        if let c = config { lines.append("设置：\(c)") }
        lines.append("优先级：\(priorities.map { "\($0)" } ?? "读不到")")
        lines += history.prefix(5).map { "记录：\($0.time) \($0.title) \($0.source)" }
        return lines.joined(separator: "\n")
    }
}

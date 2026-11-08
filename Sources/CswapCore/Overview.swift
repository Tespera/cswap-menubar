import Foundation

// 状态 → 界面模型的全部映射（纯函数，有测试）。视图只照着画，不做判断。
// 规则出处：docs/03-界面与设计规范.md §3–§6、docs/02-功能清单.md。

// MARK: - 基础类型

/// 语义级别：决定颜色
public enum Level: Sendable, Equatable {
    case ok, warn, bad, off
}

/// 进度条着色：窗口本色 / 警告 / 危险
public enum BarTint: Sendable, Equatable {
    case native, warn, bad

    /// 已用 ≥ 100 → 危险；≥ 85 → 警告；否则本色
    public static func of(_ used: Double?) -> BarTint {
        guard let u = used else { return .native }
        if u >= 100 { return .bad }
        if u >= Overview.warnLine { return .warn }
        return .native
    }
}

public enum WindowKind: Sendable, Equatable {
    case fiveHour, week

    public var label: String { self == .fiveHour ? "5 小时" : "本周" }
}

/// 头像样式：当前账号彩色；其他账号灰度 45%；不参与自动切换 / 登录失效灰度 25%
public enum AvatarStyle: Sendable, Equatable {
    case color, idle, muted
}

// MARK: - 档位徽章

public enum TierStyle: Sendable, Equatable {
    case free, pro, max5, max20, team, unknown
}

public struct TierBadge: Sendable, Equatable {
    public var style: TierStyle
    /// 徽章文字（到期时是原档位名，可能为空）
    public var name: String
    /// 订阅已到期：灰底 + 橙色「已到期」
    public var expired: Bool

    public init(style: TierStyle, name: String, expired: Bool = false) {
        self.style = style
        self.name = name
        self.expired = expired
    }

    /// 档位识别（docs/03 §5）。cswap 的 label 只看额度等级（rate_limit_tier），而 Pro 的额度等级与 Free 相同
    /// （都是 default_claude_ai），cswap 会把有效的 Pro 标成 Free。组织类型（organizationType）才分得开，以它为准
    public static func of(_ plan: Plan?) -> TierBadge? {
        guard let plan else { return nil }
        let tier = plan.tier?.lowercased() ?? ""
        let org = plan.organizationType?.lowercased() ?? ""
        // cswap 的「已到期」= 订阅状态 canceled 且额度等级是免费档。Pro 的额度等级本来就和免费档相同，
        // App Store 订阅关掉自动续费后状态就是 canceled、但仍在有效期内（用户实测 2026-11-07）：
        // 对 Pro 这条规则分不清「取消续费」与「真的到期」，不标到期，按 Pro 显示
        if plan.expired == true && !org.contains("pro") {
            let name: String
            if org.contains("max") { name = "Max" }
            else if org.contains("team") { name = "Team" }
            else { name = "" }
            return TierBadge(style: .unknown, name: name, expired: true)
        }
        if org.contains("team") || plan.label == "Team" { return TierBadge(style: .team, name: "Team") }
        if tier.contains("max_20x") || plan.label == "Max 20x" { return TierBadge(style: .max20, name: "Max 20×") }
        if tier.contains("max_5x") || plan.label == "Max 5x" { return TierBadge(style: .max5, name: "Max 5×") }
        if org.contains("pro") || tier.contains("pro") { return TierBadge(style: .pro, name: "Pro") }
        if plan.label == "Free" { return TierBadge(style: .free, name: "Free") }
        let raw = plan.label ?? plan.tier ?? ""
        return raw.isEmpty ? nil : TierBadge(style: .unknown, name: raw)
    }
}

// MARK: - 输入

/// 自动切换子进程的状态（App 自己的开关 + 看护结果）
public enum AutoSwitchState: Sendable, Equatable {
    case off
    case starting
    case running
    /// 连续启动失败 / 意外退出：显示原因
    case failed(String)
}

/// 菜单栏显示什么
public enum MenuBarDisplay: String, Sendable, CaseIterable, Identifiable {
    case fiveHour, week, both
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .fiveHour: return "5 小时"
        case .week: return "本周"
        case .both: return "两者"
        }
    }
}

/// 命令行可用性
public enum CLIState: Sendable, Equatable {
    case locating
    case missing
    case ready
    /// schemaVersion 不是 1，或版本过低到解不了
    case incompatible(String)
}

public struct Inputs: Sendable {
    public var cli: CLIState
    public var list: AccountList?
    /// 拿到 list 的时刻（usageAgeSeconds 是那一刻的年龄）
    public var listFetchedAt: Date?
    /// 最近一次读取命令本身失败的原因（命令报错、超时）；成功后清空
    public var fetchError: String?
    public var nextRefreshAt: Date?
    public var refreshing: Bool
    public var config: AutoSwitchConfig?
    public var priorities: [Int: Int]
    public var autoSwitch: AutoSwitchState
    public var display: MenuBarDisplay
    public var now: Date

    public init(cli: CLIState = .ready, list: AccountList?, listFetchedAt: Date? = nil, fetchError: String? = nil,
                nextRefreshAt: Date? = nil, refreshing: Bool = false, config: AutoSwitchConfig? = nil,
                priorities: [Int: Int] = [:], autoSwitch: AutoSwitchState = .off, display: MenuBarDisplay = .both,
                now: Date) {
        self.cli = cli
        self.list = list
        self.listFetchedAt = listFetchedAt ?? now
        self.fetchError = fetchError
        self.nextRefreshAt = nextRefreshAt
        self.refreshing = refreshing
        self.config = config
        self.priorities = priorities
        self.autoSwitch = autoSwitch
        self.display = display
        self.now = now
    }
}

// MARK: - 输出

public struct Verdict: Sendable, Equatable {
    public var level: Level
    public var text: String
}

public struct Header: Sendable, Equatable {
    public var name: String
    public var tier: TierBadge?
    public var verdict: Verdict
}

public struct UsageCard: Sendable, Equatable {
    public var kind: WindowKind
    public var value: String
    public var pct: Double?
    public var tint: BarTint
    /// 均速竖线位置（本周卡）
    public var pace: Double?
    public var foot: String
    /// 按当前速度撑不到刷新时的「预计周二 09:55 用完」（橙字），与 foot 轮流显示
    public var exhaustion: String? = nil
}

public struct MiniBar: Sendable, Equatable {
    public var kind: WindowKind
    public var pct: Double?
    public var tint: BarTint
    /// 「5 小时 0%」
    public var text: String
}

public enum RowMeta: Sendable, Equatable {
    case usage([MiniBar])
    /// 不参与自动切换：文字 + 本周迷你条
    case disabled(MiniBar?)
    /// 登录失效：红字
    case broken(String)
    /// 其他说明（读不到用量、API Key 账号）
    case note(String)
}

public enum RowAction: Sendable, Equatable {
    case switchTo
    /// 登录失效后的「刷新」：核对当前登录邮箱后重新存回这个位置
    case relogin
}

public struct AccountRow: Sendable, Equatable, Identifiable {
    public var number: Int
    public var name: String
    public var email: String
    public var tier: TierBadge?
    public var avatar: AvatarStyle
    public var isCurrent: Bool
    public var isDisabled: Bool
    public var isBroken: Bool
    public var meta: RowMeta
    public var action: RowAction?
    public var id: Int { number }
}

public struct AutoRow: Sendable, Equatable {
    public var on: Bool
    public var subtitle: String
    public var level: Level
}

public struct Footer: Sendable, Equatable {
    public var text: String
    public var level: Level
}

/// 菜单栏上的一个数：百分比文字 + 着色（ok = 系统默认色）
public struct MenuBarItem: Sendable, Equatable {
    public var kind: WindowKind
    public var text: String
    public var level: Level

    public init(kind: WindowKind, text: String, level: Level) {
        self.kind = kind
        self.text = text
        self.level = level
    }
}

/// 菜单栏标签：一个数单行显示；两个数上下两行（上 5 小时、下本周）
public struct MenuBarLabel: Sendable, Equatable {
    public var items: [MenuBarItem]
    /// 鼠标悬停说明：「5 小时 30%，本周 68%」
    public var tooltip: String

    public init(items: [MenuBarItem], tooltip: String) {
        self.items = items
        self.tooltip = tooltip
    }
}

public struct Overview: Sendable, Equatable {
    /// 已用 ≥ 85% 算「快到切换阈值」
    public static let warnLine: Double = 85
    /// 登录到期提前提醒的天数
    public static let loginWarnDays = 7

    public var header: Header?
    public var cards: [UsageCard]
    public var rows: [AccountRow]
    public var autoRow: AutoRow
    public var footer: Footer
    public var menuBar: MenuBarLabel
    /// 整个面板的特殊状态（找不到命令行、不兼容、还没有账号）
    public var blocker: Blocker?

    public enum Blocker: Sendable, Equatable {
        case locating
        case missingCLI
        case incompatible(String)
        case noAccounts
        case loading
        case failed(String)
    }
}

// MARK: - 计算

public enum OverviewBuilder {
    public static func build(_ i: Inputs) -> Overview {
        let list = i.list
        let active = list?.active
        let verdict = Self.verdict(list: list, now: i.now)
        let header = active.map { Header(name: displayName($0), tier: TierBadge.of($0.plan), verdict: verdict) }
        // 当前账号排最前，其余按编号
        let rows = (list?.accounts ?? [])
            .sorted { ($0.number == active?.number ? 0 : 1, $0.number) < ($1.number == active?.number ? 0 : 1, $1.number) }
            .map { row($0, activeNumber: active?.number) }

        var blocker: Overview.Blocker?
        switch i.cli {
        case .locating: blocker = .locating
        case .missing: blocker = .missingCLI
        case .incompatible(let why): blocker = .incompatible(why)
        case .ready:
            if list == nil { blocker = i.fetchError.map { .failed($0) } ?? .loading }
            else if list?.accounts.isEmpty == true { blocker = .noAccounts }
        }

        return Overview(
            header: header,
            cards: active.map { cards(for: $0, now: i.now) } ?? [],
            rows: rows,
            autoRow: autoRow(i),
            footer: footer(i),
            menuBar: menuBar(i),
            blocker: blocker
        )
    }

    // MARK: 名字与用量

    /// App 里起的名字优先，其次 cswap 的别名，否则取邮箱 @ 前面
    public static func displayName(_ a: Account) -> String {
        if let name = a.appName, !name.isEmpty { return name }
        if let alias = a.alias, !alias.isEmpty { return alias }
        return a.email.split(separator: "@").first.map(String.init) ?? a.email
    }

    /// 最紧的一项：5 小时与本周已用量里更大的；都没有 = nil
    public static func tightest(_ u: Usage?) -> Double? {
        [u?.fiveHour?.pct, u?.sevenDay?.pct].compactMap { $0 }.max()
    }

    /// 能拿来判断的用量：登录正常且读到了 usage（lastGoodUsage 只能展示）
    static func liveUsage(_ a: Account) -> Usage? {
        a.usageStatus?.isLoginBroken == true ? nil : a.usage
    }

    // MARK: 头部状态

    public static func verdict(list: AccountList?, now: Date) -> Verdict {
        guard let list, let a = list.active else { return Verdict(level: .off, text: "没有登录的账号") }
        if a.usageStatus?.isLoginBroken == true { return Verdict(level: .bad, text: "登录已失效") }
        guard let t = tightest(liveUsage(a)) else { return Verdict(level: .off, text: "读不到用量") }
        if t >= 100 {
            let others = list.accounts.filter { $0.number != a.number }.compactMap { tightest(liveUsage($0)) }
            if !others.isEmpty && others.allSatisfy({ $0 >= 100 }) { return Verdict(level: .bad, text: "都已用完") }
            return Verdict(level: .bad, text: "已用完")
        }
        if t >= Overview.warnLine { return Verdict(level: .warn, text: "快到切换阈值") }
        if let w = a.usage?.sevenDay, runsOutBeforeReset(w, now: now) != nil { return Verdict(level: .warn, text: "用得偏快") }
        return Verdict(level: .ok, text: "充足")
    }

    // MARK: 用量卡

    public static func cards(for a: Account, now: Date) -> [UsageCard] {
        guard let u = a.usage ?? a.lastGoodUsage else {
            return [WindowKind.fiveHour, .week].map {
                UsageCard(kind: $0, value: "—", pct: nil, tint: .native, pace: nil, foot: "读不到")
            }
        }
        var out: [UsageCard] = []
        // 没有 5 小时窗口（如 Ultra）时整卡隐藏
        if let w = u.fiveHour {
            let foot: String
            if (w.pct ?? 0) == 0 && w.resetsAt == nil { foot = "还没开始用" }
            else { foot = Fmt.refresh(w.resetsAt, now: now) ?? "—" }
            out.append(UsageCard(kind: .fiveHour, value: Fmt.pct(w.pct), pct: w.pct, tint: .of(w.pct), pace: nil, foot: foot))
        }
        if let w = u.sevenDay {
            out.append(UsageCard(kind: .week, value: Fmt.pct(w.pct), pct: w.pct, tint: .of(w.pct), pace: w.expectedPct,
                                 foot: Fmt.refresh(w.resetsAt, now: now) ?? "—",
                                 exhaustion: liveUsage(a).flatMap { _ in runsOutBeforeReset(w, now: now) }.map { Fmt.exhaustion($0, now: now) }))
        }
        return out
    }

    /// 按当前速度本周额度会在刷新前用完：返回预计用完的时间，否则 nil。
    /// 用 cswap 的 willLastToReset（线性外推、不设门槛）；不用 aheadOfPace，它要超过均速 15 个点才算，
    /// 超 11 个点、照样会早一天多用完的情况会被判成「充足」（用户 2026-11-08 决定改）。
    /// 刷新后头 24 小时不判：时间太短外推不可信（cswap 的偏快标记同样避开这一天）。
    public static func runsOutBeforeReset(_ w: UsageWindow, now: Date) -> Date? {
        guard w.willLastToReset == false, let eta = w.projectedExhaustionAt, eta > now else { return nil }
        if let reset = w.resetsAt {
            guard eta < reset else { return nil }
            let elapsed = weekSeconds - reset.timeIntervalSince(now)
            if elapsed < 24 * 3600 { return nil }
        }
        return eta
    }

    static let weekSeconds: Double = 7 * 86400

    // MARK: 账号列表

    public static func row(_ a: Account, activeNumber: Int?) -> AccountRow {
        let isCurrent = a.number == activeNumber
        let broken = a.usageStatus?.isLoginBroken == true
        let disabled = a.disabled == true
        let avatar: AvatarStyle = isCurrent ? .color : (broken || disabled ? .muted : .idle)
        let u = liveUsage(a)

        func mini(_ kind: WindowKind, _ w: UsageWindow?) -> MiniBar? {
            guard let w else { return nil }
            return MiniBar(kind: kind, pct: w.pct, tint: .of(w.pct), text: "\(kind.label) \(Fmt.pct(w.pct))%")
        }

        let meta: RowMeta
        if broken {
            meta = .broken("登录已失效，在终端重新登录后点刷新")
        } else if disabled {
            meta = .disabled(mini(.week, u?.sevenDay))
        } else if a.usageStatus == .apiKey {
            meta = .note("API Key 账号，按用量计费")
        } else if let u {
            let bars = [mini(.fiveHour, u.fiveHour), mini(.week, u.sevenDay)].compactMap { $0 }
            meta = bars.isEmpty ? .note("没有用量数据") : .usage(bars)
        } else {
            meta = .note(a.usageError.map { "用量读取失败（\($0)）" } ?? "读不到用量")
        }

        let action: RowAction? = isCurrent ? nil : (broken ? .relogin : .switchTo)
        return AccountRow(number: a.number, name: displayName(a), email: a.email, tier: TierBadge.of(a.plan),
                          avatar: avatar, isCurrent: isCurrent, isDisabled: disabled, isBroken: broken,
                          meta: meta, action: action)
    }

    // MARK: 自动切换行

    public static func strategyPhrase(_ s: Strategy, threshold: String) -> String {
        switch s {
        case .best: return "用到 \(threshold)% 时换到余量最多的号"
        case .weeklyFirst: return "用到 \(threshold)% 时换到本周最先刷新的号"
        case .consumeFirst: return "始终用最先刷新的号，用到 \(threshold)% 再换"
        case .priorityConsumeFirst: return "按你排的顺序用，用到 \(threshold)% 再换"
        }
    }

    public static func autoRow(_ i: Inputs) -> AutoRow {
        let cfg = i.config ?? AutoSwitchConfig()
        switch i.autoSwitch {
        case .off: return AutoRow(on: false, subtitle: "已关闭", level: .off)
        case .starting: return AutoRow(on: true, subtitle: "正在启动…", level: .off)
        case .failed(let why): return AutoRow(on: true, subtitle: "没在运行：\(why)", level: .bad)
        case .running: break
        }
        if let list = i.list, let a = list.active, let p = preview(list: list, active: a, config: cfg, priorities: i.priorities) {
            return AutoRow(on: true, subtitle: p, level: .warn)
        }
        return AutoRow(on: true, subtitle: strategyPhrase(cfg.strategy, threshold: Fmt.pct(cfg.threshold)), level: .ok)
    }

    /// 账号自己的阈值优先，否则全局
    public static func lines(for a: Account, config: AutoSwitchConfig) -> (fiveHour: Double, week: Double) {
        if let t = a.threshold { return (t, t) }
        return (config.threshold, config.weeklyThreshold ?? config.threshold)
    }

    /// 快到阈值时的预告（B12）：「快到 90% 了，到线就换到 XX」。
    /// App 按 cswap 的规则估算，不是 cswap 的结论；「余量最多的」时准，其他策略可能有偏差
    public static func preview(list: AccountList, active a: Account, config: AutoSwitchConfig, priorities: [Int: Int]) -> String? {
        guard let u = liveUsage(a), let t = tightest(u), t >= Overview.warnLine else { return nil }
        let l = lines(for: a, config: config)
        // 离自己那条线最近的窗口决定「快到多少」
        let windows: [(Double, Double)] = [(u.fiveHour?.pct, l.fiveHour), (u.sevenDay?.pct, l.week)]
            .compactMap { pct, line in pct.map { ($0, line) } }
        guard let binding = windows.max(by: { $0.0 / $0.1 < $1.0 / $1.1 }), binding.0 < binding.1 else { return nil }
        let head = "快到 \(Fmt.pct(binding.1))% 了，"
        guard let target = candidate(list: list, excluding: a.number, config: config, priorities: priorities) else {
            return head + "但没有可换的号"
        }
        return head + "到线就换到 \(displayName(target))"
    }

    /// 按策略估算会换到哪个号
    public static func candidate(list: AccountList, excluding current: Int, config: AutoSwitchConfig,
                                 priorities: [Int: Int]) -> Account? {
        let usable = list.accounts.filter { a in
            guard a.number != current, a.disabled != true else { return false }
            if a.usageStatus == .apiKey { return config.includeApiKeyAccounts }
            guard a.usageStatus == .ok || a.usageStatus == nil, let u = liveUsage(a), let t = tightest(u) else { return false }
            return t < lines(for: a, config: config).fiveHour
        }
        let far = Date.distantFuture
        switch config.strategy {
        case .best:
            return usable.min { (tightest($0.usage) ?? 100) < (tightest($1.usage) ?? 100) }
        case .weeklyFirst, .consumeFirst:
            return usable.min {
                let a = $0.usage?.sevenDay?.resetsAt ?? far, b = $1.usage?.sevenDay?.resetsAt ?? far
                return a != b ? a < b : (tightest($0.usage) ?? 100) < (tightest($1.usage) ?? 100)
            }
        case .priorityConsumeFirst:
            return usable.min {
                let pa = priorities[$0.number] ?? 0, pb = priorities[$1.number] ?? 0
                if pa != pb { return pa > pb }
                return ($0.usage?.sevenDay?.resetsAt ?? far) < ($1.usage?.sevenDay?.resetsAt ?? far)
            }
        }
    }

    // MARK: 底部

    public static func footer(_ i: Inputs) -> Footer {
        if let err = i.fetchError {
            let retry = i.nextRefreshAt.map { "，\(Fmt.after($0.timeIntervalSince(i.now)))重试" } ?? ""
            return Footer(text: i.list == nil ? "读取失败\(retry)" : "读取失败\(retry)（\(err)）", level: .warn)
        }
        if i.refreshing && i.list == nil { return Footer(text: "正在读取…", level: .off) }
        guard let a = i.list?.active else { return Footer(text: i.refreshing ? "正在读取…" : "", level: .off) }
        if a.usage == nil, a.usageError != nil {
            let retry = a.usageRetryAt.map { "，\(Fmt.after(max(0, $0.timeIntervalSince(i.now))))重试" } ?? ""
            return Footer(text: "读取失败\(retry)", level: .warn)
        }
        let age = (a.usageAgeSeconds ?? 0) + max(0, i.now.timeIntervalSince(i.listFetchedAt ?? i.now))
        return Footer(text: Fmt.updatedAgo(age), level: .off)
    }

    // MARK: 菜单栏

    /// 每个数按自己的已用量着色：≥ 85% 橙、100% 红，否则系统默认色。读不到 = 「—」。
    /// 没有 5 小时窗口（如 Ultra）的账号只显示本周
    public static func menuBar(_ i: Inputs) -> MenuBarLabel {
        guard let a = i.list?.active, let u = liveUsage(a) else {
            return MenuBarLabel(items: [MenuBarItem(kind: .week, text: "—", level: .ok)], tooltip: "cswap：读不到用量")
        }
        func item(_ kind: WindowKind, _ w: UsageWindow?) -> MenuBarItem? {
            guard let w else { return nil }
            let level: Level = switch BarTint.of(w.pct) { case .native: .ok; case .warn: .warn; case .bad: .bad }
            return MenuBarItem(kind: kind, text: "\(Fmt.pct(w.pct))%", level: w.pct == nil ? .ok : level)
        }
        let five = item(.fiveHour, u.fiveHour), week = item(.week, u.sevenDay)
        var items: [MenuBarItem]
        switch i.display {
        case .fiveHour: items = [five ?? week].compactMap { $0 }
        case .week: items = [week ?? five].compactMap { $0 }
        case .both: items = [five, week].compactMap { $0 }
        }
        if items.isEmpty { items = [MenuBarItem(kind: .week, text: "—", level: .ok)] }
        let tip = [five, week].compactMap { $0 }.map { "\($0.kind.label) \($0.text)" }.joined(separator: "，")
        return MenuBarLabel(items: items, tooltip: "\(displayName(a))：\(tip.isEmpty ? "读不到用量" : tip)")
    }
}

// MARK: - 账号详情

public struct AccountDetail: Sendable, Equatable {
    public var row: AccountRow
    public var cards: [UsageCard]
    public var loginExpiry: String
    public var tokenStatus: Verdict
    public var participates: Bool
    /// 单账号阈值；nil = 跟随全局
    public var threshold: Double?
    public var thresholdText: String
    public var priority: Int?
    public var alias: String

    public static func build(_ a: Account, activeNumber: Int?, config: AutoSwitchConfig?, priorities: [Int: Int]?,
                             now: Date) -> AccountDetail {
        let cfg = config ?? AutoSwitchConfig()
        let token: Verdict
        switch a.usageStatus {
        case .ok?, nil: token = Verdict(level: .ok, text: "正常")
        case .tokenExpired?: token = Verdict(level: .bad, text: "已失效")
        case .reloginRequired?, .noCredentials?: token = Verdict(level: .bad, text: "需要重新登录")
        case .apiKey?: token = Verdict(level: .off, text: "API Key")
        default: token = Verdict(level: .warn, text: "读不到")
        }
        let thresholdText = a.threshold.map { "\(Fmt.pct($0))%" } ?? "跟随全局 \(Fmt.pct(cfg.threshold))%"
        return AccountDetail(
            row: OverviewBuilder.row(a, activeNumber: activeNumber),
            cards: a.usageStatus?.isLoginBroken == true ? [] : OverviewBuilder.cards(for: a, now: now),
            loginExpiry: a.loginExpiresAt.map { Fmt.monthDay($0) } ?? "—",
            tokenStatus: token,
            participates: a.disabled != true,
            threshold: a.threshold,
            thresholdText: thresholdText,
            priority: priorities?[a.number],
            alias: a.appName ?? a.alias ?? ""
        )
    }
}

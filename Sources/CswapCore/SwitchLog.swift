import Foundation

/// 切换的来源。cswap 日志不区分手动 / 自动：经 App 发起的记「面板」，auto 事件记「自动」，
/// 日志里有、App 没记到的标「命令行」
public enum SwitchSource: String, Codable, Sendable, Equatable {
    case panel, auto, cli

    public var title: String {
        switch self {
        case .panel: return "面板"
        case .auto: return "自动"
        case .cli: return "命令行"
        }
    }
}

/// App 自己记的一条切换（存在 Application Support/cswap/history.json）
public struct HistoryRecord: Codable, Sendable, Equatable {
    public var at: Date
    public var from: Int?
    public var to: Int
    public var toEmail: String?
    public var source: SwitchSource
    /// 自动切换的原因，例如「alicechen92 本周用到了 90%」
    public var reason: String?

    public init(at: Date, from: Int?, to: Int, toEmail: String? = nil, source: SwitchSource, reason: String? = nil) {
        self.at = at
        self.from = from
        self.to = to
        self.toEmail = toEmail
        self.source = source
        self.reason = reason
    }
}

/// cswap 日志里的一次切换
public struct LogSwitch: Sendable, Equatable {
    public var at: Date
    public var from: Int
    public var to: Int
}

/// 合并后用于展示的一行
public struct HistoryItem: Sendable, Equatable {
    public var title: String
    public var source: String
    public var time: String

    public init(title: String, source: String, time: String) {
        self.title = title
        self.source = source
        self.time = time
    }
}

public enum SwitchLog {
    /// 解析日志行 `2026-11-06 09:53:23,726 - INFO - Switched from account 2 to 1`（本地时间）。
    /// 日志不是稳定接口：不认识的行跳过
    public static func parse(_ text: String, timeZone: TimeZone = Fmt.machineTimeZone) -> [LogSwitch] {
        let re = /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})(?:[,.]\d+)?\s.*Switched from account (\d+) to (\d+)/
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let m = try? re.firstMatch(in: String(line)) else { return nil }
            let dc = DateComponents(year: Int(m.1), month: Int(m.2), day: Int(m.3),
                                    hour: Int(m.4), minute: Int(m.5), second: Int(m.6))
            guard let date = cal.date(from: dc), let f = Int(m.7), let t = Int(m.8) else { return nil }
            return LogSwitch(at: date, from: f, to: t)
        }
    }

    /// 某个账号最近一次被 Claude 的用量接口限速（`Usage fetch failed for account N: http-429`）的时刻。
    /// 限速后 cswap 会把读取间隔逐步拉长到最多 30 分钟，用来解释「数据为什么旧了」
    public static func lastRateLimited(_ text: String, account: Int, timeZone: TimeZone = Fmt.machineTimeZone) -> Date? {
        let re = /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})(?:[,.]\d+)?\s.*Usage fetch failed for account (\d+): http-429/
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            guard let m = try? re.firstMatch(in: String(line)), Int(m.7) == account else { continue }
            let dc = DateComponents(year: Int(m.1), month: Int(m.2), day: Int(m.3),
                                    hour: Int(m.4), minute: Int(m.5), second: Int(m.6))
            return cal.date(from: dc)
        }
        return nil
    }

    /// 日志与 App 记录合并：同一次切换（目标相同、时间差 ≤ 15 秒）取 App 的来源；
    /// 只有 App 记录（日志读不到）的也展示。按时间倒序取前 limit 条
    public static func merge(log: [LogSwitch], records: [HistoryRecord], names: [Int: String],
                             now: Date, limit: Int = 10, calendar: Calendar = Fmt.calendar) -> [HistoryItem] {
        var unmatched = records
        var merged: [(Date, Int, String?, SwitchSource)] = []
        for l in log {
            if let k = unmatched.firstIndex(where: { $0.to == l.to && abs($0.at.timeIntervalSince(l.at)) <= 15 }) {
                let r = unmatched.remove(at: k)
                merged.append((l.at, l.to, r.toEmail, r.source))
            } else {
                merged.append((l.at, l.to, nil, .cli))
            }
        }
        merged += unmatched.map { ($0.at, $0.to, $0.toEmail, $0.source) }
        return merged.sorted { $0.0 > $1.0 }.prefix(limit).map { at, to, email, source in
            let name = names[to] ?? email.flatMap { $0.split(separator: "@").first.map(String.init) } ?? "账号 \(to)"
            return HistoryItem(title: "换到 \(name)", source: source.title,
                               time: Fmt.historyTime(at, now: now, calendar: calendar))
        }
    }
}

/// 系统通知文案（docs/02 F 组）
public enum Notices {
    public struct Notice: Sendable, Equatable {
        public var title: String
        public var body: String
    }

    static func count(_ n: Int) -> String { n == 2 ? "两" : String(n) }

    /// 说清楚是哪个窗口触发的：「alicechen92 本周用到了 90%」
    public static func reason(from a: Account?) -> String? {
        guard let a, let u = a.usage else { return nil }
        let name = OverviewBuilder.displayName(a)
        let candidates: [(WindowKind, Double?)] = [(.fiveHour, u.fiveHour?.pct), (.week, u.sevenDay?.pct)]
        guard let (kind, pct) = candidates.compactMap({ k, p in p.map { (k, $0) } }).max(by: { $0.1 < $1.1 }) else { return nil }
        return "\(name) \(kind.label)用到了 \(Fmt.pct(pct))%"
    }

    /// F1 自动换号后
    public static func switched(to: Account?, toEmail: String?, from: Account?) -> Notice {
        let name = to.map(OverviewBuilder.displayName) ?? toEmail?.split(separator: "@").first.map(String.init) ?? "另一个账号"
        return Notice(title: "已换到 \(name)", body: reason(from: from) ?? "上一个账号快用完了")
    }

    /// F2 所有账号都用完
    public static func allExhausted(list: AccountList?, earliestResetAt: Date?, now: Date) -> Notice {
        let n = list?.accounts.count ?? 0
        let title = n >= 2 ? "\(count(n))个账号都用完了" : "账号用完了"
        guard let reset = earliestResetAt else { return Notice(title: title, body: "暂时没有可换的号") }
        var body = "最早 \(Fmt.duration(max(0, reset.timeIntervalSince(now))))后刷新"
        // 找出是哪个账号的哪个窗口最先刷新
        for a in list?.accounts ?? [] {
            for (kind, w) in [(WindowKind.fiveHour, a.usage?.fiveHour), (.week, a.usage?.sevenDay)] {
                if let r = w?.resetsAt, abs(r.timeIntervalSince(reset)) < 120 {
                    let gap = kind == .fiveHour ? " " : ""   // 中文与数字之间加空格
                    body += "（\(OverviewBuilder.displayName(a)) 的\(gap)\(kind.label)额度）"
                    return Notice(title: title, body: body)
                }
            }
        }
        return Notice(title: title, body: body)
    }

    /// F3 登录快过期：≤ 7 天时返回
    public static func loginExpiring(_ a: Account, now: Date) -> Notice? {
        guard let exp = a.loginExpiresAt else { return nil }
        let left = exp.timeIntervalSince(now)
        guard left <= Double(Overview.loginWarnDays) * 86400 else { return nil }
        let name = OverviewBuilder.displayName(a)
        let days = Int((left / 86400).rounded(.up))
        let title = left <= 0 ? "\(name) 的登录已过期" : "\(name) 的登录 \(days) 天后过期"
        return Notice(title: title, body: "到期前用这个号在 Claude Code 里重新登录一次")
    }

    /// F5 App 自动更新后：正文列这一版的要点（更新日志各条的标题），取不到时指向更新日志
    public static func appUpdated(to version: String, changelog: Changelog.Section?) -> Notice {
        let points = changelog.map(Changelog.highlights) ?? []
        return Notice(title: "cswap 已更新到 \(version)",
                      body: points.isEmpty ? "在面板底部点「更新日志」查看新变化" : points.joined(separator: "；"))
    }

    /// F4 账号令牌失效被隔离
    public static func quarantined(name: String) -> Notice {
        Notice(title: "\(name) 的登录失效了", body: "在终端重新登录后，到面板里点刷新")
    }
}

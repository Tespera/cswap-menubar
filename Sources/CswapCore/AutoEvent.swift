import Foundation

/// `cswap auto --json` 的事件流：一行一个 JSON。上游约定事件类型只增不减，未知类型一律忽略。
public enum AutoEvent: Sendable, Equatable {
    public struct Ref: Decodable, Sendable, Equatable {
        public var number: Int?
        public var email: String?

        public init(number: Int?, email: String?) {
            self.number = number
            self.email = email
        }
    }

    case poll
    /// 已换号。trigger：proactive / at-limit / failover / consume-first / priority
    case switched(from: Ref?, to: Ref?, trigger: String, dryRun: Bool, at: Date?)
    case noSwitch(reason: String)
    case quarantined(number: Int?, email: String, reason: String)
    case unquarantined(number: Int?, email: String)
    case allExhausted(earliestResetAt: Date?)
    case error(message: String, transient: Bool)
    case configWarning(String)
    case unknown(String)

    private struct Raw: Decodable {
        var event: String
        var ts: Date?
        var trigger: String?
        var from: Ref?
        var to: Ref?
        var dryRun: Bool?
        var reason: String?
        var number: String?
        var email: String?
        var earliestResetAt: Date?
        var message: String?
        var transient: Bool?
    }

    /// 解一行；不是 JSON 或没有 event 字段返回 nil（stdout 里偶尔夹杂的文字行直接跳过）
    public static func parse(line: String) -> AutoEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let r = try? CswapJSON.decode(Raw.self, from: data) else { return nil }
        switch r.event {
        case "poll": return .poll
        case "switch": return .switched(from: r.from, to: r.to, trigger: r.trigger ?? "", dryRun: r.dryRun ?? false, at: r.ts)
        case "no-switch": return .noSwitch(reason: r.reason ?? "")
        case "account-quarantined":
            return .quarantined(number: r.number.flatMap { Int($0) }, email: r.email ?? "", reason: r.reason ?? "")
        case "account-unquarantined": return .unquarantined(number: r.number.flatMap { Int($0) }, email: r.email ?? "")
        case "all-exhausted": return .allExhausted(earliestResetAt: r.earliestResetAt)
        case "error": return .error(message: r.message ?? "", transient: r.transient ?? true)
        case "config-warning": return .configWarning(r.message ?? "")
        default: return .unknown(r.event)
        }
    }
}

/// `cswap priority` 的文字输出（JSON 里没有优先级）。格式以 0.30.0 为准，解析失败返回 nil，界面隐藏当前值
public enum PriorityParser {
    public static func parse(_ text: String) -> [Int: Int]? {
        let re = /^\s*Account-(\d+)\s+(\S+)\s+(\d+)\s*$/
        var out: [Int: Int] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            if let m = try? re.wholeMatch(in: String(line)), let n = Int(m.1), let p = Int(m.3) { out[n] = p }
        }
        return out.isEmpty ? nil : out
    }
}

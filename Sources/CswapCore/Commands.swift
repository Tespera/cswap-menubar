import Foundation

/// 调用 cswap 的全部命令（参数、读 / 写、超时、标准输入）。依据 docs/05。
/// 只读命令可并发；写命令由执行层串行，写完立即刷新一次 list。
public enum Command: Sendable, Equatable {
    case list
    case status
    case configList
    case priorities
    case version

    case switchTo(Int)
    case add(alias: String?)
    case addSlot(Int)
    case remove(Int)
    case alias(Int, String?)
    case disable(Int)
    case enable(Int)
    case threshold(Int, Double?)
    case priority(Int, Int?)
    case configSet(String, String)
    case configUnset(String)
    case upgrade

    public var arguments: [String] {
        switch self {
        case .list: return ["list", "--json"]
        case .status: return ["status", "--json"]
        case .configList: return ["config", "list", "--json"]
        case .priorities: return ["priority"]
        case .version: return ["--version"]
        case .switchTo(let n): return ["switch", "\(n)", "--json"]
        case .add(let alias):
            if let alias, !alias.isEmpty { return ["add", "--alias", alias] }
            return ["add"]
        case .addSlot(let n): return ["add", "--slot", "\(n)"]
        case .remove(let n): return ["remove", "\(n)"]
        case .alias(let n, let name):
            if let name, !name.isEmpty { return ["alias", "\(n)", name] }
            return ["alias", "\(n)", "--unset"]
        case .disable(let n): return ["disable", "\(n)"]
        case .enable(let n): return ["enable", "\(n)"]
        case .threshold(let n, let pct):
            if let pct { return ["threshold", "\(n)", Self.number(pct)] }
            return ["threshold", "\(n)", "--unset"]
        case .priority(let n, let tier):
            if let tier { return ["priority", "\(n)", "\(tier)"] }
            return ["priority", "\(n)", "--unset"]
        case .configSet(let k, let v): return ["config", "set", k, v]
        case .configUnset(let k): return ["config", "unset", k]
        case .upgrade: return ["upgrade"]
        }
    }

    public var isWrite: Bool {
        switch self {
        case .list, .status, .configList, .priorities, .version: return false
        default: return true
        }
    }

    /// 只读 20 秒，写 30 秒，升级 5 分钟
    public var timeout: Duration {
        switch self {
        case .upgrade: return .seconds(300)
        default: return isWrite ? .seconds(30) : .seconds(20)
        }
    }

    /// 写进标准输入的内容；nil = 接 /dev/null（任何意外的确认提示立刻 EOF 失败，不会挂住）。
    /// remove 没有跳过确认的参数，会问 [y/N]：界面确认过之后替用户答 y
    public var stdin: String? {
        if case .remove = self { return "y\n" }
        return nil
    }

    /// 90.0 → "90"，97.5 → "97.5"
    public static func number(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }
}

/// cswap 的设置键
public enum ConfigKey {
    public static let threshold = "autoswitch.threshold"
    public static let weeklyThreshold = "autoswitch.weeklyThreshold"
    public static let cooldown = "autoswitch.cooldownSeconds"
    public static let strategy = "autoswitch.strategy"
    public static let model = "autoswitch.model"
    public static let includeApiKey = "autoswitch.includeApiKeyAccounts"
}

/// 版本号比较与本设计依据的最低版本
public enum CswapVersion {
    /// 本 App 依据 0.30.0 的输出格式设计
    public static let minimum = "0.30.0"

    /// 从 `cswap 0.30.0` 这样的输出里取版本号
    public static func parse(_ output: String) -> String? {
        let re = /(\d+\.\d+(?:\.\d+)?)/
        return (try? re.firstMatch(in: output)).map { String($0.1) }
    }

    /// a < b
    public static func isOlder(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for k in 0..<max(pa.count, pb.count) {
            let x = k < pa.count ? pa[k] : 0, y = k < pb.count ? pb[k] : 0
            if x != y { return x < y }
        }
        return false
    }
}

/// 一次命令的原始结果
public struct CommandOutput: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool

    public init(status: Int32, stdout: Data, stderr: Data, timedOut: Bool = false) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// 调用 cswap 失败的原因（message 直接给用户看）
public struct CLIError: Error, Sendable, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }

    public static let missing = CLIError("没找到 cswap 命令行")

    /// 判断一次执行是否失败，失败时取出给用户看的原因：
    /// 超时 → 「超时」；`--json` 命令出错时 stdout 是 error 信封；其他取 stderr 最后几行
    public static func check(_ out: CommandOutput) -> CLIError? {
        if out.timedOut { return CLIError("cswap 没有响应（超时）") }
        if let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: out.stdout) {
            return CLIError(env.error.message ?? env.error.type ?? "cswap 报错")
        }
        guard out.status != 0 else { return nil }
        let tail = (out.stderrText.isEmpty ? out.stdoutText : out.stderrText)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Traceback") }
            .suffix(2)
            .joined(separator: " ")
        return CLIError(tail.isEmpty ? "cswap 退出码 \(out.status)" : tail)
    }
}

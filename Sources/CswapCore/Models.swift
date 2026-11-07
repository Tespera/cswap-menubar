import Foundation

// cswap `--json` 输出的解码模型（依据 0.30.0 源码与本机实际输出，字段说明见 docs/05）。
// 上游承诺 schemaVersion 1 内只增不减：除账号编号外一律按可选解码，未知字段忽略。

/// 只解出 schemaVersion，用来在正式解码前判断兼容性
public struct SchemaProbe: Decodable, Sendable {
    public let schemaVersion: Int?
}

/// `--json` 命令出错时的输出：`{"schemaVersion":1,"error":{"type","message"}}`
public struct ErrorEnvelope: Decodable, Sendable {
    public struct Body: Decodable, Sendable {
        public let type: String?
        public let message: String?
    }
    public let error: Body
}

// MARK: - list --json

public struct AccountList: Decodable, Sendable, Equatable {
    public var schemaVersion: Int
    public var activeAccountNumber: Int?
    public var accounts: [Account]

    public init(schemaVersion: Int = 1, activeAccountNumber: Int?, accounts: [Account]) {
        self.schemaVersion = schemaVersion
        self.activeAccountNumber = activeAccountNumber
        self.accounts = accounts
    }

    public var active: Account? {
        accounts.first { $0.number == activeAccountNumber } ?? accounts.first { $0.active == true }
    }
}

public struct Account: Decodable, Sendable, Equatable, Identifiable {
    public var number: Int
    public var email: String
    public var organizationName: String?
    public var active: Bool?
    public var usageStatus: UsageStatus?
    public var usage: Usage?
    public var usageFetchedAt: Date?
    public var usageAgeSeconds: Double?
    public var lastGoodUsage: Usage?
    public var usageError: String?
    public var usageRetryAt: Date?
    public var disabled: Bool?
    public var threshold: Double?
    public var alias: String?
    public var loginExpiresAt: Date?
    public var plan: Plan?
    /// App 自己存的显示名（别名）。cswap 的 alias 只能用小写字母、数字和 _.-，会被强制转小写，
    /// 所以带大小写、中文的名字由 App 保存（按邮箱），读到 list 后合并进来。不从 cswap 的 JSON 解码
    public var appName: String?

    public var id: Int { number }

    private enum CodingKeys: String, CodingKey {
        case number, email, organizationName, active, usageStatus, usage, usageFetchedAt, usageAgeSeconds
        case lastGoodUsage, usageError, usageRetryAt, disabled, threshold, alias, loginExpiresAt, plan
    }

    public init(number: Int, email: String, active: Bool = false, usageStatus: UsageStatus? = .ok, usage: Usage? = nil,
                usageAgeSeconds: Double? = 30, disabled: Bool? = nil, threshold: Double? = nil, alias: String? = nil,
                loginExpiresAt: Date? = nil, plan: Plan? = nil, usageError: String? = nil, usageRetryAt: Date? = nil) {
        self.number = number
        self.email = email
        self.active = active
        self.usageStatus = usageStatus
        self.usage = usage
        self.usageAgeSeconds = usageAgeSeconds
        self.disabled = disabled
        self.threshold = threshold
        self.alias = alias
        self.loginExpiresAt = loginExpiresAt
        self.plan = plan
        self.usageError = usageError
        self.usageRetryAt = usageRetryAt
    }
}

/// `usageStatus` 的取值；不认识的值保留原文，按「读不到」处理
public enum UsageStatus: Sendable, Equatable, Decodable {
    case ok, tokenExpired, reloginRequired, apiKey, keychainUnavailable, foreignCredential, noCredentials, unavailable
    case other(String)

    public init(raw: String) {
        switch raw {
        case "ok": self = .ok
        case "token_expired": self = .tokenExpired
        case "relogin_required": self = .reloginRequired
        case "api_key": self = .apiKey
        case "keychain_unavailable": self = .keychainUnavailable
        case "foreign_credential": self = .foreignCredential
        case "no_credentials": self = .noCredentials
        case "unavailable": self = .unavailable
        default: self = .other(raw)
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(raw: try decoder.singleValueContainer().decode(String.self))
    }

    /// 登录失效：要用户在终端重新登录后点「刷新」
    public var isLoginBroken: Bool {
        switch self {
        case .tokenExpired, .reloginRequired, .noCredentials: return true
        default: return false
        }
    }
}

public struct Usage: Decodable, Sendable, Equatable {
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?
    public var scoped: [UsageWindow]?

    public init(fiveHour: UsageWindow? = nil, sevenDay: UsageWindow? = nil, scoped: [UsageWindow]? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.scoped = scoped
    }
}

/// 一个用量窗口。sevenDay / scoped 约一天后才带配速字段
public struct UsageWindow: Decodable, Sendable, Equatable {
    public var pct: Double?
    public var resetsAt: Date?
    public var expectedPct: Double?
    public var aheadOfPace: Bool?
    public var projectedExhaustionAt: Date?
    public var willLastToReset: Bool?
    /// scoped 窗口的模型名（如 Fable）
    public var name: String?

    public init(pct: Double?, resetsAt: Date? = nil, expectedPct: Double? = nil, aheadOfPace: Bool? = nil,
                projectedExhaustionAt: Date? = nil, willLastToReset: Bool? = nil, name: String? = nil) {
        self.pct = pct
        self.resetsAt = resetsAt
        self.expectedPct = expectedPct
        self.aheadOfPace = aheadOfPace
        self.projectedExhaustionAt = projectedExhaustionAt
        self.willLastToReset = willLastToReset
        self.name = name
    }
}

public struct Plan: Decodable, Sendable, Equatable {
    public var label: String?
    public var tier: String?
    public var organizationType: String?
    public var billingType: String?
    public var subscriptionStatus: String?
    public var expired: Bool?

    public init(label: String?, tier: String?, organizationType: String? = nil, expired: Bool? = nil) {
        self.label = label
        self.tier = tier
        self.organizationType = organizationType
        self.expired = expired
    }
}

// MARK: - status --json

public struct StatusResponse: Decodable, Sendable {
    public struct Active: Decodable, Sendable {
        public var number: Int?
        public var email: String?
        public var managed: Bool?
    }
    public var active: Active?
}

// MARK: - switch --json

public struct SwitchResult: Decodable, Sendable {
    public struct Ref: Decodable, Sendable {
        public var number: Int?
        public var email: String?
    }
    public var switched: Bool?
    public var from: Ref?
    public var to: Ref?
    public var reason: String?
    public var message: String?
    public var warnings: [String]?
}

// MARK: - config list --json

/// `config list --json` 里与 App 有关的自动切换设置
public struct AutoSwitchConfig: Sendable, Equatable {
    public var threshold: Double = 90
    public var weeklyThreshold: Double?
    public var cooldownSeconds: Double = 300
    public var strategy: Strategy = .best
    public var model: String?
    public var includeApiKeyAccounts = false

    public init() {}

    public init(threshold: Double, weeklyThreshold: Double? = nil, cooldownSeconds: Double = 300, strategy: Strategy = .best,
                model: String? = nil, includeApiKeyAccounts: Bool = false) {
        self.threshold = threshold
        self.weeklyThreshold = weeklyThreshold
        self.cooldownSeconds = cooldownSeconds
        self.strategy = strategy
        self.model = model
        self.includeApiKeyAccounts = includeApiKeyAccounts
    }
}

/// 切换优先级（`autoswitch.strategy`）
public enum Strategy: String, Sendable, CaseIterable, Identifiable {
    case best
    case weeklyFirst = "weekly-first"
    case consumeFirst = "consume-first"
    case priorityConsumeFirst = "priority-consume-first"

    public var id: String { rawValue }
}

public struct ConfigList: Decodable, Sendable {
    public struct Setting: Decodable, Sendable {
        public var key: String
        public var value: JSONValue?
        public var isSet: Bool?
    }
    public var settings: [Setting]

    public var autoSwitch: AutoSwitchConfig {
        var c = AutoSwitchConfig()
        let map = Dictionary(settings.map { ($0.key, $0.value ?? .null) }, uniquingKeysWith: { a, _ in a })
        if let v = map["autoswitch.threshold"]?.double { c.threshold = v }
        c.weeklyThreshold = map["autoswitch.weeklyThreshold"]?.double
        if let v = map["autoswitch.cooldownSeconds"]?.double { c.cooldownSeconds = v }
        if let s = map["autoswitch.strategy"]?.string, let v = Strategy(rawValue: s) { c.strategy = v }
        c.model = map["autoswitch.model"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        if let v = map["autoswitch.includeApiKeyAccounts"]?.bool { c.includeApiKeyAccounts = v }
        return c
    }
}

/// 设置值：数字、字符串、布尔或 null
public enum JSONValue: Decodable, Sendable, Equatable {
    case number(Double), string(String), bool(Bool), null, other

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else { self = .other }
    }

    public var double: Double? { if case .number(let d) = self { return d }; return nil }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
}

// MARK: - 解码入口

public enum CswapJSON {
    /// cswap 的时间有三种写法：`...Z`、`+00:00` 带 6 位小数、不带小数，统一解析
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            guard let date = parseDate(s) else {
                throw DecodingError.dataCorruptedError(in: try dec.singleValueContainer(), debugDescription: "时间格式不认识：\(s)")
            }
            return date
        }
        return d
    }

    public static func parseDate(_ s: String) -> Date? {
        // 拆出小数秒（ISO8601DateFormatter 只认 3 位小数），整秒部分交给系统解析
        var base = s
        var fraction = 0.0
        if let dot = s.firstIndex(of: ".") {
            let rest = s[s.index(after: dot)...]
            let digits = rest.prefix { $0.isNumber }
            fraction = Double("0." + digits) ?? 0
            base = String(s[..<dot]) + String(rest.dropFirst(digits.count))
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: base).map { $0.addingTimeInterval(fraction) }
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(type, from: data)
    }
}

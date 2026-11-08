import Foundation

/// 时间与百分比的文案。中英文、数字与单位之间加空格；时间一律说「刷新」。
/// 所有函数都显式接收 now 与 calendar，便于测试。
public enum Fmt {
    /// 本机系统时区（系统设置里选的那个，即 /etc/localtime）。不用 TimeZone.current：它会被 TZ 环境变量带偏
    /// （本机终端设了 TZ=Europe/Oslo，系统时区是 Asia/Shanghai；从终端启动的 App 会继承 TZ）
    public static let machineTimeZone: TimeZone = {
        let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/etc/localtime")) ?? ""
        return timeZone(fromLocaltimeLink: target) ?? .current
    }()

    /// 「/var/db/timezone/zoneinfo/Asia/Shanghai」→ Asia/Shanghai
    public static func timeZone(fromLocaltimeLink target: String) -> TimeZone? {
        guard let r = target.range(of: "zoneinfo/") else { return nil }
        return TimeZone(identifier: String(target[r.upperBound...]))
    }

    /// 时间一律 24 小时制、按本机系统时区
    public static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = machineTimeZone
        c.locale = Locale(identifier: "zh_CN")
        return c
    }

    /// 百分比取整：90.0 → "90"；没有数据 → "—"
    public static func pct(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(Int(v.rounded()))
    }

    /// 「2 时 50 分」「50 分」「不到 1 分」
    public static func duration(_ seconds: TimeInterval) -> String {
        let m = Int((seconds / 60).rounded(.up))
        if seconds < 60 { return "不到 1 分" }
        let h = m / 60, mm = m % 60
        if h == 0 { return "\(mm) 分" }
        if mm == 0 { return "\(h) 时" }
        return "\(h) 时 \(mm) 分"
    }

    static let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    /// 刷新时间：24 小时以内用相对时间（「2 时 50 分后刷新」），超过用星期 + 时刻（「周三 05:00 刷新」）
    public static func refresh(_ at: Date?, now: Date, calendar cal: Calendar = calendar) -> String? {
        guard let at else { return nil }
        let left = at.timeIntervalSince(now)
        if left <= 0 { return "正在刷新" }
        if left < 24 * 3600 { return "\(duration(left))后刷新" }
        return "\(weekdayClock(at, calendar: cal)) 刷新"
    }

    /// 「预计 5 时 20 分后用完」「预计周二 09:55 用完」（与 refresh 同一套写法）
    public static func exhaustion(_ at: Date, now: Date, calendar cal: Calendar = calendar) -> String {
        let left = at.timeIntervalSince(now)
        if left < 24 * 3600 { return "预计 \(duration(max(left, 60)))后用完" }
        return "预计\(weekdayClock(at, calendar: cal)) 用完"
    }

    /// 「周三 05:00」
    public static func weekdayClock(_ d: Date, calendar cal: Calendar = calendar) -> String {
        let c = cal.dateComponents([.weekday, .hour, .minute], from: d)
        return "\(weekdays[(c.weekday ?? 1) - 1]) \(String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0))"
    }

    /// 「09:53」
    public static func clock(_ d: Date, calendar cal: Calendar = calendar) -> String {
        let c = cal.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// 切换记录的时间：「今天 09:53」「昨天 09:53」「11-05 11:08」
    public static func historyTime(_ d: Date, now: Date, calendar cal: Calendar = calendar) -> String {
        let days = dayDistance(from: now, to: d, calendar: cal)
        if days == 0 { return "今天 \(clock(d, calendar: cal))" }
        if days == -1 { return "昨天 \(clock(d, calendar: cal))" }
        let c = cal.dateComponents([.month, .day], from: d)
        return String(format: "%02d-%02d ", c.month ?? 0, c.day ?? 0) + clock(d, calendar: cal)
    }

    /// 「11 月 19 日」
    public static func monthDay(_ d: Date, calendar cal: Calendar = calendar) -> String {
        let c = cal.dateComponents([.month, .day], from: d)
        return "\(c.month ?? 0) 月 \(c.day ?? 0) 日"
    }

    /// 软化的未来时间点：「今天晚上」「明天下午」「周日上午」；7 天以外「11 月 19 日」
    public static func softMoment(_ d: Date, now: Date, calendar cal: Calendar = calendar) -> String {
        let days = dayDistance(from: now, to: d, calendar: cal)
        let hour = cal.component(.hour, from: d)
        let part: String
        switch hour {
        case 0..<5: part = "凌晨"
        case 5..<9: part = "早上"
        case 9..<12: part = "上午"
        case 12..<14: part = "中午"
        case 14..<18: part = "下午"
        default: part = "晚上"
        }
        switch days {
        case ..<0: return "很快"
        case 0: return "今天\(part)"
        case 1: return "明天\(part)"
        case 2: return "后天\(part)"
        case 3..<7: return weekdays[cal.component(.weekday, from: d) - 1] + part
        default: return monthDay(d, calendar: cal)
        }
    }

    /// 「刚刚更新」「N 分钟前更新」「N 小时前更新」
    public static func updatedAgo(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "刚刚更新" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前更新" }
        return "\(Int(seconds / 3600)) 小时前更新"
    }

    /// 「N 分钟后」「N 秒后」「马上」
    public static func after(_ seconds: TimeInterval) -> String {
        if seconds < 5 { return "马上" }
        if seconds < 60 { return "\(Int(seconds)) 秒后" }
        return "\(Int((seconds / 60).rounded(.up))) 分钟后"
    }

    /// 两个时刻相差的自然日（to 在 from 之后为正）
    public static func dayDistance(from: Date, to: Date, calendar cal: Calendar = calendar) -> Int {
        cal.dateComponents([.day], from: cal.startOfDay(for: from), to: cal.startOfDay(for: to)).day ?? 0
    }
}

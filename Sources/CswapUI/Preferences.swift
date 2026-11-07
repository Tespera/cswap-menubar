import CswapCore
import Foundation

/// App 自己的偏好（UserDefaults，域 com.eric.cswap；开发运行与打包后共用同一份）
struct Preferences {
    static let domain = "com.eric.cswap"
    /// 打包后标准域就是 com.eric.cswap（用自己的 bundle id 当 suite 名系统不支持）；开发运行时显式指定同一个域。
    /// UserDefaults 本身线程安全（文档保证），只是没标 Sendable
    nonisolated(unsafe) private static let d: UserDefaults =
        Bundle.main.bundleIdentifier == domain ? .standard : UserDefaults(suiteName: domain) ?? .standard

    enum Key: String {
        case display, refreshSeconds, notifySwitch, notifyExhausted, notifyExpiry, autoSwitch
    }

    static var display: MenuBarDisplay {
        get { MenuBarDisplay(rawValue: d.string(forKey: Key.display.rawValue) ?? "") ?? .both }
        set { d.set(newValue.rawValue, forKey: Key.display.rawValue) }
    }

    /// 刷新频率：30 秒 / 1 分钟（默认）/ 5 分钟
    static var refreshSeconds: Int {
        get { [30, 60, 300].contains(d.integer(forKey: Key.refreshSeconds.rawValue)) ? d.integer(forKey: Key.refreshSeconds.rawValue) : 60 }
        set { d.set(newValue, forKey: Key.refreshSeconds.rawValue) }
    }

    static func flag(_ k: Key, default def: Bool) -> Bool {
        d.object(forKey: k.rawValue) as? Bool ?? def
    }

    static func set(_ k: Key, _ v: Bool) { d.set(v, forKey: k.rawValue) }
}

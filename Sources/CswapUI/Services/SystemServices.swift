import AppKit
import CswapCore
import Foundation
import UserNotifications

// MARK: - 通知

/// 系统通知：打包成 .app 时用 UNUserNotificationCenter；不在 App 包里（swift run）、
/// 或通知权限被拒 / 请求出错时退回 osascript（docs/04 §2，自签名包能否稳定弹 UN 通知待真机确认）
@MainActor
final class Notifier {
    private var authorized: Bool?
    private var useAppleScript: Bool

    init() {
        useAppleScript = Bundle.main.bundleIdentifier == nil || !Bundle.main.bundlePath.hasSuffix(".app")
    }

    private let presenter = ForegroundPresenter()

    func requestAuthorization() {
        guard !useAppleScript else { return }
        UNUserNotificationCenter.current().delegate = presenter
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            Task { @MainActor in
                self.authorized = granted && error == nil
                if !granted || error != nil { self.useAppleScript = true }
            }
        }
    }

    func post(_ n: Notices.Notice, id: String = UUID().uuidString) {
        if useAppleScript || authorized == false { return Self.appleScript(n) }
        let content = UNMutableNotificationContent()
        content.title = n.title
        content.body = n.body
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            if error != nil { Task { @MainActor in Self.appleScript(n) } }
        }
    }

    static func appleScript(_ n: Notices.Notice) {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(esc(n.body))\" with title \"\(esc(n.title))\""]
        try? p.run()
    }
}

/// App 在前台时（例如刚弹过对话框）系统默认不显示横幅：照样显示
final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

// MARK: - 登录时打开

/// 用户级 LaunchAgent（同 NetHub：无付费证书时 SMAppService 不可靠）
enum LaunchAgent {
    static let label = "com.eric.cswap"

    static var plistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistPath) }

    /// 只写 / 删配置，不当场加载：下次登录时由系统启动。当场 bootstrap 会立刻再拉起一个实例，bootout 会结束自己
    static func set(_ on: Bool) {
        if on {
            try? FileManager.default.createDirectory(atPath: (plistPath as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            let exec = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
            let dict: [String: Any] = ["Label": label, "ProgramArguments": [exec], "RunAtLoad": true,
                                       "KeepAlive": ["SuccessfulExit": false], "ProcessType": "Interactive"]
            guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) else { return }
            try? data.write(to: URL(filePath: plistPath), options: .atomic)
        } else {
            try? FileManager.default.removeItem(atPath: plistPath)
        }
    }
}

// MARK: - 版本检测

/// 最新版本号：先读 cswap 自己的更新缓存（不是稳定接口，解析失败就当没有），过期（> 24 小时）再查 PyPI
enum UpdateCheck {
    static var cachePath: String { NSHomeDirectory() + "/.claude-swap-backup/cache/update_check.json" }

    struct Cache: Decodable {
        var timestamp: Double?
        var data: String?
    }

    static func latest() async -> String? {
        if let d = FileManager.default.contents(atPath: cachePath),
           let c = try? JSONDecoder().decode(Cache.self, from: d), let v = c.data,
           let ts = c.timestamp, Date().timeIntervalSince1970 - ts < 86400 {
            return v
        }
        return await pypi()
    }

    static func pypi() async -> String? {
        struct Info: Decodable { struct I: Decodable { var version: String }; var info: I }
        var req = URLRequest(url: URL(string: "https://pypi.org/pypi/claude-swap/json")!)
        req.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return try? JSONDecoder().decode(Info.self, from: data).info.version
    }
}

// MARK: - 打开终端

/// 用某个号开一个终端：生成临时 .command 文件交给「终端」打开（不需要申请自动化权限）
enum TerminalLauncher {
    static func open(account: Int, env: CswapEnvironment) throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cswap-terminal")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "account-\(account).command")
        let cswap = env.executable.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        #!/bin/zsh -l
        # 由 cswap 菜单栏生成：用 \(account) 号账号运行 Claude Code（只影响这个终端窗口）
        unset CLAUDE_CONFIG_DIR
        rm -f "$0"
        exec '\(cswap)' run \(account)

        """
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        let terminal = URL(filePath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - App 数据

/// App 自己的数据目录 ~/Library/Application Support/cswap/
enum AppData {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appending(path: "cswap")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func load<T: Decodable>(_ name: String, as: T.Type) -> T? {
        guard let d = try? Data(contentsOf: dir.appending(path: name)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(T.self, from: d)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(value) else { return }
        try? d.write(to: dir.appending(path: name), options: .atomic)
    }
}

/// 切换记录（App 发起的和 auto 事件），保留最近 200 条
enum HistoryStore {
    static let file = "history.json"
    static let keep = 200

    static func load() -> [HistoryRecord] { AppData.load(file, as: [HistoryRecord].self) ?? [] }

    static func append(_ r: HistoryRecord) {
        AppData.save(Array((load() + [r]).suffix(keep)), file)
    }

    /// cswap 日志（只读，不是稳定接口：读不到就只用 App 自己的记录）
    static func readLog() -> [LogSwitch] {
        let path = NSHomeDirectory() + "/.claude-swap-backup/claude-swap.log"
        guard let h = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? h.close() }
        // 只读末尾 512KB：日志会一直长
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 512_000 ? size - 512_000 : 0)
        let data = (try? h.readToEnd()) ?? Data()
        return SwitchLog.parse(String(decoding: data, as: UTF8.self))
    }
}

/// App 自己存的显示名（按邮箱小写）：cswap 的别名只能用小写字母、数字和 _.-
enum AppNames {
    static let file = "names.json"

    static func load() -> [String: String] { AppData.load(file, as: [String: String].self) ?? [:] }

    /// 空字符串 = 删除
    static func set(_ name: String, for email: String) {
        var all = load()
        all[email.lowercased()] = name.isEmpty ? nil : name
        AppData.save(all, file)
    }
}

/// 登录过期提醒：每个账号每天最多一次
enum ExpiryReminder {
    static let file = "notify-state.json"

    /// 今天还没提醒过这个邮箱 → 记下并返回 true
    static func shouldRemind(email: String, now: Date) -> Bool {
        var state = AppData.load(file, as: [String: String].self) ?? [:]
        let day = ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withFullDate])
        guard state[email] != day else { return false }
        state[email] = day
        AppData.save(state, file)
        return true
    }
}

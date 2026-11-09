import Foundation

/// App 自己的更新（docs/04 §9）：GitHub Release → 下载 → 核对签名 → 替换 → 重启。
/// 这里只放纯逻辑（解析 Release、挑安装包、状态到界面的映射、更新日志截取），网络与安装在 CswapUI/Services/AppUpdater.swift
public enum AppUpdate {
    public static let repo = "Tespera/cswap-menubar"
    public static var latestReleaseAPI: URL { URL(string: "https://api.github.com/repos/\(repo)/releases/latest")! }
    public static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases")! }
    /// 安装包文件名；tools/package.sh release 与 CI 都按这个名字产出
    public static func assetName(_ version: String) -> String { "cswap-\(version).zip" }
    /// 自动检查间隔
    public static let checkInterval: TimeInterval = 6 * 3600
    /// 检查连续失败超过这么久才在设置页露出来（网络偶尔不通不打扰）
    public static let quietFailureWindow: TimeInterval = 86400

    /// 下载地址：先直连 GitHub，失败再走加速代理（安装前一律核对签名，代理改不了包）
    public static func downloadURLs(_ direct: URL) -> [URL] {
        var urls = [direct]
        if let p = URL(string: "https://gh-proxy.com/" + direct.absoluteString) { urls.append(p) }
        return urls
    }

    /// 从 Release 里挑出比当前版本新的安装包；没有新版、或缺安装包 → nil
    public static func candidate(_ r: GitHubRelease, current: String) -> Candidate? {
        guard !r.draft, !r.prerelease else { return nil }
        let v = r.tagName.hasPrefix("v") ? String(r.tagName.dropFirst()) : r.tagName
        guard v.split(separator: ".").count == 3, v.split(separator: ".").allSatisfy({ Int($0) != nil }),
              CswapVersion.isOlder(current, than: v),
              let asset = r.assets.first(where: { $0.name == assetName(v) }) else { return nil }
        let sha = asset.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)).lowercased() : nil }
        return Candidate(version: v, url: asset.browserDownloadURL, size: asset.size, sha256: sha, page: r.htmlURL)
    }

    public struct Candidate: Sendable, Equatable {
        public var version: String
        public var url: URL
        public var size: Int?
        /// GitHub 给的 sha256（新 Release 都有；没有就只靠签名核对）
        public var sha256: String?
        public var page: URL?

        public init(version: String, url: URL, size: Int? = nil, sha256: String? = nil, page: URL? = nil) {
            self.version = version
            self.url = url
            self.size = size
            self.sha256 = sha256
            self.page = page
        }
    }
}

/// GitHub `releases/latest` 里用得到的部分
public struct GitHubRelease: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public var name: String
        public var browserDownloadURL: URL
        public var size: Int?
        public var digest: String?

        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case browserDownloadURL = "browser_download_url"
        }
    }
    public var tagName: String
    public var draft: Bool
    public var prerelease: Bool
    public var htmlURL: URL?
    public var assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case draft, prerelease, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try c.decode(String.self, forKey: .tagName)
        draft = try c.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        prerelease = try c.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
        htmlURL = try c.decodeIfPresent(URL.self, forKey: .htmlURL)
        assets = try c.decodeIfPresent([Asset].self, forKey: .assets) ?? []
    }
}

/// 更新流程的状态
public enum AppUpdateState: Sendable, Equatable {
    /// 还没查过 / 已是最新 / 检查失败但还不到露出来的时候
    case idle
    case checking
    /// 有新版、还没开始下（关了自动更新时停在这里，等用户点「更新」）
    case available(AppUpdate.Candidate)
    case downloading(AppUpdate.Candidate)
    /// 已下载并核对通过，等合适的时机安装（面板关着、没有正在执行的命令）
    case ready(AppUpdate.Candidate)
    case installing(String)
    case failed(String)
}

/// 设置页「cswap App」一栏
public struct AppUpdateRow: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case none, check, checking, update, installNow, retry, openPage
    }
    public var subtitle: String
    public var level: Level
    public var action: Action
    public var spinning: Bool

    /// - canInstall：当前 App 能自己替换（打包后的 App 且有固定证书签名）；开发运行 / 临时签名只提示、点了打开发布页
    /// - checkFailedSince：检查连续失败的起点（成功一次就清空）；不到一天不露出来
    public static func build(state: AppUpdateState, current: String, isDevBuild: Bool, canInstall: Bool,
                             autoUpdate: Bool, upToDate: Bool = false, checkFailedSince: Date?, now: Date) -> AppUpdateRow {
        if isDevBuild { return AppUpdateRow(subtitle: "\(current)（开发版，不自动更新）", level: .off, action: .none, spinning: false) }
        switch state {
        case .checking:
            return AppUpdateRow(subtitle: current, level: .off, action: .checking, spinning: false)
        case .available(let c):
            return AppUpdateRow(subtitle: "有新版本 \(c.version)", level: .ok,
                                action: canInstall ? .update : .openPage, spinning: false)
        case .downloading(let c):
            return AppUpdateRow(subtitle: "正在下载 \(c.version)", level: .off, action: .none, spinning: true)
        case .ready(let c):
            return AppUpdateRow(subtitle: autoUpdate ? "\(c.version) 已准备好，稍后自动更新" : "\(c.version) 已准备好",
                                level: .ok, action: .installNow, spinning: false)
        case .installing(let v):
            return AppUpdateRow(subtitle: "正在更新到 \(v)…", level: .off, action: .none, spinning: true)
        case .failed(let why):
            return AppUpdateRow(subtitle: "更新失败：\(why)", level: .warn, action: .retry, spinning: false)
        case .idle:
            if let since = checkFailedSince, now.timeIntervalSince(since) >= AppUpdate.quietFailureWindow {
                return AppUpdateRow(subtitle: "\(current)，检查更新失败", level: .warn, action: .retry, spinning: false)
            }
            return AppUpdateRow(subtitle: upToDate ? "\(current)，已是最新" : current, level: .off, action: .check, spinning: false)
        }
    }

    /// 设置入口（齿轮）上的小红点：有要用户动手的事才亮——关了自动更新时的新版本、更新失败
    public static func badge(state: AppUpdateState, isDevBuild: Bool, autoUpdate: Bool) -> Bool {
        guard !isDevBuild else { return false }
        switch state {
        case .available: return !autoUpdate
        case .ready: return !autoUpdate
        case .failed: return true
        default: return false
        }
    }
}

/// 更新日志：从 CHANGELOG.md 里截出 (from, to] 之间各版本的那几节（新的在前，同文件顺序）
public enum Changelog {
    public struct Section: Sendable, Equatable, Identifiable {
        public var version: String
        /// 「0.3.0 — 2026-11-09」里破折号后的部分
        public var date: String
        /// 正文（Markdown 列表等，原样）
        public var body: String
        public var id: String { version }
    }

    public static func sections(_ text: String) -> [Section] {
        var out: [Section] = []
        var cur: Section?
        var lines: [Substring] = []
        func flush() {
            guard var s = cur else { return }
            s.body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(s)
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                flush()
                let head = line.dropFirst(3)
                let parts = head.components(separatedBy: " — ")
                let v = parts[0].trimmingCharacters(in: .whitespaces)
                cur = Section(version: v, date: parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "", body: "")
                lines = []
            } else if cur != nil {
                lines.append(line)
            }
        }
        flush()
        return out
    }

    /// 某一版那一节（App 里的更新日志页只显示当前版本，其余到 GitHub 发布页看）
    public static func section(_ text: String, version: String) -> Section? {
        sections(text).first { $0.version == version }
    }

    /// from 为 nil 时只取 to 这一版
    public static func between(_ text: String, from: String?, to: String) -> [Section] {
        sections(text).filter { s in
            guard !CswapVersion.isOlder(to, than: s.version) else { return false }
            if let f = from { return CswapVersion.isOlder(f, than: s.version) }
            return s.version == to
        }
    }
}

import Foundation
import Testing
@testable import CswapCore

@Suite("App 更新")
struct AppUpdateTests {
    /// GitHub releases/latest 的形状（字段名照官方文档，只留用得到的）
    func release(tag: String, assets: [String], draft: Bool = false, digest: String? = "sha256:ABCDEF") throws -> GitHubRelease {
        let list = assets.map { n in
            """
            {"name": "\(n)", "size": 1234, \(digest.map { "\"digest\": \"\($0)\"," } ?? "")
             "browser_download_url": "https://github.com/\(AppUpdate.repo)/releases/download/\(tag)/\(n)"}
            """
        }.joined(separator: ",")
        let json = """
        {"tag_name": "\(tag)", "draft": \(draft), "prerelease": false,
         "html_url": "https://github.com/\(AppUpdate.repo)/releases/tag/\(tag)", "assets": [\(list)]}
        """
        return try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
    }

    @Test func picksNewerAsset() throws {
        let c = AppUpdate.candidate(try release(tag: "v0.3.0", assets: ["cswap-0.3.0.zip", "other.txt"]), current: "0.2.0")
        #expect(c?.version == "0.3.0")
        #expect(c?.url.lastPathComponent == "cswap-0.3.0.zip")
        #expect(c?.sha256 == "abcdef")
        #expect(c?.size == 1234)
    }

    @Test func ignoresSameOrOlderDraftOrMissingAsset() throws {
        #expect(AppUpdate.candidate(try release(tag: "v0.2.0", assets: ["cswap-0.2.0.zip"]), current: "0.2.0") == nil)
        #expect(AppUpdate.candidate(try release(tag: "v0.1.9", assets: ["cswap-0.1.9.zip"]), current: "0.2.0") == nil)
        #expect(AppUpdate.candidate(try release(tag: "v0.3.0", assets: ["cswap-0.3.0.zip"], draft: true), current: "0.2.0") == nil)
        #expect(AppUpdate.candidate(try release(tag: "v0.3.0", assets: ["cswap.zip"]), current: "0.2.0") == nil)
        #expect(AppUpdate.candidate(try release(tag: "nightly", assets: ["cswap-nightly.zip"]), current: "0.2.0") == nil)
        // 0.10.0 比 0.9.0 新（按数字比，不按字符串）
        #expect(AppUpdate.candidate(try release(tag: "v0.10.0", assets: ["cswap-0.10.0.zip"]), current: "0.9.0")?.version == "0.10.0")
    }

    @Test func noDigestMeansSignatureOnly() throws {
        let c = AppUpdate.candidate(try release(tag: "v0.3.0", assets: ["cswap-0.3.0.zip"], digest: nil), current: "0.2.0")
        #expect(c != nil && c?.sha256 == nil)
    }

    @Test func downloadFallsBackToProxy() {
        let u = URL(string: "https://github.com/a/b/releases/download/v1/x.zip")!
        #expect(AppUpdate.downloadURLs(u).map(\.absoluteString) ==
                [u.absoluteString, "https://gh-proxy.com/https://github.com/a/b/releases/download/v1/x.zip"])
    }

    let c = AppUpdate.Candidate(version: "0.3.0", url: URL(string: "https://example.com/x.zip")!)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func row(_ s: AppUpdateState, auto: Bool = true, dev: Bool = false, canInstall: Bool = true,
             upToDate: Bool = false, failedSince: Date? = nil) -> AppUpdateRow {
        AppUpdateRow.build(state: s, current: "0.2.0", isDevBuild: dev, canInstall: canInstall, autoUpdate: auto,
                           upToDate: upToDate, checkFailedSince: failedSince, now: now)
    }

    @Test func rowStates() {
        #expect(row(.idle).subtitle == "0.2.0" && row(.idle).action == .check)
        #expect(row(.idle, upToDate: true).subtitle == "0.2.0，已是最新")
        #expect(row(.checking).action == .checking)
        #expect(row(.available(c), auto: false) == AppUpdateRow(subtitle: "有新版本 0.3.0", level: .ok, action: .update, spinning: false))
        #expect(row(.available(c), canInstall: false).action == .openPage)
        #expect(row(.downloading(c)).spinning)
        #expect(row(.ready(c)).subtitle == "0.3.0 已准备好，稍后自动更新")
        #expect(row(.ready(c), auto: false).subtitle == "0.3.0 已准备好")
        #expect(row(.installing("0.3.0")).subtitle == "正在更新到 0.3.0…")
        #expect(row(.failed("安装包签名不对")).subtitle == "更新失败：安装包签名不对")
        #expect(row(.failed("x")).level == .warn && row(.failed("x")).action == .retry)
        #expect(row(.available(c), dev: true).subtitle == "0.2.0（开发版，不自动更新）")
    }

    /// 自动检查失败：一天内安静，超过一天才在那一栏露出来
    @Test func quietCheckFailures() {
        #expect(row(.idle, failedSince: now.addingTimeInterval(-3600)).level == .off)
        let r = row(.idle, failedSince: now.addingTimeInterval(-86400))
        #expect(r.subtitle == "0.2.0，检查更新失败" && r.level == .warn && r.action == .retry)
    }

    /// 小红点只在要用户动手时亮
    @Test func badge() {
        #expect(!AppUpdateRow.badge(state: .available(c), isDevBuild: false, autoUpdate: true))
        #expect(AppUpdateRow.badge(state: .available(c), isDevBuild: false, autoUpdate: false))
        #expect(!AppUpdateRow.badge(state: .downloading(c), isDevBuild: false, autoUpdate: false))
        #expect(AppUpdateRow.badge(state: .failed("x"), isDevBuild: false, autoUpdate: true))
        #expect(!AppUpdateRow.badge(state: .idle, isDevBuild: false, autoUpdate: false))
        #expect(!AppUpdateRow.badge(state: .available(c), isDevBuild: true, autoUpdate: false))
    }

    @Test func changelogSections() throws {
        let text = """
        # 更新记录

        说明文字

        ## 0.3.0 — 2026-11-09

        - **自动更新**：后台下载
        - 第二条

        ## 0.2.0 — 2026-11-08

        - 旧的

        ## 0.1.0 — 2026-11-07

        第一个版本
        """
        let all = Changelog.sections(text)
        #expect(all.map(\.version) == ["0.3.0", "0.2.0", "0.1.0"])
        #expect(all[0].date == "2026-11-09")
        #expect(all[0].body == "- **自动更新**：后台下载\n- 第二条")
        #expect(Changelog.between(text, from: "0.1.0", to: "0.3.0").map(\.version) == ["0.3.0", "0.2.0"])
        #expect(Changelog.between(text, from: nil, to: "0.2.0").map(\.version) == ["0.2.0"])
    }

    /// 仓库里真实的 CHANGELOG.md 能解析出当前版本那一节（App 里的更新日志页就是它）
    @Test func realChangelogHasCurrent() throws {
        let repo = Fixture.dir.deletingLastPathComponent()
        let text = try String(contentsOf: repo.appending(path: "CHANGELOG.md"), encoding: .utf8)
        let s = Changelog.sections(text)
        #expect(s.first?.version == AppVersion.current)
        #expect(!(s.first?.body.isEmpty ?? true))
    }
}

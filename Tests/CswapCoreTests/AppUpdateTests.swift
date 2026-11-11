import Foundation
import Testing
@testable import CswapCore

@Suite("App 更新")
struct AppUpdateTests {
    func manifest(_ json: String) throws -> AppUpdate.Manifest {
        try JSONDecoder().decode(AppUpdate.Manifest.self, from: Data(json.utf8))
    }

    @Test func picksNewerFromManifest() throws {
        let c = AppUpdate.candidate(try manifest(#"{"version": "0.3.3", "sha256": "ABCDEF"}"#), current: "0.3.2")
        #expect(c?.version == "0.3.3")
        #expect(c?.url.absoluteString == "https://github.com/\(AppUpdate.repo)/releases/download/v0.3.3/cswap-0.3.3.zip")
        #expect(c?.sha256 == "abcdef")
        #expect(c?.page?.absoluteString == "https://github.com/\(AppUpdate.repo)/releases/tag/v0.3.3")
        #expect(AppUpdate.manifestURL.absoluteString == "https://github.com/\(AppUpdate.repo)/releases/latest/download/latest.json")
    }

    @Test func ignoresSameOrOlderOrMalformed() throws {
        #expect(AppUpdate.candidate(try manifest(#"{"version": "0.3.2"}"#), current: "0.3.2") == nil)
        #expect(AppUpdate.candidate(try manifest(#"{"version": "0.3.1"}"#), current: "0.3.2") == nil)
        #expect(AppUpdate.candidate(try manifest(#"{"version": "nightly"}"#), current: "0.3.2") == nil)
        #expect(AppUpdate.candidate(try manifest(#"{"version": "1.0"}"#), current: "0.3.2") == nil)
        // 0.10.0 比 0.9.0 新（按数字比，不按字符串）
        #expect(AppUpdate.candidate(try manifest(#"{"version": "0.10.0"}"#), current: "0.9.0")?.version == "0.10.0")
    }

    @Test func noShaMeansSignatureOnly() throws {
        let c = AppUpdate.candidate(try manifest(#"{"version": "0.4.0"}"#), current: "0.3.2")
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
             upToDate: Bool = false, justChecked: Bool = false, failedSince: Date? = nil) -> AppUpdateRow {
        AppUpdateRow.build(state: s, current: "0.2.0", isDevBuild: dev, canInstall: canInstall, autoUpdate: auto,
                           upToDate: upToDate, justChecked: justChecked, checkFailedSince: failedSince, now: now)
    }

    @Test func rowStates() {
        #expect(row(.idle).subtitle == "0.2.0" && row(.idle).action == .check)
        #expect(row(.idle, upToDate: true).subtitle == "0.2.0，已是最新")
        #expect(row(.checking).action == .checking && row(.checking).subtitle == "0.2.0，正在检查更新…")
        #expect(row(.idle, upToDate: true, justChecked: true).subtitle == "0.2.0，已是最新 · 刚刚检查")
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
        #expect(Changelog.section(text, version: "0.2.0")?.body == "- 旧的")
        #expect(Changelog.section(text, version: "9.9.9") == nil)
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

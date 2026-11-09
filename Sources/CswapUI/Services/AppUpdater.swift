import AppKit
import CryptoKit
import CswapCore
import Foundation
import Security

/// App 自己的更新：查 GitHub Release、下载、核对、替换、重启（docs/04 §9）。
/// 安全：新包必须满足当前 App 的指定要求（同一 bundle id + 同一张证书），否则丢弃——
/// 所以下载可以走加速代理；临时签名（没有证书）的 App 不自己替换，只提示到发布页下载。
enum AppUpdater {
    struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ d: String) { description = d }
    }

    /// 正在运行的是打包后的 .app（swift run、截图工具不是）
    static var bundleURL: URL? {
        let u = Bundle.main.bundleURL
        return u.pathExtension == "app" && Bundle.main.bundleIdentifier == Preferences.domain ? u : nil
    }

    /// 当前 App 的指定要求里带证书（「certificate leaf = H"…"」）才能放心替换；临时签名的只有 cdhash
    static var selfRequirement: SecRequirement? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var req: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &req) == errSecSuccess, let req else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(req, [], &text) == errSecSuccess, let s = text as String?, s.contains("certificate") else { return nil }
        return req
    }

    static var canInstall: Bool { bundleURL != nil && selfRequirement != nil }

    // MARK: 检查

    static func latest() async throws -> GitHubRelease {
        var req = URLRequest(url: AppUpdate.latestReleaseAPI)
        req.timeoutInterval = 15
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("cswap-menubar/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw Failure("没有响应") }
        if http.statusCode == 404 { throw Failure("还没有发布版本") }
        guard http.statusCode == 200 else { throw Failure("GitHub 返回 \(http.statusCode)") }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    // MARK: 下载与核对

    static var stagingRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "com.eric.cswap/update")
    }

    /// 下载、校验 sha256、解压、核对签名与版本，返回解压出的 cswap.app
    static func prepare(_ c: AppUpdate.Candidate) async throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: stagingRoot)
        let dir = stagingRoot.appending(path: c.version)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var lastError: Error = Failure("下载失败")
        var zip: URL?
        for url in AppUpdate.downloadURLs(c.url) {
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 60
                let (tmp, resp) = try await URLSession.shared.download(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("下载返回 \((resp as? HTTPURLResponse)?.statusCode ?? 0)") }
                let dest = dir.appending(path: AppUpdate.assetName(c.version))
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: tmp, to: dest)
                if let want = c.sha256 {
                    let got = try sha256(dest)
                    guard got == want else { throw Failure("安装包校验不一致") }
                }
                zip = dest
                break
            } catch {
                lastError = error
            }
        }
        guard let zip else { throw lastError }

        let out = dir.appending(path: "unzipped")
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])
        let app = out.appending(path: "cswap.app")
        guard fm.fileExists(atPath: app.path) else { throw Failure("安装包里没有 cswap.app") }

        guard let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Preferences.domain,
              info["CFBundleShortVersionString"] as? String == c.version else { throw Failure("安装包版本不对") }
        try verifySignature(app)
        // 下载的文件不带隔离标记（URLSession 不加），保险起见清一次，免得首次打开被拦
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    /// 新包签名完整、且满足当前 App 的指定要求（同 bundle id、同一张证书）
    static func verifySignature(_ app: URL) throws {
        guard let req = selfRequirement else { throw Failure("当前 App 没有固定签名，不能自动替换") }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { throw Failure("读不到安装包签名") }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let st = SecStaticCodeCheckValidity(code, flags, req)
        guard st == errSecSuccess else { throw Failure("安装包签名不对（\(st)），已丢弃") }
    }

    static func sha256(_ file: URL) throws -> String {
        let h = SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe))
        return h.map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    static func run(_ exe: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(filePath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure("\((exe as NSString).lastPathComponent) 失败（\(p.terminationStatus)）") }
        return p.terminationStatus
    }

    // MARK: 安装

    /// 用新包替换当前 App（旧的移到废纸篓之外的暂存处，失败可还原），然后重启。成功不返回
    @MainActor
    static func install(_ newApp: URL, version: String, beforeQuit: () -> Void) throws {
        guard let current = bundleURL else { throw Failure("不是打包后的 App") }
        let fm = FileManager.default
        let backup = stagingRoot.appending(path: "previous.app")
        try? fm.removeItem(at: backup)
        // 替换：先挪走旧的再放新的（同一磁盘内是重命名，几乎瞬间）；第二步失败就把旧的放回去
        do {
            try fm.moveItem(at: current, to: backup)
        } catch {
            throw Failure("没有权限替换 \(current.path)")
        }
        do {
            try fm.moveItem(at: newApp, to: current)
        } catch {
            try? fm.moveItem(at: backup, to: current)
            throw Failure("替换失败：\(error.localizedDescription)")
        }
        try? fm.removeItem(at: backup)
        Preferences.pendingUpdateFrom = AppVersion.current
        relaunch(current, beforeQuit: beforeQuit)
    }

    /// 退出后再打开：由 LaunchAgent（登录时打开）拉起的，非零退出让 launchd 按 KeepAlive 重新拉起；
    /// 否则起一个独立会话的小脚本，等本进程结束后 open（单实例锁随进程释放）
    @MainActor
    static func relaunch(_ app: URL, beforeQuit: () -> Void) {
        beforeQuit()
        let underLaunchd = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == LaunchAgent.label
        if !underLaunchd {
            let script = "while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\""
            spawnDetached("/bin/sh", ["-c", script, app.path])
        }
        exit(underLaunchd ? 75 : 0)
    }

    /// posix_spawn + 新会话：不随本进程（或它所在的 launchd 任务）一起被结束
    static func spawnDetached(_ exe: String, _ args: [String]) {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        let argv: [UnsafeMutablePointer<CChar>?] = ([exe] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        posix_spawn(&pid, exe, nil, &attr, argv, environ)
        posix_spawnattr_destroy(&attr)
    }
}

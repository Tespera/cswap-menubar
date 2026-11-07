import CswapCore
import Foundation
import os

/// 找到的 cswap 与调用它要用的环境
public struct CswapEnvironment: Sendable {
    public var executable: URL
    public var environment: [String: String]
}

/// 定位 cswap（docs/04 §4）：先 `~/.local/bin/cswap`，再登录 shell 的 PATH。
/// 同时从登录 shell 取 PATH 与代理变量：从「登录时打开」或访达启动时，App 继承不到终端里的环境，
/// 而 cswap 联网取用量要走代理
public enum CswapLocator {
    static let marker = "__CSWAP_ENV__"

    public static func locate() async -> CswapEnvironment? {
        let shell = await loginShellEnvironment()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/cswap", shell.cswapPath].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        return CswapEnvironment(executable: URL(filePath: path), environment: cleanEnvironment(shell: shell.env))
    }

    /// 子进程环境：去掉 CLAUDE_CONFIG_DIR（在 `cswap run` 会话里 cswap 会拒绝很多命令）；
    /// PATH 补齐 ~/.local/bin 与 Homebrew；带上登录 shell 里的代理变量
    static func cleanEnvironment(shell: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for (k, v) in shell where k.lowercased().hasSuffix("_proxy") { env[k] = v }
        env.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        // 去掉 TZ：让 cswap 的日志按本机系统时区记时间，与 App 的显示和其他来源一致
        env.removeValue(forKey: "TZ")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var path = (shell["PATH"] ?? env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for extra in ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] where !path.contains(extra) {
            path.insert(extra, at: 0)
        }
        env["PATH"] = path.joined(separator: ":")
        env["PYTHONIOENCODING"] = "utf-8"
        return env
    }

    /// 登录 + 交互 shell 里的 `command -v cswap` 与环境变量。rc 文件可能往输出里打印东西，用标记切出需要的部分
    static func loginShellEnvironment() async -> (cswapPath: String?, env: [String: String]) {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let script = "printf '\\n\(marker)\\n'; command -v cswap; printf '\\n\(marker)\\n'; env"
        guard let out = try? await ProcessRunner.run(URL(filePath: shell), ["-lic", script], environment: nil,
                                                     stdin: nil, timeout: .seconds(8)), !out.timedOut else { return (nil, [:]) }
        let parts = out.stdoutText.components(separatedBy: "\n\(marker)\n")
        guard parts.count >= 3 else { return (nil, [:]) }
        let path = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        var env: [String: String] = [:]
        for line in parts[2].split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            env[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return (path.hasPrefix("/") ? path : nil, env)
    }
}

/// 进程句柄。Process 不是 Sendable，只在下面受控地跨线程使用
final class ProcessBox: @unchecked Sendable {
    let process = Process()
}

/// 跨线程收集输出
final class DataSink: @unchecked Sendable {
    var data = Data()
}

public enum ProcessRunner {
    /// 跑一个命令直到结束；超时先 SIGTERM，3 秒后 SIGKILL。stdin 为 nil 时接 /dev/null
    public static func run(_ executable: URL, _ arguments: [String], environment: [String: String]?, stdin: String?,
                           timeout: Duration) async throws -> CommandOutput {
        let box = ProcessBox()
        let p = box.process
        p.executableURL = executable
        p.arguments = arguments
        if let environment { p.environment = environment }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let input: Pipe? = stdin == nil ? nil : Pipe()
        p.standardInput = input ?? FileHandle.nullDevice

        let outSink = DataSink(), errSink = DataSink()
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let group = DispatchGroup()

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CommandOutput, Error>) in
            group.enter()
            p.terminationHandler = { _ in group.leave() }
            do { try p.run() } catch {
                cont.resume(throwing: CLIError("启动 cswap 失败：\(error.localizedDescription)"))
                return
            }
            for (pipe, sink) in [(out, outSink), (err, errSink)] {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    sink.data = pipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
            }
            if let input, let stdin {
                let h = input.fileHandleForWriting
                try? h.write(contentsOf: Data(stdin.utf8))
                try? h.close()
            }
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                guard box.process.isRunning else { return }
                timedOut.withLock { $0 = true }
                box.process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if box.process.isRunning { kill(box.process.processIdentifier, SIGKILL) }
                }
            }
            group.notify(queue: .global()) {
                cont.resume(returning: CommandOutput(status: box.process.terminationStatus, stdout: outSink.data,
                                                     stderr: errSink.data, timedOut: timedOut.withLock { $0 }))
            }
        }
    }
}

/// 调 cswap：只读命令可并发；写命令串行（一个写完才开始下一个）
public actor CswapCLI {
    public nonisolated let env: CswapEnvironment
    private var writeTail: Task<Void, Never>?

    public init(_ env: CswapEnvironment) { self.env = env }

    /// 执行并检查错误（命令报错、超时、非零退出码都抛 CLIError）
    @discardableResult
    public func run(_ command: Command) async throws -> CommandOutput {
        let out: CommandOutput
        if command.isWrite {
            let previous = writeTail
            let task = Task { [env] in
                _ = await previous?.value
                return try await Self.execute(command, env: env)
            }
            writeTail = Task { _ = try? await task.value }
            out = try await task.value
        } else {
            out = try await Self.execute(command, env: env)
        }
        if let error = CLIError.check(out) { throw error }
        return out
    }

    /// 执行并解码 JSON
    public func json<T: Decodable & Sendable>(_ command: Command, as type: T.Type) async throws -> T {
        let out = try await run(command)
        if let probe = try? JSONDecoder().decode(SchemaProbe.self, from: out.stdout), let v = probe.schemaVersion, v != 1 {
            throw CLIError("cswap 版本不兼容（输出格式 \(v)）")
        }
        do { return try CswapJSON.decode(type, from: out.stdout) } catch {
            throw CLIError("看不懂 cswap 的输出：\(error.localizedDescription)")
        }
    }

    static func execute(_ command: Command, env: CswapEnvironment) async throws -> CommandOutput {
        try await ProcessRunner.run(env.executable, command.arguments, environment: env.environment,
                                    stdin: command.stdin, timeout: command.timeout)
    }
}

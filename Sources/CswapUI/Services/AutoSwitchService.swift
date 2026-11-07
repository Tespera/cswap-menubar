import CswapCore
import Foundation

/// 看护 `cswap auto --json` 子进程（docs/04 §6）。
/// - 不传 --threshold 等参数：全部读 cswap 自己的 autoswitch.* 设置，与命令行保持一致
/// - 意外退出按 5 秒、30 秒、2 分钟、之后每 5 分钟退避重启；连续失败把原因交给界面
/// - 设置变化、cswap 升级后重启；App 退出时 SIGTERM，3 秒后 SIGKILL
@MainActor
final class AutoSwitchService {
    var onEvent: (AutoEvent) -> Void = { _ in }
    var onState: (AutoSwitchState) -> Void = { _ in }

    private var env: CswapEnvironment?
    private var box: ProcessBox?
    private var wanted = false
    private var failures = 0
    private var restartTask: Task<Void, Never>?
    private var startedAt = Date()
    private var lastError: String?
    private var stderrTail = ""

    static let backoff: [TimeInterval] = [5, 30, 120, 300]

    func configure(_ env: CswapEnvironment?) {
        self.env = env
    }

    func setEnabled(_ on: Bool) {
        wanted = on
        if on { start() } else { stop() }
    }

    /// 设置变化 / 升级后：重读设置
    func restart() {
        guard wanted else { return }
        stop(keepWanted: true)
        start()
    }

    private func start() {
        guard wanted, box == nil else { return }
        guard let env else { return report(.failed("没找到 cswap")) }
        restartTask?.cancel()
        Self.killOrphans()
        report(.starting)

        let b = ProcessBox()
        let p = b.process
        p.executableURL = env.executable
        p.arguments = ["auto", "--json"]
        p.environment = env.environment
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        let lines = LineSplitter { [weak self] line in
            Task { @MainActor in self?.handle(line: line) }
        }
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { lines.feed(d) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            let text = String(decoding: d, as: UTF8.self)
            Task { @MainActor in self?.stderrTail = String(((self?.stderrTail ?? "") + text).suffix(600)) }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in self?.exited(b, status: status) }
        }
        do {
            try p.run()
            box = b
            startedAt = Date()
            lastError = nil
            stderrTail = ""
        } catch {
            scheduleRestart(reason: "启动失败：\(error.localizedDescription)")
        }
    }

    private func stop(keepWanted: Bool = false) {
        if !keepWanted { wanted = false }
        restartTask?.cancel()
        restartTask = nil
        failures = 0
        if let b = box {
            box = nil   // 先摘掉：之后的退出回调不算「意外退出」
            Self.terminate(b)
        }
        if !keepWanted { report(.off) }
    }

    /// App 退出时同步结束子进程
    func shutdown() {
        wanted = false
        restartTask?.cancel()
        guard let b = box else { return }
        box = nil
        b.process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while b.process.isRunning && Date() < deadline { usleep(50_000) }
        if b.process.isRunning { kill(b.process.processIdentifier, SIGKILL) }
    }

    private static func terminate(_ b: ProcessBox) {
        guard b.process.isRunning else { return }
        b.process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if b.process.isRunning { kill(b.process.processIdentifier, SIGKILL) }
        }
    }

    private func handle(line: String) {
        guard let event = AutoEvent.parse(line: line) else { return }
        switch event {
        case .poll:
            failures = 0
            report(.running)
        case .error(let message, let transient):
            lastError = message
            if !transient { report(.failed(message)) }
        default:
            break
        }
        onEvent(event)
    }

    private func exited(_ b: ProcessBox, status: Int32) {
        guard box === b else { return }   // 主动结束的，或已被替换
        box = nil
        guard wanted else { return }
        let detail = lastError
            ?? stderrTail.split(whereSeparator: \.isNewline).last.map(String.init)
            ?? "退出码 \(status)"
        // 跑了 10 分钟以上才退出的，不算连续失败
        if Date().timeIntervalSince(startedAt) > 600 { failures = 0 }
        scheduleRestart(reason: detail)
    }

    private func scheduleRestart(reason: String) {
        let delay = Self.backoff[min(failures, Self.backoff.count - 1)]
        failures += 1
        report(.failed("\(reason)，\(Fmt.after(delay))重试"))
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }

    private func report(_ s: AutoSwitchState) { onState(s) }

    /// 结束上次 App 被强杀后遗留的 `cswap auto --json`（父进程已是 launchd）：否则会有两个引擎同时换号。
    /// 只认 PPID 为 1 且参数正好是 `auto --json` 的，终端里手动跑的不动
    static func killOrphans() {
        let p = Process()
        p.executableURL = URL(filePath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard cols.count == 3, let pid = Int32(cols[0]), cols[1] == "1",
                  cols[2].hasSuffix("/cswap auto --json") else { continue }
            kill(pid, SIGTERM)
        }
    }
}

/// 把字节流切成行（跨读块拼接）
final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    func feed(_ data: Data) {
        let lines: [String] = lock.withLock {
            buffer.append(data)
            var out: [String] = []
            while let nl = buffer.firstIndex(of: 0x0A) {
                out.append(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...nl)
            }
            return out
        }
        lines.forEach(onLine)
    }
}

import Foundation
import Testing
@testable import CswapCore

@Suite("解码真实输出")
struct DecodingTests {
    @Test func listFixture() throws {
        let l = try Fixture.list()
        #expect(l.schemaVersion == 1)
        #expect(l.activeAccountNumber == 1)
        #expect(l.accounts.count == 2)
        let a = try #require(l.active)
        #expect(a.email == "alicechen92@example.com")
        #expect(a.usageStatus == .ok)
        #expect(a.usage?.fiveHour?.pct == 90)
        #expect(a.usage?.sevenDay?.aheadOfPace == true)
        #expect(a.usage?.sevenDay?.expectedPct == 44.6)
        #expect(a.plan?.expired == true)
        #expect(a.loginExpiresAt == date("2026-11-19T03:34:00Z"))
        // 6 位小数 + "+00:00" 的时间
        let reset = try #require(a.usage?.fiveHour?.resetsAt)
        #expect(abs(reset.timeIntervalSince(date("2026-11-07T09:10:00Z")) - 0.960992) < 0.001)
        // 5 小时 0% 且没有 resetsAt
        #expect(l.accounts[1].usage?.fiveHour?.pct == 0)
        #expect(l.accounts[1].usage?.fiveHour?.resetsAt == nil)
    }

    @Test func statusFixture() throws {
        let s = try CswapJSON.decode(StatusResponse.self, from: Fixture.data("status.json"))
        #expect(s.active?.email == "alicechen92@example.com")
        #expect(s.active?.managed == true)
    }

    @Test func configFixture() throws {
        let c = try CswapJSON.decode(ConfigList.self, from: Fixture.data("config.json")).autoSwitch
        #expect(c == AutoSwitchConfig(threshold: 90, weeklyThreshold: nil, cooldownSeconds: 300, strategy: .best,
                                      model: nil, includeApiKeyAccounts: false))
    }

    @Test func configWithValues() throws {
        let json = #"{"schemaVersion":1,"settings":[{"key":"autoswitch.threshold","value":85,"isSet":true},{"key":"autoswitch.weeklyThreshold","value":97.5,"isSet":true},{"key":"autoswitch.strategy","value":"priority-consume-first"},{"key":"autoswitch.model","value":"Fable"},{"key":"autoswitch.includeApiKeyAccounts","value":true}]}"#
        let c = try CswapJSON.decode(ConfigList.self, from: Data(json.utf8)).autoSwitch
        #expect(c.threshold == 85)
        #expect(c.weeklyThreshold == 97.5)
        #expect(c.strategy == .priorityConsumeFirst)
        #expect(c.model == "Fable")
        #expect(c.includeApiKeyAccounts)
    }

    @Test func unknownFieldsAndMissingOptionals() throws {
        // 只有编号和邮箱、外加未知字段与未知 usageStatus，也要能解
        let json = #"{"schemaVersion":1,"activeAccountNumber":3,"newTopLevel":{"x":1},"accounts":[{"number":3,"email":"a@b.c","usageStatus":"something_new","usage":null,"futureField":[1,2]}]}"#
        let l = try CswapJSON.decode(AccountList.self, from: Data(json.utf8))
        #expect(l.accounts[0].usageStatus == .other("something_new"))
        #expect(l.accounts[0].usage == nil)
    }

    @Test func scopedWindowName() throws {
        let json = #"{"schemaVersion":1,"accounts":[{"number":1,"email":"a@b.c","usage":{"sevenDay":{"pct":10},"scoped":[{"pct":30,"name":"Fable"}]}}]}"#
        let l = try CswapJSON.decode(AccountList.self, from: Data(json.utf8))
        #expect(l.accounts[0].usage?.scoped?.first?.name == "Fable")
        #expect(l.accounts[0].usage?.fiveHour == nil)
    }

    @Test func dateFormats() {
        #expect(CswapJSON.parseDate("2026-11-19T03:34:00Z") != nil)
        #expect(CswapJSON.parseDate("2026-11-07T09:10:00.960992+00:00") != nil)
        #expect(CswapJSON.parseDate("2026-11-07T09:10:00+02:00") == date("2026-11-07T07:10:00Z"))
        #expect(CswapJSON.parseDate("not a date") == nil)
    }

    @Test func priorityFixture() throws {
        #expect(PriorityParser.parse(try Fixture.text("priority.txt")) == [1: 0, 2: 0])
        #expect(PriorityParser.parse("Account-3  x@y.z  250\n") == [3: 250])
        #expect(PriorityParser.parse("something else entirely") == nil)
    }

    @Test func logFixture() throws {
        let entries = SwitchLog.parse(try Fixture.text("log-switch-lines.txt"), timeZone: TimeZone(identifier: "UTC")!)
        #expect(entries.count == 10)
        #expect(entries.last == LogSwitch(at: date("2026-11-06T09:53:23Z"), from: 2, to: 1))
        #expect(SwitchLog.parse("garbage\n2026-11-06 09:53:23,726 - INFO - Other line").isEmpty)
    }
}

@Suite("auto 事件")
struct AutoEventTests {
    @Test func switchEvent() {
        let line = #"{"schemaVersion":1,"event":"switch","ts":"2026-11-07T07:00:00Z","trigger":"proactive","from":{"number":1,"email":"a@x"},"to":{"number":2,"email":"b@x"},"warnings":[],"dryRun":false}"#
        #expect(AutoEvent.parse(line: line) == .switched(from: .init(number: 1, email: "a@x"), to: .init(number: 2, email: "b@x"),
                                                         trigger: "proactive", dryRun: false, at: date("2026-11-07T07:00:00Z")))
    }

    /// 本机 cswap 0.30.0 `auto --json --once --dry-run` 的真实输出
    @Test func realDryRunLines() {
        let poll = #"{"schemaVersion": 1, "event": "poll", "ts": "2026-11-07T07:39:56Z", "active": {"number": 2, "email": "BobWilliams8810@example.com"}, "headroomPct": {"1": 0.0, "2": 32.0}, "threshold": 90.0, "windowsPct": {"1": {"5h": 100.0, "7d": 73.0}, "2": {"5h": 27.0, "7d": 68.0}}}"#
        let noSwitch = #"{"schemaVersion": 1, "event": "no-switch", "ts": "2026-11-07T07:39:56Z", "reason": "below-threshold", "detail": "7d 68% < 90%"}"#
        #expect(AutoEvent.parse(line: poll) == .poll)
        #expect(AutoEvent.parse(line: noSwitch) == .noSwitch(reason: "below-threshold"))
    }

    @Test func otherEvents() {
        #expect(AutoEvent.parse(line: #"{"event":"poll","ts":"2026-11-07T07:00:00Z","active":null,"headroomPct":{},"threshold":90}"#) == .poll)
        #expect(AutoEvent.parse(line: #"{"event":"account-quarantined","number":"2","email":"b@x","reason":"relogin"}"#)
                == .quarantined(number: 2, email: "b@x", reason: "relogin"))
        #expect(AutoEvent.parse(line: #"{"event":"all-exhausted","earliestResetAt":"2026-11-07T08:00:00Z"}"#)
                == .allExhausted(earliestResetAt: date("2026-11-07T08:00:00Z")))
        #expect(AutoEvent.parse(line: #"{"event":"all-exhausted","earliestResetAt":null}"#) == .allExhausted(earliestResetAt: nil))
        #expect(AutoEvent.parse(line: #"{"event":"error","message":"boom","transient":false}"#) == .error(message: "boom", transient: false))
        #expect(AutoEvent.parse(line: #"{"event":"brand-new-kind","x":1}"#) == .unknown("brand-new-kind"))
        #expect(AutoEvent.parse(line: "Switched Account-1 -> Account-2") == nil)
        #expect(AutoEvent.parse(line: "") == nil)
    }
}

@Suite("命令")
struct CommandTests {
    @Test func arguments() {
        #expect(Command.list.arguments == ["list", "--json"])
        #expect(Command.switchTo(2).arguments == ["switch", "2", "--json"])
        #expect(Command.threshold(1, 97.5).arguments == ["threshold", "1", "97.5"])
        #expect(Command.threshold(1, 90).arguments == ["threshold", "1", "90"])
        #expect(Command.threshold(1, nil).arguments == ["threshold", "1", "--unset"])
        #expect(Command.alias(2, "").arguments == ["alias", "2", "--unset"])
        #expect(Command.add(alias: "备用").arguments == ["add", "--alias", "备用"])
        #expect(Command.addSlot(2).arguments == ["add", "--slot", "2"])
        #expect(Command.configUnset(ConfigKey.weeklyThreshold).arguments == ["config", "unset", "autoswitch.weeklyThreshold"])
    }

    @Test func readWriteAndStdin() {
        #expect(!Command.list.isWrite && !Command.priorities.isWrite)
        #expect(Command.switchTo(1).isWrite && Command.priority(1, 5).isWrite)
        #expect(Command.remove(2).stdin == "y\n")
        #expect(Command.switchTo(2).stdin == nil)
        #expect(Command.upgrade.timeout == .seconds(300))
    }

    @Test func errors() {
        let env = CommandOutput(status: 1, stdout: Data(#"{"schemaVersion":1,"error":{"type":"ClaudeSwitchError","message":"Account 9 not found"}}"#.utf8), stderr: Data())
        #expect(CLIError.check(env) == CLIError("Account 9 not found"))
        let text = CommandOutput(status: 2, stdout: Data(), stderr: Data("Traceback (most recent call last):\n  x\nError: refused in session\n".utf8))
        #expect(CLIError.check(text)?.message == "x Error: refused in session")
        #expect(CLIError.check(CommandOutput(status: 0, stdout: Data("{}".utf8), stderr: Data())) == nil)
        #expect(CLIError.check(CommandOutput(status: 0, stdout: Data(), stderr: Data(), timedOut: true)) != nil)
    }

    @Test func versions() {
        #expect(CswapVersion.parse("cswap 0.30.0\n") == "0.30.0")
        #expect(CswapVersion.isOlder("0.28.0", than: "0.30.0"))
        #expect(!CswapVersion.isOlder("0.30.0", than: "0.30.0"))
        #expect(!CswapVersion.isOlder("0.31", than: "0.30.9"))
        #expect(CswapVersion.isOlder("0.9.9", than: "0.30.0"))
    }
}

@Suite("版本号")
struct VersionTests {
    /// 版本号三位；CHANGELOG.md 要有对应一节（tools/package.sh release 也查这一条）
    @Test func versionFormatAndChangelog() throws {
        let parts = AppVersion.current.split(separator: ".")
        #expect(parts.count == 3 && parts.allSatisfy { Int($0) != nil })
        let repo = Fixture.dir.deletingLastPathComponent()
        let log = try String(contentsOf: repo.appending(path: "CHANGELOG.md"), encoding: .utf8)
        #expect(log.contains("\n## \(AppVersion.current) "), "CHANGELOG.md 缺 \(AppVersion.current) 这一节")
    }
}

@Suite("升级结果")
struct UpgradeOutcomeTests {
    let pinnedOut = """
    Nothing to upgrade

    hint: `claude-swap` is pinned to `0.30.0` (installed with an exact version pin); reinstall with `uv tool install claude-swap@latest` to upgrade to a new version.
    claude-swap is still at 0.30.0.
    """

    @Test func upgraded() {
        #expect(UpgradeOutcome.evaluate(before: "0.30.0", after: "1.0.0", latest: "1.0.0", output: "") == .upgraded(from: "0.30.0", to: "1.0.0"))
    }

    @Test func pinnedIsNotUpToDate() {
        let r = UpgradeOutcome.evaluate(before: "0.30.0", after: "0.30.0", latest: "1.0.0", output: pinnedOut)
        #expect(r == .pinned(current: "0.30.0", latest: "1.0.0"))
        #expect(!r.isOK)
        #expect(r.blockedNote?.contains("0.30.0") == true)
        #expect(r.reinstallCommand?.contains("@latest") == true)
        #expect(r.reinstallCommand?.contains("exclude-newer") == false)
    }

    @Test func cooldown() {
        let out = "claude-swap 1.0.0 is on PyPI, but this install has a release cooldown\n  (uv-receipt.toml: exclude-newer-span = \"P14D\")"
        #expect(UpgradeOutcome.evaluate(before: "0.30.0", after: "0.30.0", latest: "1.0.0", output: out) == .cooldown(current: "0.30.0", latest: "1.0.0"))
    }

    @Test func unchangedWithoutReason() {
        let r = UpgradeOutcome.evaluate(before: "0.30.0", after: "0.30.0", latest: "1.0.0", output: "Nothing to upgrade")
        #expect(r == .unchanged(current: "0.30.0", latest: "1.0.0"))
        #expect(r.blockedNote == nil)
    }

    @Test func upToDate() {
        #expect(UpgradeOutcome.evaluate(before: "1.0.0", after: "1.0.0", latest: "1.0.0", output: "Nothing to upgrade") == .upToDate)
    }
}

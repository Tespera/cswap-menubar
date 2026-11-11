import Foundation
import Testing
@testable import CswapCore

@Suite("状态判定")
struct VerdictTests {
    @Test func fixtureIsNearThreshold() throws {
        // 真实数据：当前账号 5 小时 90%
        let v = OverviewBuilder.verdict(list: try Fixture.list(), now: fixtureNow)
        #expect(v == Verdict(level: .warn, text: "快到切换阈值"))
    }

    @Test func rules() {
        func v(_ l: AccountList?) -> Verdict { OverviewBuilder.verdict(list: l, now: fixtureNow) }
        #expect(v(list(account(1, active: true, five: 20, week: 30))).text == "充足")
        // 按当前速度撑不到刷新（刷新在 3 天后、2 天后用完）→ 偏快，不管有没有超过均速 15 个点
        #expect(v(list(account(1, active: true, five: 20, week: 30, exhaustIn: 2 * 86400))).text == "用得偏快")
        // 只有 cswap 的 aheadOfPace、能撑到刷新 → 充足
        #expect(v(list(account(1, active: true, five: 20, week: 30, ahead: true))).text == "充足")
        // 预计用完在刷新之后 → 充足
        #expect(v(list(account(1, active: true, five: 20, week: 30, exhaustIn: 4 * 86400))).text == "充足")
        // 刷新后头 24 小时外推不可信 → 不判
        #expect(v(list(account(1, active: true, five: 20, week: 5, exhaustIn: 3600, weekReset: fixtureNow.addingTimeInterval(6.5 * 86400)))).text == "充足")
        #expect(v(list(account(1, active: true, five: 85, week: 30))).level == .warn)
        #expect(v(list(account(1, active: true, five: 100, week: 30), account(2, five: 10))).text == "已用完")
        #expect(v(list(account(1, active: true, five: 100), account(2, five: 30, week: 100))).text == "都已用完")
        #expect(v(list(account(1, active: true, status: .tokenExpired))) == Verdict(level: .bad, text: "登录已失效"))
        #expect(v(list(account(1, active: true, five: nil, week: nil))).level == .off)
        #expect(v(nil).level == .off)
    }

    @Test func exhaustionLine() {
        let far = OverviewBuilder.cards(for: account(1, active: true, exhaustIn: 2 * 86400), now: fixtureNow)
        #expect(far[1].exhaustion?.hasPrefix("预计周") == true && far[1].exhaustion?.hasSuffix(" 用完") == true)
        let near = OverviewBuilder.cards(for: account(1, active: true, exhaustIn: 5 * 3600 + 20 * 60), now: fixtureNow)
        #expect(near[1].exhaustion == "预计 5 时 20 分后用完")
        #expect(OverviewBuilder.cards(for: account(1, active: true), now: fixtureNow)[1].exhaustion == nil)
        #expect(far[0].exhaustion == nil)
    }

    @Test func barTint() {
        #expect(BarTint.of(84.9) == .native)
        #expect(BarTint.of(85) == .warn)
        #expect(BarTint.of(100) == .bad)
        #expect(BarTint.of(nil) == .native)
    }
}

@Suite("档位徽章")
struct TierTests {
    @Test func fixtureTiers() throws {
        let l = try Fixture.list()
        // 1 号：App Store 订阅的 Pro，cswap 标 expired（状态 canceled + 免费档额度等级），
        // 但 Pro 的额度等级本就与免费档相同，实际仍在有效期内（用户确认）→ 按 Pro 显示
        #expect(l.accounts[0].plan?.expired == true)
        #expect(TierBadge.of(l.accounts[0].plan) == TierBadge(style: .pro, name: "Pro"))
        // 2 号：有效的 Pro。cswap 的 label 是 Free（Pro 与 Free 的额度等级相同），组织类型 claude_pro 才分得开
        #expect(l.accounts[1].plan?.label == "Free")
        #expect(TierBadge.of(l.accounts[1].plan) == TierBadge(style: .pro, name: "Pro"))
    }

    @Test func rules() {
        #expect(TierBadge.of(Plan(label: "Free", tier: "default_claude_ai")) == TierBadge(style: .free, name: "Free"))
        #expect(TierBadge.of(Plan(label: "Free", tier: "default_claude_ai", organizationType: "claude_free"))?.style == .free)
        #expect(TierBadge.of(Plan(label: "Max 5x", tier: "default_claude_max_5x"))?.style == .max5)
        #expect(TierBadge.of(Plan(label: "Max 20x", tier: "default_claude_max_20x")) == TierBadge(style: .max20, name: "Max 20×"))
        #expect(TierBadge.of(Plan(label: "Team", tier: "default_claude_max_5x", organizationType: "claude_team"))?.style == .team)
        // Pro 档 cswap 没有映射：label 是原文 tier
        #expect(TierBadge.of(Plan(label: "default_claude_pro", tier: "default_claude_pro"))?.style == .pro)
        #expect(TierBadge.of(Plan(label: "weird_tier", tier: "weird_tier")) == TierBadge(style: .unknown, name: "weird_tier"))
        #expect(TierBadge.of(Plan(label: "Free", tier: "default_claude_ai", organizationType: "claude_max", expired: true))
                == TierBadge(style: .unknown, name: "Max", expired: true))
        #expect(TierBadge.of(Plan(label: "Free", tier: "default_claude_ai", organizationType: nil, expired: true))?.name == "")
        #expect(TierBadge.of(Plan(label: "Free", tier: "default_claude_ai", organizationType: "claude_pro", expired: true))?.expired == false)
        #expect(TierBadge.of(nil) == nil)
    }
}

@Suite("主面板映射")
struct OverviewTests {
    @Test func fixtureOverview() throws {
        let o = OverviewBuilder.build(Inputs(list: try Fixture.list(), config: AutoSwitchConfig(), autoSwitch: .running, now: fixtureNow))
        #expect(o.header?.name == "alicechen92")
        #expect(o.cards.map(\.value) == ["90", "71"])
        #expect(o.cards[0].tint == .warn)
        #expect(o.cards[0].foot == "2 时 14 分后刷新")
        #expect(o.cards[1].pace == 44.6)
        #expect(o.cards[1].exhaustion?.hasSuffix("用完") == true)
        #expect(o.rows.count == 2)
        #expect(o.rows[0].isCurrent && o.rows[0].action == nil && o.rows[0].avatar == .color)
        #expect(o.rows[1].action == .switchTo && o.rows[1].avatar == .idle)
        guard case .usage(let bars) = o.rows[1].meta else { Issue.record("应为用量条"); return }
        #expect(bars.map(\.text) == ["5 小时 0%", "本周 64%"])
        #expect(bars.map(\.tint) == [.native, .native])
        // 每列下面带刷新时间（周几随本机时区，只核对写法）
        #expect(bars[0].foot == "还没开始用")
        #expect(bars[1].foot.hasSuffix(" 刷新") && bars[1].foot.hasPrefix("周"))
        // 已经 90%，等于全局阈值：不再预告（到线了）
        #expect(o.autoRow.subtitle == "用到 90% 时换到余量最多的号")
        #expect(o.menuBar.items == [MenuBarItem(kind: .fiveHour, text: "90%", level: .warn),
                                    MenuBarItem(kind: .week, text: "71%", level: .ok)])
        #expect(o.menuBar.tooltip == "alicechen92：5 小时 90%，本周 71%")
        #expect(o.footer.text == "3 分钟前更新")
        #expect(o.blocker == nil)
    }

    @Test func fiveHourCardHiddenAndUnstarted() {
        let a = Account(number: 1, email: "a@b.c", active: true, usage: Usage(sevenDay: UsageWindow(pct: 10)))
        #expect(OverviewBuilder.cards(for: a, now: fixtureNow).map(\.kind) == [.week])
        let b = Account(number: 1, email: "a@b.c", active: true, usage: Usage(fiveHour: UsageWindow(pct: 0), sevenDay: UsageWindow(pct: 10)))
        #expect(OverviewBuilder.cards(for: b, now: fixtureNow)[0].foot == "还没开始用")
    }

    @Test func rowsForSpecialAccounts() {
        let broken = OverviewBuilder.row(account(2, status: .reloginRequired), activeNumber: 1, now: fixtureNow)
        #expect(broken.meta == .broken("登录已失效，在终端重新登录后点刷新"))
        #expect(broken.action == .relogin && broken.avatar == .muted)
        let off = OverviewBuilder.row(account(3, disabled: true), activeNumber: 1, now: fixtureNow)
        #expect(off.isDisabled && off.avatar == .muted)
        if case .disabled(let bar) = off.meta { #expect(bar?.kind == .week) } else { Issue.record("应为不参与自动切换") }
        let unread = OverviewBuilder.row(Account(number: 4, email: "x@y", usage: nil, usageError: "http-429"), activeNumber: 1, now: fixtureNow)
        #expect(unread.meta == .note("用量读取失败（http-429）"))
        #expect(OverviewBuilder.row(account(5, alias: "备用号"), activeNumber: 1, now: fixtureNow).name == "备用号")
    }

    @Test func previewBeforeThreshold() {
        let l = list(account(1, active: true, five: 87, week: 78), account(2, five: 0, week: 59, alias: "备用"),
                     account(3, five: 0, week: 10, disabled: true))
        let o = OverviewBuilder.build(Inputs(list: l, config: AutoSwitchConfig(), autoSwitch: .running, now: fixtureNow))
        #expect(o.autoRow == AutoRow(on: true, subtitle: "快到 90% 了，到线就换到 备用", level: .warn))
        // 没有可换的号
        let solo = list(account(1, active: true, five: 87, week: 78), account(2, status: .tokenExpired))
        #expect(OverviewBuilder.build(Inputs(list: solo, autoSwitch: .running, now: fixtureNow)).autoRow.subtitle == "快到 90% 了，但没有可换的号")
        // 单账号阈值 95%
        let own = list(account(1, active: true, five: 92, week: 10, threshold: 95), account(2, five: 0, week: 0))
        #expect(OverviewBuilder.build(Inputs(list: own, autoSwitch: .running, now: fixtureNow)).autoRow.subtitle.hasPrefix("快到 95% 了"))
        // 关闭时不预告
        #expect(OverviewBuilder.build(Inputs(list: l, autoSwitch: .off, now: fixtureNow)).autoRow == AutoRow(on: false, subtitle: "已关闭", level: .off))
    }

    @Test func candidateByStrategy() {
        let soon = fixtureNow.addingTimeInterval(86400), late = fixtureNow.addingTimeInterval(5 * 86400)
        let l = list(account(1, active: true, five: 88), account(2, five: 10, week: 60, weekReset: soon),
                     account(3, five: 5, week: 20, weekReset: late))
        var c = AutoSwitchConfig()
        #expect(OverviewBuilder.candidate(list: l, excluding: 1, config: c, priorities: [:])?.number == 3)
        c.strategy = .weeklyFirst
        #expect(OverviewBuilder.candidate(list: l, excluding: 1, config: c, priorities: [:])?.number == 2)
        c.strategy = .priorityConsumeFirst
        #expect(OverviewBuilder.candidate(list: l, excluding: 1, config: c, priorities: [3: 10])?.number == 3)
        #expect(OverviewBuilder.candidate(list: l, excluding: 1, config: c, priorities: [:])?.number == 2)
    }

    @Test func autoRowStates() {
        let l = list(account(1, active: true))
        var c = AutoSwitchConfig()
        c.strategy = .consumeFirst
        #expect(OverviewBuilder.build(Inputs(list: l, config: c, autoSwitch: .running, now: fixtureNow)).autoRow.subtitle == "始终用最先刷新的号，用到 90% 再换")
        #expect(OverviewBuilder.build(Inputs(list: l, autoSwitch: .failed("cswap 退出码 1"), now: fixtureNow)).autoRow.level == .bad)
    }

    @Test func menuBarDisplay() {
        let l = list(account(1, active: true, five: 12, week: 67))
        func texts(_ d: MenuBarDisplay) -> [String] {
            OverviewBuilder.build(Inputs(list: l, display: d, now: fixtureNow)).menuBar.items.map(\.text)
        }
        #expect(texts(.fiveHour) == ["12%"])
        #expect(texts(.week) == ["67%"])
        #expect(texts(.both) == ["12%", "67%"])
        // 每个数按自己的用量着色
        let full = list(account(1, active: true, five: 100, week: 86))
        #expect(OverviewBuilder.build(Inputs(list: full, now: fixtureNow)).menuBar.items.map(\.level) == [.bad, .warn])
        // 没有 5 小时窗口：只显示本周
        let noFive = list(account(1, active: true, five: nil, week: 30))
        #expect(OverviewBuilder.build(Inputs(list: noFive, display: .fiveHour, now: fixtureNow)).menuBar.items.map(\.text) == ["30%"])
        #expect(OverviewBuilder.build(Inputs(list: nil, now: fixtureNow)).menuBar.items.map(\.text) == ["—"])
    }

    @Test func currentAccountFirstAndNames() {
        var a = account(1, alias: "loria")
        a.appName = "Loria 主号"
        let l = list(a, account(2), account(3, active: true))
        let rows = OverviewBuilder.build(Inputs(list: l, now: fixtureNow)).rows
        #expect(rows.map(\.number) == [3, 1, 2])
        #expect(rows[1].name == "Loria 主号")
        #expect(OverviewBuilder.displayName(account(4, alias: "loria")) == "loria")
    }

    @Test func footerAndBlockers() {
        let l = list(account(1, active: true))
        let next = fixtureNow.addingTimeInterval(90)
        #expect(OverviewBuilder.build(Inputs(list: l, fetchError: "超时", nextRefreshAt: next, now: fixtureNow)).footer.text == "读取失败，2 分钟后重试（超时）")
        let failing = list(Account(number: 1, email: "a@b", active: true, usage: nil, usageError: "http-429",
                                   usageRetryAt: fixtureNow.addingTimeInterval(240)))
        #expect(OverviewBuilder.build(Inputs(list: failing, now: fixtureNow)).footer.text == "读取失败，4 分钟后重试")
        #expect(OverviewBuilder.build(Inputs(cli: .missing, list: nil, now: fixtureNow)).blocker == .missingCLI)
        #expect(OverviewBuilder.build(Inputs(list: AccountList(activeAccountNumber: nil, accounts: []), now: fixtureNow)).blocker == .noAccounts)
        #expect(OverviewBuilder.build(Inputs(list: nil, refreshing: true, now: fixtureNow)).blocker == .loading)
        #expect(OverviewBuilder.build(Inputs(list: nil, fetchError: "boom", now: fixtureNow)).blocker == .failed("boom"))
    }

    @Test func detail() throws {
        let l = try Fixture.list()
        let d = AccountDetail.build(l.accounts[1], activeNumber: 1, config: AutoSwitchConfig(), priorities: [2: 0], now: fixtureNow)
        #expect(d.tokenStatus == Verdict(level: .ok, text: "正常"))
        #expect(d.thresholdText == "跟随全局 90%")
        #expect(d.priority == 0)
        #expect(d.participates)
        let broken = AccountDetail.build(account(2, status: .reloginRequired, threshold: 95), activeNumber: 1, config: nil, priorities: nil, now: fixtureNow)
        #expect(broken.tokenStatus.text == "需要重新登录")
        #expect(broken.thresholdText == "95%")
        #expect(broken.cards.isEmpty)
        #expect(broken.priority == nil)
        #expect(broken.loginExpiry == "—")
    }
}

@Suite("文案")
struct FormatTests {
    @Test func durations() {
        #expect(Fmt.duration(30) == "不到 1 分")
        #expect(Fmt.duration(50 * 60) == "50 分")
        #expect(Fmt.duration(2 * 3600 + 50 * 60) == "2 时 50 分")
        #expect(Fmt.duration(3 * 3600) == "3 时")
        #expect(Fmt.updatedAgo(20) == "刚刚更新")
        #expect(Fmt.updatedAgo(150) == "2 分钟前更新")
    }

    @Test func refreshText() {
        let cal = utcCalendar()
        let now = date("2026-11-07T07:00:00Z")   // 周六
        #expect(Fmt.refresh(date("2026-11-07T09:50:00Z"), now: now, calendar: cal) == "2 时 50 分后刷新")
        #expect(Fmt.refresh(date("2026-11-11T05:00:00Z"), now: now, calendar: cal) == "周三 05:00 刷新")
        #expect(Fmt.refresh(nil, now: now) == nil)
    }

    @Test func softMoments() {
        let cal = utcCalendar()
        let now = date("2026-11-07T07:00:00Z")
        #expect(Fmt.softMoment(date("2026-11-07T20:00:00Z"), now: now, calendar: cal) == "今天晚上")
        #expect(Fmt.softMoment(date("2026-11-08T13:28:31Z"), now: now, calendar: cal) == "明天中午")
        #expect(Fmt.softMoment(date("2026-11-11T10:00:00Z"), now: now, calendar: cal) == "周三上午")
        #expect(Fmt.softMoment(date("2026-11-20T10:00:00Z"), now: now, calendar: cal) == "11 月 20 日")
    }

    @Test func machineTimeZone() {
        #expect(Fmt.timeZone(fromLocaltimeLink: "/var/db/timezone/zoneinfo/Asia/Shanghai")?.identifier == "Asia/Shanghai")
        #expect(Fmt.timeZone(fromLocaltimeLink: "/usr/share/zoneinfo/Europe/Oslo")?.identifier == "Europe/Oslo")
        #expect(Fmt.timeZone(fromLocaltimeLink: "garbage") == nil)
        // 24 小时制
        #expect(Fmt.clock(date("2026-11-07T15:05:00Z"), calendar: utcCalendar()) == "15:05")
    }

    @Test func historyTimes() {
        let cal = utcCalendar()
        let now = date("2026-11-07T07:00:00Z")
        #expect(Fmt.historyTime(date("2026-11-07T01:02:00Z"), now: now, calendar: cal) == "今天 01:02")
        #expect(Fmt.historyTime(date("2026-11-06T09:53:00Z"), now: now, calendar: cal) == "昨天 09:53")
        #expect(Fmt.historyTime(date("2026-11-05T11:08:00Z"), now: now, calendar: cal) == "11-05 11:08")
    }
}

@Suite("切换记录与通知")
struct HistoryNoticeTests {
    @Test func mergeSources() {
        let cal = utcCalendar()
        let now = date("2026-11-07T07:00:00Z")
        let log = [LogSwitch(at: date("2026-11-06T09:53:23Z"), from: 2, to: 1),
                   LogSwitch(at: date("2026-11-07T06:00:00Z"), from: 1, to: 2)]
        let records = [HistoryRecord(at: date("2026-11-07T06:00:03Z"), from: 1, to: 2, source: .auto),
                       HistoryRecord(at: date("2026-11-07T06:30:00Z"), from: 2, to: 1, toEmail: "eep@x.com", source: .panel)]
        let items = SwitchLog.merge(log: log, records: records, names: [2: "Loria"], now: now, calendar: cal)
        #expect(items == [
            HistoryItem(title: "换到 eep", source: "面板", time: "今天 06:30"),
            HistoryItem(title: "换到 Loria", source: "自动", time: "今天 06:00"),
            HistoryItem(title: "换到 账号 1", source: "命令行", time: "昨天 09:53"),
        ])
    }

    @Test func notices() throws {
        let l = try Fixture.list()
        let n = Notices.switched(to: l.accounts[1], toEmail: nil, from: l.accounts[0])
        #expect(n == Notices.Notice(title: "已换到 BobWilliams8810", body: "alicechen92 5 小时用到了 90%"))
        let ex = Notices.allExhausted(list: l, earliestResetAt: l.accounts[0].usage?.fiveHour?.resetsAt,
                                      now: date("2026-11-07T08:18:00Z"))
        #expect(ex.title == "两个账号都用完了")
        #expect(ex.body == "最早 53 分后刷新（alicechen92 的 5 小时额度）")
        let exp = Notices.loginExpiring(l.accounts[1], now: date("2026-11-16T01:00:00Z"))
        #expect(exp?.title == "BobWilliams8810 的登录 7 天后过期")
        #expect(Notices.loginExpiring(l.accounts[1], now: fixtureNow) == nil)
        #expect(Notices.quarantined(name: "x").body == "在终端重新登录后，到面板里点刷新")
    }
}

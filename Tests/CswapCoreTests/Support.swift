import Foundation
@testable import CswapCore

/// 仓库根目录 fixtures/：本机 cswap 0.30.0 的真实输出（唯一一份，文档与测试共用）
enum Fixture {
    static let dir = URL(filePath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appending(path: "fixtures")

    static func data(_ name: String) throws -> Data { try Data(contentsOf: dir.appending(path: name)) }
    static func text(_ name: String) throws -> String { String(decoding: try data(name), as: UTF8.self) }
    static func list() throws -> AccountList { try CswapJSON.decode(AccountList.self, from: data("list.json")) }
}

func date(_ iso: String) -> Date { CswapJSON.parseDate(iso)! }

/// list.json 抓取的时刻附近
let fixtureNow = date("2026-11-07T06:57:00Z")

func utcCalendar() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

func account(_ n: Int, active: Bool = false, five: Double? = 10, week: Double? = 20, ahead: Bool? = nil,
             status: UsageStatus = .ok, disabled: Bool? = nil, threshold: Double? = nil, alias: String? = nil,
             weekReset: Date? = nil, plan: Plan? = Plan(label: "Free", tier: "default_claude_ai")) -> Account {
    let usage = Usage(fiveHour: five.map { UsageWindow(pct: $0, resetsAt: fixtureNow.addingTimeInterval(3600)) },
                      sevenDay: week.map { UsageWindow(pct: $0, resetsAt: weekReset ?? fixtureNow.addingTimeInterval(3 * 86400),
                                                  expectedPct: 40, aheadOfPace: ahead) })
    return Account(number: n, email: "user\(n)@example.com", active: active, usageStatus: status,
                   usage: five == nil && week == nil ? nil : usage, disabled: disabled, threshold: threshold,
                   alias: alias, plan: plan)
}

func list(_ accounts: Account...) -> AccountList {
    AccountList(activeAccountNumber: accounts.first { $0.active == true }?.number, accounts: accounts)
}

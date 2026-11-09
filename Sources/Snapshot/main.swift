import AppKit
import CswapCore
import CswapUI
import SwiftUI

// 开发用：把面板按各场景渲染成 PNG（浅色 + 深色）+ 状态栏图标，输出到第一个参数指定的目录。
// 用法：swift run Snapshot /tmp/cswap-shots
// 场景对应 design-demos/a4.html：现在（fixtures 真实数据）、四个档位、快到阈值、都用完、读不到、登录失效、各子页

let outDir = CommandLine.arguments.dropFirst().first ?? "/tmp/cswap-shots"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let fixtures = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appending(path: "fixtures")
let realList = try! CswapJSON.decode(AccountList.self, from: Data(contentsOf: fixtures.appending(path: "list.json")))
let now = CswapJSON.parseDate("2026-11-07T06:57:00Z")!

func win(_ pct: Double?, resetIn: TimeInterval? = 3 * 3600, expected: Double? = nil, ahead: Bool? = nil,
         eta: TimeInterval? = nil) -> UsageWindow {
    UsageWindow(pct: pct, resetsAt: resetIn.map { now.addingTimeInterval($0) }, expectedPct: expected, aheadOfPace: ahead,
           projectedExhaustionAt: eta.map { now.addingTimeInterval($0) }, willLastToReset: eta == nil ? nil : false)
}

func acct(_ n: Int, _ email: String, alias: String? = nil, active: Bool = false, plan: Plan?, five: UsageWindow?, week: UsageWindow?,
          status: UsageStatus = .ok, disabled: Bool? = nil, expires: TimeInterval? = 14 * 86400) -> Account {
    var a = Account(number: n, email: email, active: active, usageStatus: status,
                    usage: five == nil && week == nil ? nil : Usage(fiveHour: five, sevenDay: week),
                    usageAgeSeconds: 40, disabled: disabled, alias: alias,
                    loginExpiresAt: expires.map { now.addingTimeInterval($0) }, plan: plan)
    a.organizationName = nil
    return a
}

let free = Plan(label: "Free", tier: "default_claude_ai")
let pro = Plan(label: "default_claude_pro", tier: "default_claude_pro", organizationType: "claude_pro")
let max5 = Plan(label: "Max 5x", tier: "default_claude_max_5x")
let max20 = Plan(label: "Max 20x", tier: "default_claude_max_20x")
let team = Plan(label: "Team", tier: "default_claude_max_5x", organizationType: "claude_team")

let tiersList = AccountList(activeAccountNumber: 1, accounts: [
    acct(1, "work@example.com", alias: "工作号", active: true, plan: max20, five: win(34, resetIn: 6000), week: win(41, resetIn: 4 * 86400, expected: 52)),
    acct(2, "max5@example.com", alias: "备用 Max", plan: max5, five: win(12, resetIn: 14700), week: win(58, resetIn: 2 * 86400, expected: 80)),
    acct(3, "pro@example.com", alias: "个人 Pro", plan: pro, five: win(0, resetIn: nil), week: win(22, resetIn: 5 * 86400, expected: 15)),
    acct(4, "team@example.com", alias: "团队席位", plan: team, five: win(5, resetIn: 9000), week: win(18, resetIn: 3 * 86400)),
    acct(5, "free@example.com", alias: "测试号", plan: free, five: win(0, resetIn: nil), week: win(5, resetIn: 6 * 86400), disabled: true),
])

let nearList = AccountList(activeAccountNumber: 1, accounts: [
    acct(1, "alicechen92@example.com", active: true, plan: pro, five: win(87, resetIn: 3900),
         week: win(78, resetIn: 4 * 86400, expected: 52, ahead: true, eta: 2 * 86400 + 3600 * 5)),
    acct(2, "BobWilliams8810@example.com", plan: pro, five: win(0, resetIn: nil), week: win(59, resetIn: 3 * 86400, expected: 57)),
])

let exhaustedList = AccountList(activeAccountNumber: 1, accounts: [
    acct(1, "alicechen92@example.com", active: true, plan: pro, five: win(100, resetIn: 3120), week: win(81, resetIn: 4 * 86400, expected: 52)),
    acct(2, "BobWilliams8810@example.com", plan: free, five: win(30, resetIn: 9000), week: win(100, resetIn: 2 * 86400, expected: 70)),
])

var unreadable = realList
unreadable.accounts[0].usage = nil
unreadable.accounts[0].usageError = "http-429"
unreadable.accounts[0].usageRetryAt = now.addingTimeInterval(240)
unreadable.accounts[0].lastGoodUsage = realList.accounts[0].usage

let brokenList = AccountList(activeAccountNumber: 1, accounts: [
    acct(1, "alicechen92@example.com", active: true, plan: pro, five: win(40, resetIn: 11400), week: win(51, resetIn: 4 * 86400, expected: 44)),
    acct(2, "BobWilliams8810@example.com", plan: pro, five: nil, week: nil, status: .reloginRequired, expires: nil),
])

let history = [
    HistoryItem(title: "换到 alicechen92", source: "自动", time: "今天 06:12"),
    HistoryItem(title: "换到 BobWilliams8810", source: "面板", time: "昨天 22:40"),
    HistoryItem(title: "换到 alicechen92", source: "命令行", time: "昨天 09:53"),
    HistoryItem(title: "换到 BobWilliams8810", source: "命令行", time: "昨天 07:50"),
    HistoryItem(title: "换到 alicechen92", source: "命令行", time: "11-05 11:08"),
]

var customConfig = AutoSwitchConfig(threshold: 90, weeklyThreshold: 97, cooldownSeconds: 300, strategy: .best)
customConfig.model = nil

let newApp = AppUpdate.Candidate(version: "0.4.0", url: URL(string: "https://example.com/cswap-0.4.0.zip")!)
/// 仓库里的 CHANGELOG.md（App 里由打包放进 Resources）
let changelogText = (try? String(contentsOf: URL(filePath: #filePath).deletingLastPathComponent()
    .appending(path: "../../CHANGELOG.md").standardized, encoding: .utf8)) ?? ""

struct Scenario {
    let name: String
    let model: @MainActor () -> PanelModel
}

let scenarios: [Scenario] = [
    .init(name: "01-now") { .preview(list: realList, now: now) },
    .init(name: "02-tiers") { .preview(list: tiersList, autoSwitch: .running, now: now) },
    .init(name: "03-near") { .preview(list: nearList, autoSwitch: .running, now: now) },
    .init(name: "04-exhausted") { .preview(list: exhaustedList, autoSwitch: .running, now: now) },
    .init(name: "05-unreadable") { .preview(list: unreadable, autoSwitch: .running, now: now) },
    .init(name: "06-broken") { .preview(list: brokenList, autoSwitch: .running, now: now) },
    .init(name: "07-missing-cli") { .preview(list: nil, cli: .missing, version: nil, now: now) },
    .init(name: "08-auto-failed") { .preview(list: realList, autoSwitch: .failed("cswap 退出码 1，30 秒后重试"), now: now) },
    .init(name: "09-toast") { .preview(list: realList, toast: Toast(text: "已换到 BobWilliams8810", level: .ok), now: now) },
    .init(name: "10-detail") { .preview(list: realList, priorities: [1: 0, 2: 0], pages: [.detail(2)], now: now) },
    .init(name: "11-detail-broken") { .preview(list: brokenList, priorities: [1: 0, 2: 3], pages: [.detail(2)], now: now) },
    .init(name: "10b-detail-threshold") {
        var l = realList
        l.accounts[1].threshold = 97
        return .preview(list: l, priorities: [1: 0, 2: 0], pages: [.detail(2)], now: now)
    },
    .init(name: "12-auto") { .preview(list: realList, config: customConfig, autoSwitch: .running, pages: [.autoSwitch], now: now) },
    .init(name: "13-settings") { .preview(list: realList, pages: [.settings], latest: "0.31.0", now: now) },
    .init(name: "13b-settings-upgrade-pinned") {
        .preview(list: realList, pages: [.settings], latest: "1.0.0",
                 versionNote: .upgrade(.pinned(current: "0.30.0", latest: "1.0.0")), now: now)
    },
    .init(name: "13c-settings-upgraded") {
        .preview(list: realList, pages: [.settings], version: "1.0.0", latest: "1.0.0",
                 versionNote: .upgrade(.upgraded(from: "0.30.0", to: "1.0.0")), now: now)
    },
    .init(name: "14-history") { .preview(list: realList, pages: [.history], history: history, now: now) },
    // App 自己的更新
    .init(name: "15-just-updated") { .preview(list: realList, now: now, justUpdated: AppVersion.current) },
    .init(name: "15b-update-badge") { .preview(list: realList, now: now, appUpdate: .available(newApp), autoUpdate: false) },
    .init(name: "15c-settings-available") {
        .preview(list: realList, pages: [.settings], now: now, appUpdate: .available(newApp), autoUpdate: false)
    },
    .init(name: "15d-settings-ready") { .preview(list: realList, pages: [.settings], now: now, appUpdate: .ready(newApp)) },
    .init(name: "15e-settings-failed") {
        .preview(list: realList, pages: [.settings], now: now, appUpdate: .failed("安装包签名不对，已丢弃"))
    },
    .init(name: "16-changelog") { .preview(list: realList, pages: [.changelog], now: now, changelog: changelogText) },
]

@MainActor
func render<V: View>(_ view: V, scheme: ColorScheme, to path: String, scale: CGFloat = 2) {
    let r = ImageRenderer(content: view.environment(\.colorScheme, scheme))
    r.scale = scale
    // ImageRenderer 输出的色彩空间与 PNG 默认假设不同（直接写出偏暗）：先画进 8 位 sRGB 画布再保存
    guard let src = r.cgImage,
          let ctx = CGContext(data: nil, width: src.width, height: src.height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        print("渲染失败：\(path)")
        return
    }
    ctx.draw(src, in: CGRect(x: 0, y: 0, width: src.width, height: src.height))
    guard let cg = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
        print("渲染失败：\(path)")
        return
    }
    try? png.write(to: URL(filePath: path))
}

@MainActor
func renderStatusBar(_ label: MenuBarLabel, dark: Bool, to path: String) {
    let ap = NSAppearance(named: dark ? .darkAqua : .aqua)!
    var img: NSImage!
    ap.performAsCurrentDrawingAppearance { img = StatusImage.make(label, height: 24) }
    let size = NSSize(width: img.size.width * 4 + 40, height: img.size.height * 4 + 16)
    let canvas = NSImage(size: size, flipped: false) { rect in
        (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.94, alpha: 1)).setFill()
        rect.fill()
        ap.performAsCurrentDrawingAppearance {
            let target = NSRect(x: 20, y: 8, width: img.size.width * 4, height: img.size.height * 4)
            if img.isTemplate {
                let tinted = NSImage(size: img.size, flipped: false) { r in
                    img.draw(in: r)
                    (dark ? NSColor.white : NSColor.black).set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: target)
            } else {
                img.draw(in: target)
            }
        }
        return true
    }
    if let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(filePath: path))
    }
}

MainActor.assumeIsolated {
    for s in scenarios {
        let m = s.model()
        for scheme in [ColorScheme.light, .dark] {
            // 面板底近似系统毛玻璃（设计稿：浅 rgba(244,244,246,.82)，深 rgba(38,38,42,.8)）
            let bg = scheme == .light ? Color(red: 244 / 255, green: 244 / 255, blue: 246 / 255) : Color(red: 38 / 255, green: 38 / 255, blue: 42 / 255)
            let v = PanelView(model: m).background(bg).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(16).background(scheme == .light ? Color(white: 0.80) : Color(white: 0.08))
            render(v, scheme: scheme, to: "\(outDir)/\(s.name)-\(scheme == .light ? "light" : "dark").png")
        }
    }
    let labels: [(String, MenuBarLabel)] = [
        ("both", .init(items: [.init(kind: .fiveHour, text: "30%", level: .ok), .init(kind: .week, text: "68%", level: .ok)], tooltip: "")),
        ("both-warn", .init(items: [.init(kind: .fiveHour, text: "90%", level: .warn), .init(kind: .week, text: "71%", level: .ok)], tooltip: "")),
        ("week", .init(items: [.init(kind: .week, text: "68%", level: .ok)], tooltip: "")),
        ("bad", .init(items: [.init(kind: .fiveHour, text: "100%", level: .bad)], tooltip: "")),
        ("unknown", .init(items: [.init(kind: .week, text: "—", level: .ok)], tooltip: "")),
    ]
    for (name, label) in labels {
        for dark in [false, true] {
            renderStatusBar(label, dark: dark, to: "\(outDir)/statusbar-\(name)-\(dark ? "dark" : "light").png")
        }
    }
    // 尺寸自检：真实面板（带滚动视图）的理想高度要等于内容高度；屏幕放不下时截到上限
    for (name, pages, maxH) in [("主面板", [Page](), CGFloat(900)), ("自动切换页", [.autoSwitch], 900), ("自动切换页·矮屏", [.autoSwitch], 400)] {
        let m = PanelModel.preview(list: realList, config: customConfig, pages: pages, now: now, forImageRenderer: false)
        m.maxHeight = maxH
        let host = NSHostingView(rootView: PanelView(model: m))
        host.sizingOptions = [.intrinsicContentSize]
        print("尺寸自检 \(name)（上限 \(Int(maxH))）：\(host.intrinsicContentSize)")
    }
    print("已输出到 \(outDir)")
}

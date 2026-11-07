import AppKit
import CswapCore
import CswapUI
import Observation
import SwiftUI

/// 面板窗口：无边框、不抢焦点（不让其他 App 失去激活），但能成为 key 窗口以接收悬停、点击和输入
final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: PanelWindow!
    /// 面板内容。只报告理想尺寸（preferredContentSize），不往窗口上加约束：
    /// 让 Auto Layout 按内容撑窗口时，系统以左下角为准，窗口会先向上长再被挪回（闪烁）
    private var controller: NSHostingController<PanelView>!
    private var sizeObservation: NSKeyValueObservation?
    private let model = PanelModel.live()
    private var outsideMonitor: Any?
    private var keyMonitor: Any?
    private var hiddenByOutsideClickAt = Date.distantPast
    private static let gapBelowMenuBar: CGFloat = 6

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        trackStatusImage()
        buildPanel()
        openForDebugIfAsked()
    }

    /// 开发验证：`--show 步骤,步骤,…` 启动后打开面板，每 2.5 秒执行一步（main / detail:N / auto / settings / history / back），
    /// 配合 screencapture 截真实效果（Snapshot 画不出毛玻璃、窗口伸缩、滚动视图和系统控件）
    private func openForDebugIfAsked() {
        let args = CommandLine.arguments
        guard let k = args.firstIndex(of: "--show") else { return }
        let steps = (k + 1 < args.count ? args[k + 1] : "main").split(separator: ",").map(String.init)
        for (i, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4 + 2.5 * Double(i)) { [weak self] in
                guard let self else { return }
                if !self.panel.isVisible { self.showPanel() }
                switch step {
                case "auto": self.model.push(.autoSwitch)
                case "settings": self.model.push(.settings)
                case "history": self.model.push(.history)
                case "back": self.model.pop()
                case let t where t.hasPrefix("detail:"): Int(t.dropFirst(7)).map { self.model.push(.detail($0)) }
                default: break
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    /// 菜单栏图标随数据重画（Observation：读到的属性变了就再画一次）
    private func trackStatusImage() {
        withObservationTracking {
            let label = model.overview.menuBar
            statusItem.button?.image = StatusImage.make(label)
            statusItem.button?.toolTip = label.tooltip
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackStatusImage() }
        }
    }

    private func buildPanel() {
        panel = PanelWindow(contentRect: NSRect(x: 0, y: 0, width: PanelView.width, height: 400),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        // 系统毛玻璃，圆角 12
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.roundedMask(radius: 12)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor

        // 内容视图铺满窗口（SwiftUI 里内容贴顶排布）；窗口高度由 fitPanel 按理想高度调整、顶边不动
        controller = NSHostingController(rootView: PanelView(model: model))
        controller.sizingOptions = [.preferredContentSize]
        controller.view.autoresizingMask = [.width, .height]
        controller.view.frame = effect.bounds
        effect.addSubview(controller.view)
        panel.contentView = effect
        sizeObservation = controller.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.fitPanel() } }
        }
    }

    /// NSVisualEffectView 的材质不受 layer 圆角裁剪（四角会露出直角），需用可拉伸的遮罩图
    static func roundedMask(radius r: CGFloat) -> NSImage {
        let size = NSSize(width: r * 2 + 1, height: r * 2 + 1)
        let img = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }

    private var contentHeight: CGFloat {
        let h = controller.preferredContentSize.height
        return h > 0 ? h : controller.view.fittingSize.height
    }

    /// 内容高度变化时保持顶边贴着菜单栏，向下伸缩
    private func fitPanel() {
        guard panel.isVisible else { return }
        let h = contentHeight
        guard h > 0, abs(panel.frame.height - h) > 0.5 else { return }
        var f = panel.frame
        f.origin.y += f.height - h
        f.size.height = h
        panel.setFrame(f, display: true)
        panel.invalidateShadow()
    }

    @objc private func toggle() {
        if panel.isVisible { return hidePanel() }
        // 点状态栏图标时，按下会先被当成「点了面板外面」把面板关掉，松开时又触发这里：
        // 刚因外部点击关闭的，这次点击的本意是「关闭」，不再重新打开
        if Date().timeIntervalSince(hiddenByOutsideClickAt) < 0.4 { return }
        showPanel()
    }

    private func showPanel() {
        guard let button = statusItem.button else { return }
        let win = button.window
        let screen = win?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        model.maxHeight = screen.height - Self.gapBelowMenuBar - 20
        model.panelDidShow()
        controller.view.layoutSubtreeIfNeeded()
        let size = NSSize(width: PanelView.width, height: contentHeight)
        // 图标被菜单栏管理工具收起（不在屏幕上）时，面板放在屏幕右上角
        var anchor = win.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) } ?? .zero
        if win?.isVisible != true || !screen.insetBy(dx: -1, dy: -40).contains(NSPoint(x: anchor.midX, y: anchor.minY)) {
            anchor = NSRect(x: screen.maxX - PanelView.width / 2 - 10, y: screen.maxY, width: 0, height: 0)
        }
        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.minX + 6), screen.maxX - size.width - 6)
        let y = anchor.minY - Self.gapBelowMenuBar - size.height
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        button.highlight(true)

        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hiddenByOutsideClickAt = Date()
                self.hidePanel()
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            // NSEvent 不是 Sendable：先取出需要的值再进主线程隔离区
            let code = e.keyCode, window = e.windowNumber
            let cmdQ = e.modifierFlags.contains(.command) && e.charactersIgnoringModifiers == "q"
            let handled = MainActor.assumeIsolated { self?.handleKey(code: code, cmdQ: cmdQ, window: window) ?? false }
            return handled ? nil : e
        }
    }

    /// Esc：子页先返回，主面板再关闭；⌘Q 退出
    private func handleKey(code: UInt16, cmdQ: Bool, window: Int) -> Bool {
        guard window == panel.windowNumber else { return false }
        if code == 53 {
            if model.pages.isEmpty { hidePanel() } else { model.pop() }
            return true
        }
        if cmdQ { model.quit(); return true }
        return false
    }

    private func hidePanel() {
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        model.panelDidHide()
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
}

/// 同一用户只运行一个 cswap 菜单栏：对锁文件加独占 flock，拿不到说明已有实例。锁随进程退出自动释放
enum SingleInstance {
    nonisolated(unsafe) private static var fd: Int32 = -1

    static func acquire() -> Bool {
        let dir = NSHomeDirectory() + "/Library/Application Support/cswap"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let f = open(dir + "/instance.lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard f >= 0 else { return true }
        if flock(f, LOCK_EX | LOCK_NB) != 0 {
            let err = errno
            close(f)
            return err != EWOULDBLOCK
        }
        fd = f
        return true
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    // 调试：cswap-app --dump 读取几秒后打印对当前状态的理解并退出（不显示界面）
    if CommandLine.arguments.contains("--dump") {
        let m = PanelModel.live()
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            MainActor.assumeIsolated {
                print(m.debugSummary)
                m.shutdown()
                exit(0)
            }
        }
        app.run()
    }

    // 单实例：「登录时打开」与手动打开同时发生时，只留一个状态栏图标
    guard SingleInstance.acquire() else {
        print("cswap 菜单栏已在运行，本实例退出")
        exit(0)   // 正常退出：LaunchAgent 的 KeepAlive 只在异常退出时重启
    }

    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}

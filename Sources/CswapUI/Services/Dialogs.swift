import AppKit

/// 系统对话框（移除确认、设置别名、添加账号的引导）。
/// 面板在 popUpMenu 层级，对话框要再高一层才不会被挡住；菜单栏 App 弹框前要先激活自己才能输入
@MainActor
enum Dialogs {
    private static func present(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate()
        alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        alert.icon = Assets.avatar
        return alert.runModal()
    }

    /// 对话框里的输入框：28pt 高，输入方便
    private static func inputField() -> NSTextField {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 28))
        field.font = .systemFont(ofSize: 13)
        field.bezelStyle = .roundedBezel
        field.controlSize = .large
        return field
    }

    /// 移除账号：「移除」为危险样式，默认按钮是「取消」
    static func confirmRemove(name: String, email: String) -> Bool {
        let a = NSAlert()
        a.messageText = "移除 \(name)？"
        a.informativeText = "\(email) 会从 cswap 里删除，之后要用它得重新登录并添加。"
        let remove = a.addButton(withTitle: "移除")
        remove.hasDestructiveAction = true
        a.addButton(withTitle: "取消").keyEquivalent = "\r"
        remove.keyEquivalent = ""
        return present(a) == .alertFirstButtonReturn
    }

    /// 设置别名：返回 nil = 取消；空字符串 = 清除别名
    static func askAlias(name: String, current: String) -> String? {
        let a = NSAlert()
        a.messageText = "给 \(name) 设置别名"
        a.informativeText = "起个短名字，大小写、中文都可以。\n留空即清除。"
        let field = Self.inputField()
        field.stringValue = current
        field.placeholderString = "备用号"
        a.accessoryView = field
        a.addButton(withTitle: "保存")
        a.addButton(withTitle: "取消")
        a.window.initialFirstResponder = field
        guard present(a) == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 添加账号的引导：返回 nil = 取消；否则为别名（可空）。
    /// 对话框很窄：邮箱单独一行，步骤与提醒分段，避免长句在奇怪的位置折行
    static func confirmAdd(currentEmail: String?, alreadyAdded: Bool) -> String? {
        let a = NSAlert()
        a.messageText = alreadyAdded ? "当前登录的号已经添加过了" : "添加当前登录的账号"
        var parts: [String] = []
        if let e = currentEmail { parts.append("Claude Code 现在登录的是：\n\(e)") }
        parts.append(alreadyAdded
            ? "要添加别的号：先在 Claude Code 里用 /login 登录它，再回来点「添加」。"
            : "要添加的如果是别的号：先在 Claude Code 里用 /login 登录它，再回来点「添加」。")
        parts.append("不要先 /logout，那可能让上一个号的登录失效。")
        a.informativeText = parts.joined(separator: "\n\n")
        let field = Self.inputField()
        field.placeholderString = "别名（可不填，大小写、中文都可以）"
        a.accessoryView = field
        a.addButton(withTitle: "添加")
        a.addButton(withTitle: "取消")
        guard present(a) == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

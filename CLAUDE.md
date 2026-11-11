# CLAUDE.md

cswap：claude-swap 命令行的 macOS 菜单栏 App（原生 Swift）。先读 `docs/08-开发指南.md`（README 是给用户看的），再按需读 `docs/`。实现以 `design-demos/a4.html` 和 `docs/03-界面与设计规范.md` 为准；被否的方案见 `docs/07-决策记录.md`，不要重提。

## 边界（最重要）

- App **只调 cswap 命令、读结果**，不读写 cswap 的凭据、钥匙串、`sequence.json`。只读例外：日志 `~/.claude-swap-backup/claude-swap.log`、更新缓存 `cache/update_check.json`，解析失败一律降级隐藏。
- 命令行不提供的由 App 自建（用户决定：「功能不变，App 能做的就自己做」）。来源划分见 `docs/02-功能清单.md`。
- 调命令：去掉 `CLAUDE_CONFIG_DIR`、stdin 默认 /dev/null、写命令串行；`remove` 要往 stdin 写 `y`；`add --slot N` 之前先用 `status --json` 核对当前登录邮箱。细节见 `docs/05-cswap命令行对接.md`。
- 状态到界面的映射全部放 `CswapCore/Overview.swift`（纯函数、有测试），视图里不写判断逻辑。
- 待定功能（全局快捷键、备份与恢复、文件夹绑定、用量历史、快捷指令）用户没表态，不开工。

## 构建（与 NetHub 相同的约束）

命令：`swift test`、`swift run cswap-app [--dump]`、`swift run Snapshot /tmp/cswap-shots`、`tools/package.sh [install|release]`。
- **版本号**唯一来源 `Sources/CswapCore/Version.swift`（同 NetHub）：修 bug 改第三位，加功能 / 行为变化改第二位，不兼容改第一位；改版本同时在 `CHANGELOG.md` 记一笔（有测试守着）。介绍文案也在这里。
- **真机自查**：终端能截屏。`cswap-app --show main,detail:1,back,auto,settings` 启动后打开面板并每 2.5 秒走一步，配合 `screencapture` 看真实效果（毛玻璃、窗口伸缩、滚动视图、系统控件 Snapshot 画不出）。跑之前先退出已安装的实例（单实例）。
- 面板窗口：SwiftUI 内容用 `NSHostingController(sizingOptions: .preferredContentSize)` 铺满窗口、内容贴顶，窗口按理想高度调整、顶边不动。**不要**让 Auto Layout 约束按内容撑窗口（以左下角为准，窗口先向上长 = 闪烁），也不要在布局过程中改窗口大小（会被忽略、画面停在旧内容）。

只装 Command Line Tools，**不能依赖 Xcode**：
- 不用 `@State`（macOS 27 SDK 起是宏，SwiftUI 宏插件只随 Xcode 发）；局部界面状态用 `@StateObject` + 小 `ObservableObject`。`@Observable` 可以用（CLT 自带 ObservationMacros，已实测），PanelModel 用的就是它。
- 测试用 Swift Testing，`Package.swift` 给测试目标加 `-load-plugin-library <TestingMacros>`（照抄 NetHub）。没有 XCTest。
- 字体 `F.sys / F.num`、颜色 `T.*`（从 NetHub `Theme.swift` 复制）。
- 状态栏用 `NSStatusItem` + `NSPanel`，不用 `MenuBarExtra`（要彩色百分比）。

## 验证

- 终端截不到真实菜单栏：界面用 `Snapshot` 目标出图自查，真机效果交给用户。
- 不可逆操作（移除账号）和会真实换号的测试，先问用户。
- 本机正在用的两个账号是真实账号，测试不要动它们的凭据。

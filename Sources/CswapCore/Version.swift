/// App 版本号与介绍：唯一来源。界面、Info.plist 都从这里取（tools/package.sh 从本文件读出写进 Info.plist）。
///
/// 三位 MAJOR.MINOR.PATCH：修 bug 改第三位；加功能或行为有变化改第二位；与旧版不兼容（数据格式、安装布局）改第一位。
/// 改版本时同时在 CHANGELOG.md 记一笔（有测试守着）；tools/package.sh release 会打 v<版本> 标签，
/// 标签已存在且不在当前提交上时拒绝打包（= 改了代码忘了改版本号）。做法同 NetHub
public enum AppVersion {
    public static let current = "0.1.0"
    /// 一句话介绍：写进 Info.plist，显示在访达「显示简介」/ 快速查看里（设置页不放）
    public static let tagline = "Claude Code 账号切换（搭配 Claude-cswap）"
}

// swift-tools-version: 6.2
import Foundation
import PackageDescription

// 只装 Command Line Tools 时，构建系统不会把 Swift Testing 的宏插件传给编译器（@Test 报 plugin not found），
// 这里显式加载；插件不存在（装了完整 Xcode 等）时不加。做法同 NetHub
let testingMacros = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
let testSettings: [SwiftSetting] = FileManager.default.fileExists(atPath: testingMacros)
    ? [.unsafeFlags(["-load-plugin-library", testingMacros])] : []

let package = Package(
    name: "cswap",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "cswap-app", targets: ["CswapApp"]),
    ],
    targets: [
        // 纯逻辑：cswap 输出的解码、状态到界面的映射、文案与格式化、命令参数（可单元测试，不碰进程与界面）
        .target(name: "CswapCore"),
        // 界面与 App 端服务：SwiftUI 视图、面板数据模型、调用 cswap、自动切换子进程、通知、登录时打开
        .target(name: "CswapUI", dependencies: ["CswapCore"], resources: [.copy("Resources")]),
        // App 外壳：状态栏按钮 + 面板窗口 + 单实例
        .executableTarget(name: "CswapApp", dependencies: ["CswapUI", "CswapCore"]),
        // 开发用：把面板按各场景渲染成 PNG（浅 / 深色），检查界面
        .executableTarget(name: "Snapshot", dependencies: ["CswapUI", "CswapCore"]),

        .testTarget(name: "CswapCoreTests", dependencies: ["CswapCore"],
                    swiftSettings: testSettings),
    ],
    swiftLanguageModes: [.v6]
)

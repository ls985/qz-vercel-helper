// swift-tools-version:5.9
// SwiftPM 验证工程：在 Windows 上编译并测试 ios/GoToLibrary 的业务核心层。
//
// 这个 Package 与 Xcode 工程完全独立：
//   - Core / Services 两个 target 直接引用 ../GoToLibrary 下的真实源码（不复制），
//     保证验证的就是将要发版的代码；
//   - Apple 专属框架（CryptoKit/Security/UIKit/Network/Combine/UserNotifications）
//     由 verification/shims 下的同名模块桩替代，签名与真实框架一致；
//   - CryptoKit 桩转发到 swift-crypto（Apple 官方 CryptoKit 的跨平台同源实现），
//     AES-GCM / ECDSA P-256 语义与真机一致；
//   - UI 层（SwiftUI）在 Windows 上无法编译，不在本 Package 范围内。
import PackageDescription

let package = Package(
    name: "GoToLibraryVerification",
    products: [
        .executable(name: "CoreVerify", targets: ["CoreVerify"]),
    ],
    dependencies: [
        .package(path: "verification/vendor/swift-crypto"),
    ],
    targets: [
        .target(name: "CryptoKit",
                dependencies: [.product(name: "Crypto", package: "swift-crypto")],
                path: "verification/shims/CryptoKit"),
        .target(name: "Security", path: "verification/shims/Security"),
        .target(name: "UIKit", path: "verification/shims/UIKit"),
        .target(name: "Network", path: "verification/shims/Network"),
        .target(name: "Combine", path: "verification/shims/Combine"),
        .target(name: "UserNotifications", path: "verification/shims/UserNotifications"),
        .target(name: "AppCore",
                dependencies: ["CryptoKit", "Security", "UIKit", "Network"],
                path: "GoToLibrary/Core"),
        .target(name: "AppServices",
                dependencies: ["AppCore", "Combine", "UIKit", "UserNotifications"],
                path: "GoToLibrary/Services"),
        .executableTarget(name: "CoreVerify",
                          dependencies: ["AppCore", "AppServices"],
                          path: "verification/Tests"),
    ]
)

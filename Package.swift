// swift-tools-version:5.9
// SmartBlind — macOS 메뉴 막대 상주형 실시간 이름 인식 블라인드
//
//  SmartBlindCore : 순수 Swift 로직 (이름 매칭, 가림 영역 계산, 스크롤 추적, 설정 모델)
//                   → macOS/Linux 어디서나 빌드·테스트 가능
//  SmartBlind     : macOS 앱 (ScreenCaptureKit · Vision · Accessibility · AppKit/SwiftUI)
import PackageDescription
import Foundation

let fixturesExist = FileManager.default.fileExists(
    atPath: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Tests/SmartBlindCoreTests/Fixtures").path)

var products: [Product] = [
    .library(name: "SmartBlindCore", targets: ["SmartBlindCore"]),
]
var targets: [Target] = [
    .target(
        name: "SmartBlindCore",
        path: "Sources/SmartBlindCore"
    ),
    .testTarget(
        name: "SmartBlindCoreTests",
        dependencies: ["SmartBlindCore"],
        path: "Tests/SmartBlindCoreTests",
        // 실제 화면 캡처 fixture는 개인정보라 저장소에 올리지 않음 (있으면 로컬에서만 사용)
        exclude: fixturesExist ? ["Fixtures"] : []
    ),
]

#if os(macOS)
products.append(.executable(name: "SmartBlind", targets: ["SmartBlind"]))
targets.append(
    .executableTarget(
        name: "SmartBlind",
        dependencies: ["SmartBlindCore"],
        path: "Sources/SmartBlind",
        linkerSettings: [
            .linkedFramework("AppKit"),
            .linkedFramework("ScreenCaptureKit"),
            .linkedFramework("Vision"),
            .linkedFramework("CoreImage"),
            .linkedFramework("ApplicationServices"),
            .linkedFramework("ServiceManagement"),
        ]
    )
)
#endif

let package = Package(
    name: "SmartBlind",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)

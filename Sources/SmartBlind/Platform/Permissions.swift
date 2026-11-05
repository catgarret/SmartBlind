import AppKit
import ApplicationServices
import CoreGraphics

/// 화면 기록 / 손쉬운 사용 권한
enum Permissions {
    /// 화면 및 시스템 오디오 녹음 (화면 캡처 → OCR, 모자이크/블러)
    static var screenCapture: Bool { CGPreflightScreenCaptureAccess() }

    /// 손쉬운 사용 (메신저 텍스트 읽기, 클릭 가로채기, Option+클릭 전달)
    static var accessibility: Bool { AXIsProcessTrusted() }

    static func requestScreenCapture() {
        _ = CGRequestScreenCaptureAccess()
    }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openScreenCaptureSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}

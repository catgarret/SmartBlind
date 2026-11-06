import AppKit
import SwiftUI
import SmartBlindCore

@main
struct SmartBlindApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(model)
        } label: {
            Image(systemName: model.settings.paused ? "eye" : "eye.slash")
        }
        .menuBarExtraStyle(.window)
    }
}

extension AppModel {
    /// 앱 전체에서 하나만 쓰는 모델
    static let shared = AppModel()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 메뉴 막대 전용 앱 (Dock 아이콘 없음)
        NSApp.setActivationPolicy(.accessory)
        let model = AppModel.shared
        model.start()
        // 처음 실행(대상 없음)이거나 권한이 없으면 권한 요청 + 설정 창
        if model.settings.people.isEmpty || !Permissions.screenCapture || !Permissions.accessibility {
            if !Permissions.screenCapture { Permissions.requestScreenCapture() }
            if !Permissions.accessibility { Permissions.requestAccessibility() }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                SettingsWindowController.shared.show()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.save()
        AppModel.shared.engine.stop()
    }
}

/// 설정 창 (SwiftUI 화면을 일반 NSWindow에 담아 직접 관리)
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(AppModel.shared))
            let w = NSWindow(contentViewController: host)
            w.title = "SmartBlind 설정"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 780, height: 580))
            w.minSize = NSSize(width: 700, height: 500)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 설정 창을 닫으면 이름을 다시 가림
    func windowWillClose(_ notification: Notification) {
        AppModel.shared.revealNamesInSettings = false
    }
}

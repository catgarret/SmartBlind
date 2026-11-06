import AppKit
import Combine
import ServiceManagement
import SmartBlindCore

/// 설정 저장 + 엔진 연결 + 권한/상태 표시
final class AppModel: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            engine.apply(settings)
            scheduleSave()
        }
    }
    @Published private(set) var status = EngineStatus()
    @Published private(set) var screenCaptureGranted = Permissions.screenCapture
    @Published private(set) var accessibilityGranted = Permissions.accessibility
    @Published var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)

    // 설정 화면 상태 (Command Line Tools 일부 버전에서 SwiftUI @State 매크로를 쓸 수 없어 여기에 둠)
    @Published var selectedPersonID: UUID?
    @Published var selectedAppID: String?
    @Published var selectedRoomID: UUID?
    /// 설정 화면에서 실제 이름 보기 (설정 창을 닫으면 다시 가려짐, 저장 안 함)
    @Published var revealNamesInSettings = false
    @Published var manualBundleID = ""
    @Published var discoveryMessage: String?

    let engine: BlindEngine
    let ocrLanguages: [String]
    private var saveWork: DispatchWorkItem?
    private var permissionTimer: Timer?

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SmartBlind", isDirectory: true)
    }
    static var settingsURL: URL { supportDirectory.appendingPathComponent("settings.json") }

    init() {
        let loaded = Self.load()
        settings = loaded
        engine = BlindEngine(settings: loaded)
        ocrLanguages = OCRService().languages
        engine.onTogglePaused = { [weak self] in self?.togglePause() }
        engine.onStatus = { [weak self] st in
            guard let self, self.status != st else { return }
            self.status = st
        }
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refreshPermissions() }
        RunLoop.main.add(t, forMode: .common)
        permissionTimer = t
    }

    func start() {
        ensureNaverWorks()
        engine.start()
        // NAVER WORKS를 나중에 설치·실행해도 자동 등록
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  AppDiscovery.isNaverWorks(name: app.localizedName, bundleID: app.bundleIdentifier) else { return }
            self?.ensureNaverWorks()
        }
    }

    // MARK: NAVER WORKS 자동 등록

    private static let autoAddedKey = "SmartBlind.autoAddedApps"

    /// 설치/실행 중인 NAVER WORKS를 찾아 감시 앱 맨 위에 등록 (한 번 등록한 뒤 사용자가 지우면 다시 넣지 않음)
    @discardableResult
    func ensureNaverWorks(force: Bool = false) -> [AppDiscovery.Found] {
        let found = AppDiscovery.findNaverWorks()
        var done = Set(UserDefaults.standard.stringArray(forKey: Self.autoAddedKey) ?? [])
        var s = settings
        for app in found where force || !done.contains(app.bundleID) {
            done.insert(app.bundleID)
            if let i = s.apps.firstIndex(where: { $0.id == app.bundleID }) {
                if force { s.apps[i].enabled = true }
            } else {
                s.apps.insert(AppRule(id: app.bundleID, displayName: "NAVER WORKS"), at: 0)
            }
        }
        UserDefaults.standard.set(Array(done), forKey: Self.autoAddedKey)
        if s != settings { settings = s }
        return found
    }

    /// 감시 앱 중 NAVER WORKS가 켜져 있는지
    var naverWorksWatched: Bool {
        settings.apps.contains { $0.enabled && AppDiscovery.isNaverWorks(name: $0.displayName, bundleID: $0.id) }
    }

    // MARK: 권한

    func refreshPermissions() {
        let sc = Permissions.screenCapture
        let axs = Permissions.accessibility
        if sc != screenCaptureGranted { screenCaptureGranted = sc }
        if axs != accessibilityGranted { accessibilityGranted = axs }
    }

    func requestScreenCapture() {
        Permissions.requestScreenCapture()
        Permissions.openScreenCaptureSettings()
    }

    func requestAccessibility() {
        Permissions.requestAccessibility()
        Permissions.openAccessibilitySettings()
    }

    // MARK: 로그인 시 실행

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("SmartBlind: launch at login 변경 실패: \(error.localizedDescription)")
        }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    // MARK: 동작

    func togglePause() { settings.paused.toggle() }

    func hideAllRevealed() { engine.hideAllRevealed() }

    func revealSettingsFile() {
        save()
        NSWorkspace.shared.activateFileViewerSelecting([Self.settingsURL])
    }

    // MARK: 저장/불러오기

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(settings).write(to: Self.settingsURL, options: .atomic)
        } catch {
            NSLog("SmartBlind: 설정 저장 실패: \(error.localizedDescription)")
        }
    }

    private static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }
}

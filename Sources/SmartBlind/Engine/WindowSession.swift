import AppKit
import SmartBlindCore

/// 감시 중인 창 하나의 상태 (메인 스레드 전용)
final class WindowSession {
    let id: CGWindowID
    var info: WindowInfo
    var kind: WindowKind
    let tracker: BlindTracker
    let overlay = OverlayWindow()

    // 캡처
    var stream: WindowStream?
    var streamStarting = false
    var streamRetryAt: CFTimeInterval = 0
    var latest: CapturedFrame?

    // 인식
    var dirty = true
    var detecting = false
    var detectionScheduled = false
    var lastDetectionAt: CFTimeInterval = 0
    var lastDetectedSignature: [Float]?
    var lastDetectedSize: CGSize = .zero
    var ocrLines: [TextLine] = []
    var everDetected = false

    // 그리기
    var processed: CGImage?
    var processedFrame: CapturedFrame?
    var renderInFlight = false
    var processedKey = ""
    /// 배경색 방식의 가림막 색 캐시 (가림막 ID → 위치 키, 프레임, 색)
    var fillCache: [UUID: (key: String, frame: CapturedFrame?, color: CGColor)] = [:]

    // 화면 상태
    var onScreen = true
    var lastSeen: CFTimeInterval
    let createdAt: CFTimeInterval
    /// 이 창을 덮고 있는 다른 창 (창 기준 좌표 / CG 전역)
    var occludersLocal: [CGRect] = []
    var occludersGlobal: [CGRect] = []

    init(info: WindowInfo, kind: WindowKind, now: CFTimeInterval) {
        self.id = info.id
        self.info = info
        self.kind = kind
        self.tracker = BlindTracker(windowSize: info.frame.size)
        self.lastSeen = now
        self.createdAt = now
    }

    var windowBounds: CGRect { CGRect(origin: .zero, size: info.frame.size) }

    /// 오버레이 패널 레벨: 대상 창 바로 위 (알림 배너처럼 높은 레벨 창도 덮을 수 있게)
    var panelLevel: Int { max(NSWindow.Level.floating.rawValue, info.layer + 1) }

    func tearDown() {
        processed = nil
        processedFrame = nil
        latest = nil
        stream?.stop()
        stream = nil
        overlay.hide()
        overlay.close()
    }
}

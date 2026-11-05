import AppKit
import CoreGraphics

/// 가림막 위 클릭을 가로채 공개/다시 가림으로 바꾼다.
///
/// - 오버레이 패널은 마우스를 통과시키므로 스크롤·드래그 등 나머지 조작은 메신저에 그대로 전달된다.
/// - 가림막 위 일반 클릭: 메신저에 전달하지 않고 공개/가림 전환
/// - Option + 클릭: Option 키를 떼고 원래 클릭으로 메신저에 전달 (가려진 채로 메시지 열기 등)
/// - 다른 창에 가려진 부분의 클릭은 건드리지 않는다.
final class ClickInterceptor {
    struct Target {
        let windowID: CGWindowID
        let blindID: UUID
        /// CG 전역 좌표
        let rect: CGRect
        /// 이 가림막을 덮고 있는 다른 창 (CG 전역)
        let occluders: [CGRect]
    }

    /// 메인 스레드에서 호출
    var onToggle: ((CGWindowID, UUID) -> Void)?

    private var targets: [Target] = []
    private let lock = NSLock()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var swallowing = false

    var isRunning: Bool { tap != nil }

    func setTargets(_ t: [Target]) {
        lock.lock(); targets = t; lock.unlock()
    }

    /// 손쉬운 사용 권한이 없으면 실패(false)
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<ClickInterceptor>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = port
        let t = Thread { [weak self] in
            guard let self, let port = self.tap else { return }
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            let rl = CFRunLoopGetCurrent()
            self.runLoop = rl
            CFRunLoopAddSource(rl, src, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        t.name = "SmartBlind.ClickInterceptor"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        return true
    }

    func stop() {
        if let port = tap {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let rl = runLoop { CFRunLoopStop(rl) }
        tap = nil
        runLoop = nil
        thread = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port = tap { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        case .leftMouseDown:
            let p = event.location
            lock.lock()
            let hit = targets.last { $0.rect.contains(p) && !$0.occluders.contains(where: { $0.contains(p) }) }
            lock.unlock()
            guard let hit else { return Unmanaged.passUnretained(event) }
            if event.flags.contains(.maskAlternate) {
                // 원래 메신저로 전달 (Option 키는 떼고)
                event.flags = event.flags.subtracting(.maskAlternate)
                return Unmanaged.passUnretained(event)
            }
            swallowing = true
            let cb = onToggle
            DispatchQueue.main.async { cb?(hit.windowID, hit.blindID) }
            return nil
        case .leftMouseDragged:
            return swallowing ? nil : Unmanaged.passUnretained(event)
        case .leftMouseUp:
            if swallowing { swallowing = false; return nil }
            if event.flags.contains(.maskAlternate) {
                let p = event.location
                lock.lock()
                let onBlind = targets.contains { $0.rect.contains(p) }
                lock.unlock()
                if onBlind { event.flags = event.flags.subtracting(.maskAlternate) }
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

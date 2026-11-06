import AppKit
import CoreVideo
import QuartzCore
import ScreenCaptureKit
import SmartBlindCore

/// 상태 화면용 요약
struct EngineStatus: Equatable {
    var running = false
    var watchedApps: [String] = []
    var windowCount = 0
    var blindCount = 0
    var lastRecognitionMS = 0
    var clickMode = "-"
}

/// 창 추적 → 캡처 → 인식(접근성 + OCR) → 가림 영역 계산 → 오버레이 표시를 묶는 엔진.
/// 모든 공개 메서드는 메인 스레드에서 호출한다.
final class BlindEngine {
    private(set) var settings: AppSettings
    var onStatus: ((EngineStatus) -> Void)?
    /// 창 위 켜기/끄기 버튼을 눌렀을 때
    var onTogglePaused: (() -> Void)?
    private var buttons: [CGWindowID: ToggleButtonPanel] = [:]
    /// 마우스가 올라가 있는 가림막 (살짝 보기)
    private var hoveredBlind: UUID?
    /// 창 왼쪽 세로 메뉴(사이드바) 폭. nil = 사이드바 없음(대화방 창 등)
    private var sidebarWidths: [CGWindowID: (size: CGSize, width: CGFloat?)] = [:]

    private let catalog = WindowCatalog()
    private let ocr = OCRService()
    private let ax = AccessibilityScanner()
    private let renderer = BlindRenderer()
    private let clicks = ClickInterceptor()
    private let detectQueue = DispatchQueue(label: "smartblind.detect", qos: .userInteractive, attributes: .concurrent)

    private var sessions: [CGWindowID: WindowSession] = [:]
    private var scWindows: [CGWindowID: SCWindow] = [:]
    private var fetchingShareable = false
    private var lastShareableFetch: CFTimeInterval = 0
    private var detectors: [String: Detector] = [:]
    private var customImage: NSImage?

    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var lastMovement: CFTimeInterval = 0
    private var lastStatusPublish: CFTimeInterval = 0
    private var lastRecognitionMS = 0
    private var observers: [NSObjectProtocol] = []
    private var running = false

    init(settings: AppSettings) {
        self.settings = settings
        loadCustomImage()
        clicks.onToggle = { [weak self] wid, bid in self?.toggleReveal(windowID: wid, blindID: bid) }
    }

    // MARK: 시작/중지

    func start() {
        guard !running else { return }
        running = true
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.timerFired() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        let wc = NSWorkspace.shared.notificationCenter
        observers.append(wc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            // Space 전환: 이전 Space의 가림막이 남지 않게 즉시 숨기고 다시 계산
            self?.hideAllOverlays()
            self?.tick(force: true)
        })
        observers.append(wc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.appTerminated(pid: app.processIdentifier)
        })
        observers.append(wc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.tick(force: true)
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.hideAllOverlays()
            self?.tick(force: true)
        })
        tick(force: true)
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        for o in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            NotificationCenter.default.removeObserver(o)
        }
        observers.removeAll()
        clicks.stop()
        for s in sessions.values { s.tearDown() }
        sessions.removeAll()
        for b in buttons.values { b.close() }
        buttons.removeAll()
        publishStatus(force: true)
    }

    func apply(_ new: AppSettings) {
        let old = settings
        settings = new
        if old.people != new.people || old.rooms != new.rooms || old.recognition.matchMode != new.recognition.matchMode || old.apps != new.apps || old.coverMode != new.coverMode {
            detectors.removeAll()
            for s in sessions.values { s.dirty = true; s.lastDetectedSignature = nil }
        }
        if old.style.imagePath != new.style.imagePath { loadCustomImage() }
        if old.style != new.style {
            for s in sessions.values { s.processed = nil; s.processedFrame = nil; requestRender(s); refreshOverlay(s) }
        }
        if old.recognition.performance != new.recognition.performance {
            for s in sessions.values {
                s.stream?.update(pointSize: s.info.frame.size, scale: ScreenGeometry.backingScale(forCG: s.info.frame),
                                 fps: new.recognition.performance.captureFPS)
            }
        }
        tick(force: true)
    }

    // MARK: 주기 처리

    private func timerFired() {
        let now = CACurrentMediaTime()
        // 창이 움직이는 중이면 60Hz, 아니면 성능 모드에 맞춰
        let moving = now - lastMovement < 0.4
        let interval: Double
        switch settings.recognition.performance {
        case .responsive: interval = 1.0 / 60
        case .balanced: interval = moving ? 1.0 / 60 : 1.0 / 30
        case .saver: interval = moving ? 1.0 / 30 : 1.0 / 12
        }
        if now - lastTick >= interval - 0.002 { tick(force: false) }
    }

    private var isActive: Bool { running && !settings.paused && settings.hasTargets }

    private func tick(force: Bool) {
        let now = CACurrentMediaTime()
        lastTick = now
        // 켜기/끄기 버튼은 일시정지 중에도 보여야 다시 켤 수 있다
        let showButtons = running && settings.showToggleButton && settings.hasTargets
        let snapshot: [WindowInfo]
        if showButtons || isActive {
            catalog.overlayWindowNumbers = Set(sessions.values.compactMap { s in
                s.overlay.windowNumber > 0 ? CGWindowID(s.overlay.windowNumber) : nil
            })
            snapshot = catalog.snapshot()
        } else {
            snapshot = []
        }
        updateButtons(snapshot, visible: showButtons)
        guard isActive else {
            if !sessions.isEmpty {
                // 끄기: 가림막이 서서히 사라지게
                for s in sessions.values {
                    s.stream?.stop()
                    s.stream = nil
                    s.overlay.fadeAwayAndClose()
                }
                sessions.removeAll()
            }
            if clicks.isRunning { clicks.stop() }
            publishStatus(force: force)
            return
        }
        ensureClickInterceptor()

        let windows = snapshot
        let ownPID = catalog.ownProcessID
        var rules: [String: AppRule] = [:]
        for r in settings.apps where r.enabled { rules[r.id] = r }

        var seen = Set<CGWindowID>()
        for (index, w) in windows.enumerated() {
            guard w.pid != ownPID, w.alpha > 0.01, w.frame.width >= 24, w.frame.height >= 16 else { continue }
            let isNC = w.bundleID == AppSettings.notificationCenterBundleID
            var kind = WindowKind.normal
            if isNC {
                guard settings.recognition.watchNotificationCenter else { continue }
                kind = .notification
            } else {
                guard let b = w.bundleID, let rule = rules[b] else { continue }
                let toastLike = w.layer != 0 || (w.frame.height <= 200 && w.frame.width <= 520)
                if toastLike {
                    guard rule.watchToasts else { continue }
                    kind = .toast
                }
            }
            seen.insert(w.id)

            let s: WindowSession
            if let existing = sessions[w.id] {
                s = existing
                if existing.info.frame != w.frame {
                    lastMovement = now
                    if existing.info.frame.size != w.frame.size {
                        // 창 크기 변경: 캡처를 새 크기로 다시 시작 (크기를 바꾸는 동안은 0.25초씩 미룸)
                        // 기존 캡처 설정만 바꾸면 이전 크기로 축소된 프레임이 섞여 위치가 어긋날 수 있다
                        s.tracker.windowSize = w.frame.size
                        s.tracker.resetScrollArea()
                        s.dirty = true
                        s.stream?.stop()
                        s.stream = nil
                        s.streamStarting = false
                        s.latest = nil
                        s.processed = nil
                        s.processedFrame = nil
                        s.lastDetectedSignature = nil
                        s.ocrLines = []
                        s.streamRetryAt = now + 0.25
                    }
                }
                s.info = w
                if !s.onScreen {
                    // 다른 Space/최소화에서 돌아옴: 저장된 가림막을 즉시 다시 보이고 재인식
                    s.onScreen = true
                    s.dirty = true
                }
            } else {
                s = WindowSession(info: w, kind: kind, now: now)
                sessions[w.id] = s
                s.overlay.onDirectClick = { [weak self, weak s] p in
                    guard let self, let s, let b = s.tracker.hit(p) else { return }
                    self.toggleReveal(windowID: s.id, blindID: b.id)
                }
                // 새 알림/토스트: 인식 전까지 먼저 가림 (순간 노출 방지)
                if kind != .normal && settings.recognition.preBlindNewPopups && w.frame.height <= 320 {
                    s.tracker.addProvisional(CGRect(origin: .zero, size: w.frame.size))
                }
            }
            s.lastSeen = now

            // 이 창보다 앞에 있으면서 오버레이 레벨 이하인 창 = 가림막을 잘라낼 영역
            var occLocal: [CGRect] = []
            var occGlobal: [CGRect] = []
            let level = s.panelLevel
            for o in windows[..<index] where o.alpha > 0.01 && o.layer <= level && o.frame.intersects(w.frame) {
                occGlobal.append(o.frame)
                occLocal.append(o.frame.offsetBy(dx: -w.frame.minX, dy: -w.frame.minY))
            }
            s.occludersLocal = occLocal
            s.occludersGlobal = occGlobal
        }

        // 사라진 창
        for (id, s) in sessions where !seen.contains(id) {
            if s.onScreen {
                s.onScreen = false
                s.overlay.hide()
                s.stream?.stop()
                s.stream = nil
                s.latest = nil
                s.processed = nil
                s.processedFrame = nil
                // 알림/토스트는 다시 나타나면 새 창이므로 바로 정리
                if s.kind != .normal { s.tearDown(); sessions[id] = nil; continue }
            }
            if now - s.lastSeen > 300 { s.tearDown(); sessions[id] = nil }
        }

        ensureStreams(now: now)

        updateHover()
        let date = Date()
        for s in sessions.values where s.onScreen {
            _ = s.tracker.expireReveals(now: date)
            refreshOverlay(s)
            if s.dirty { scheduleDetection(s) }
        }
        updateClickTargets()
        publishStatus(force: force)
    }

    // MARK: 창 위 켜기/끄기 버튼

    private func updateButtons(_ windows: [WindowInfo], visible: Bool) {
        guard visible else {
            for b in buttons.values { b.close() }
            buttons.removeAll()
            return
        }
        let ownPID = catalog.ownProcessID
        let buttonNumbers = Set(buttons.values.map { CGWindowID(max(0, $0.windowNumber)) })
        var seen = Set<CGWindowID>()
        for (index, w) in windows.enumerated() {
            guard w.pid != ownPID, w.layer == 0, w.alpha > 0.01, w.frame.width >= 200, w.frame.height >= 240,
                  let bid = w.bundleID, let rule = settings.rule(for: bid), rule.enabled else { continue }
            seen.insert(w.id)
            let btn: ToggleButtonPanel
            if let b = buttons[w.id] { btn = b } else {
                btn = ToggleButtonPanel()
                btn.onToggle = { [weak self] in self?.onTogglePaused?() }
                btn.onMoved = { f in UserDefaults.standard.set(Double(f), forKey: "SmartBlind.buttonY.\(bid)") }
                buttons[w.id] = btn
            }
            // 목록 창(왼쪽 세로 메뉴가 있는 창)은 그 메뉴 아래쪽(홈 버튼 위)에, 대화방 창은 오른쪽에
            let sidebar = sidebarWidth(for: w)
            let key = "SmartBlind.buttonY.\(bid).\(sidebar == nil ? "right" : "sidebar")"
            btn.onMoved = { f in UserDefaults.standard.set(Double(f), forKey: key) }
            let stored = UserDefaults.standard.object(forKey: key) as? Double
            let fraction = CGFloat(stored ?? (sidebar == nil ? 0.78 : Double(max(0.5, (w.frame.height - 190) / w.frame.height))))
            let rect = ToggleButtonPanel.buttonRect(windowFrameCG: w.frame, fraction: fraction, sidebarWidth: sidebar)
            // 버튼 자리를 다른 창이 덮고 있으면 숨김
            let blocked = windows[..<index].contains { o in
                !buttonNumbers.contains(o.id) && o.alpha > 0.01 && o.layer <= NSWindow.Level.floating.rawValue
                    && o.frame.intersects(rect)
            }
            btn.update(windowFrameCG: w.frame, fraction: fraction, sidebarWidth: sidebar, level: 0,
                       on: !settings.paused, blocked: blocked)
        }
        for (id, b) in buttons where !seen.contains(id) {
            b.close()
            buttons[id] = nil
            sidebarWidths[id] = nil
        }
    }

    /// 창 왼쪽 끝에 진한 단색 세로 메뉴가 있으면 그 폭 (NAVER WORKS 목록 창의 갈색 메뉴 등)
    private func sidebarWidth(for w: WindowInfo) -> CGFloat? {
        if let c = sidebarWidths[w.id], c.size == w.frame.size { return c.width }
        guard let px = sessions[w.id]?.latest?.pixels, px.width >= 120, px.height >= 200 else {
            return sidebarWidths[w.id]?.width
        }
        let y0 = px.height * 3 / 10, y1 = px.height * 7 / 10
        let probe = CGRect(x: 6, y: y0, width: 30, height: y1 - y0)
        let base = px.dominantColor(in: probe, step: 3)
        let lum = (Int(base.r) * 299 + Int(base.g) * 587 + Int(base.b) * 114) / 1000
        var same = 0, total = 0
        var y = y0
        while y < y1 {
            var x = 6
            while x < 36 { if px.pixel(x, y).distance(base) <= 18 { same += 1 }; total += 1; x += 3 }
            y += 3
        }
        var result: CGFloat?
        if lum < 140, total > 0, same * 100 / total >= 80 {
            // 오른쪽으로 같은 색이 이어지는 폭
            var x = 36
            let mid = (y0 + y1) / 2
            while x < min(px.width / 3, 160), px.pixel(x, mid).distance(base) <= 18 { x += 1 }
            if x >= 40 { result = CGFloat(x) }
        }
        sidebarWidths[w.id] = (w.frame.size, result)
        return result
    }

    private func hideAllOverlays() {
        for s in sessions.values { s.overlay.hide() }
    }

    private func appTerminated(pid: pid_t) {
        catalog.forget(pid: pid)
        for (id, s) in sessions where s.info.pid == pid {
            s.tearDown()
            sessions[id] = nil
        }
    }

    // MARK: 캡처

    private func ensureStreams(now: CFTimeInterval) {
        guard Permissions.screenCapture else { return }
        var missing: [WindowSession] = []
        for s in sessions.values where s.onScreen && s.stream == nil && !s.streamStarting && now >= s.streamRetryAt {
            if let scw = scWindows[s.id] { startStream(s, window: scw) } else { missing.append(s) }
        }
        guard !missing.isEmpty, !fetchingShareable, now - lastShareableFetch > 0.25 else { return }
        fetchingShareable = true
        lastShareableFetch = now
        ShareableWindows.fetch { [weak self] map in
            guard let self else { return }
            self.fetchingShareable = false
            self.scWindows = map
            for s in missing where self.sessions[s.id] === s && s.onScreen && s.stream == nil && !s.streamStarting {
                if let scw = map[s.id] { self.startStream(s, window: scw) } else { s.streamRetryAt = CACurrentMediaTime() + 0.5 }
            }
        }
    }

    private func startStream(_ s: WindowSession, window: SCWindow) {
        let ws = WindowStream(windowID: s.id)
        let sid = s.id
        ws.onFrame = { [weak self] frame in
            DispatchQueue.main.async { self?.handleFrame(frame, windowID: sid) }
        }
        ws.onStop = { [weak self, weak s] _ in
            guard let self, let s, self.sessions[sid] === s else { return }
            s.stream = nil
            s.streamRetryAt = CACurrentMediaTime() + 1
        }
        s.stream = ws
        s.streamStarting = true
        ws.start(window: window, pointSize: s.info.frame.size, scale: ScreenGeometry.backingScale(forCG: s.info.frame),
                 fps: settings.recognition.performance.captureFPS) { [weak self, weak s] err in
            guard let s else { return }
            s.streamStarting = false
            if err != nil {
                s.stream = nil
                s.streamRetryAt = CACurrentMediaTime() + 2
                self?.scWindows[sid] = nil
            }
        }
    }

    private func handleFrame(_ frame: CapturedFrame, windowID: CGWindowID) {
        guard let s = sessions[windowID], s.onScreen else { return }
        // 크기 변경 전 캡처에서 늦게 도착한 프레임은 버림
        guard abs(frame.pointSize.width - s.info.frame.width) < 1, abs(frame.pointSize.height - s.info.frame.height) < 1 else { return }
        let prev = s.latest
        s.latest = frame
        if let prev, prev.pointSize == frame.pointSize {
            let diff = ScrollEstimator.compare(prevSig: prev.signature, curSig: frame.signature, height: frame.pixels.height)
            if diff.changed {
                if settings.recognition.predictScroll, let shift = diff.shift {
                    s.tracker.applyShift(shift, bandTop: diff.bandTop, bandBottom: diff.bandBottom)
                }
                s.dirty = true
            } else if !s.everDetected {
                s.dirty = true
            }
        } else {
            s.dirty = true
        }
        // 안 읽은 수 배지: 새 메시지가 오면 인식을 기다리지 않고 바로 뚫어 보이게
        let layout = LayoutAnalyzer(image: frame.pixels, size: frame.pointSize)
        s.tracker.updateHoles { b in
            guard let badge = layout.findBadge(in: b.rect) else { return [] }
            return [badge.offsetBy(dx: -b.rect.minX, dy: -b.rect.minY)]
        }
        requestRender(s)
        refreshOverlay(s)
        updateClickTargets()
        scheduleDetection(s)
    }

    // MARK: 인식

    private func detector(for s: WindowSession) -> Detector {
        let key = s.kind == .notification ? "#nc" : (s.info.bundleID ?? "#none")
        if let d = detectors[key] { return d }
        // 알림 배너는 어느 앱 알림인지 몰라 전체 적용. 방 이름도 같은 매처로 찾는다
        let people = CoverPolicy.matchTargets(settings: settings, bundleID: s.info.bundleID, notification: s.kind == .notification)
        let d = Detector(matcher: NameMatcher(people: people, mode: settings.recognition.matchMode))
        detectors[key] = d
        return d
    }

    private func scheduleDetection(_ s: WindowSession) {
        guard s.dirty, !s.detecting, s.onScreen else { return }
        let now = CACurrentMediaTime()
        let wait = s.lastDetectionAt + settings.recognition.performance.minRecognitionInterval - now
        if wait > 0 {
            if !s.detectionScheduled {
                s.detectionScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self, weak s] in
                    guard let self, let s else { return }
                    s.detectionScheduled = false
                    self.scheduleDetection(s)
                }
            }
            return
        }
        runDetection(s)
    }

    private final class LineBox {
        private let lock = NSLock()
        private var _ax: [TextLine] = []
        private var _ocr: [TextLine]?
        var ax: [TextLine] { lock.lock(); defer { lock.unlock() }; return _ax }
        var ocr: [TextLine]? { lock.lock(); defer { lock.unlock() }; return _ocr }
        func setAX(_ l: [TextLine]) { lock.lock(); _ax = l; lock.unlock() }
        func setOCR(_ l: [TextLine]) { lock.lock(); _ocr = l; lock.unlock() }
    }

    private func runDetection(_ s: WindowSession) {
        let frame = s.latest
        let rec = settings.recognition
        // 첫 화면이 들어오기 전에 접근성 결과만으로 판단하면 미리 가린 알림이 너무 일찍 풀릴 수 있어 잠시 기다린다
        if rec.useOCR && Permissions.screenCapture && frame == nil && CACurrentMediaTime() - s.createdAt < 2.0 { return }
        let useOCR = rec.useOCR && frame != nil
        let useAX = rec.useAccessibility && Permissions.accessibility
        guard useOCR || useAX else { return }

        s.detecting = true
        s.dirty = false
        let started = CACurrentMediaTime()
        s.lastDetectionAt = started

        let size = frame?.pointSize ?? s.info.frame.size
        let sigAtStart = frame?.signature
        // 이전 인식 이후 화면이 바뀌었나 (안 바뀌었는데 놓친 이름은 잠시 유지)
        var frameChanged = true
        var roi: CGRect?
        if let last = s.lastDetectedSignature, let cur = sigAtStart, s.lastDetectedSize == size {
            let d = ScrollEstimator.compare(prevSig: last, curSig: cur, height: Int(size.height.rounded()))
            frameChanged = d.changed
            // 일부만 바뀌었고(새 메시지 도착 등) 스크롤이 아니면 바뀐 띠만 OCR
            if d.changed, d.shift == nil, Double(d.bandBottom - d.bandTop) < Double(size.height) * 0.5, !s.ocrLines.isEmpty {
                roi = CGRect(x: 0, y: CGFloat(d.bandTop) - 24, width: size.width, height: CGFloat(d.bandBottom - d.bandTop) + 48)
            }
        }
        if !frameChanged && s.everDetected && !s.tracker.blinds.contains(where: { $0.provisional }) {
            // 바뀐 게 없으면 재인식 생략
            s.detecting = false
            return
        }

        // 비동기 클로저에서는 상수만 캡처
        let changedSinceLast = frameChanged
        let ocrROI = roi
        let box = LineBox()
        let group = DispatchGroup()
        if useAX {
            group.enter()
            ax.scan(pid: s.info.pid, windowFrame: s.info.frame) { lines in box.setAX(lines); group.leave() }
        }
        if useOCR, let frame {
            group.enter()
            ocr.recognize(buffer: frame.buffer, pointSize: frame.pointSize, roi: ocrROI) { lines in box.setOCR(lines); group.leave() }
        }
        let previousOCR = s.ocrLines
        let det = detector(for: s)
        let rule = settings.rule(for: s.info.bundleID)
        let kind = s.kind
        let pixels = frame?.pixels
        let hideMentions = rec.hideMentions
        let policy = CoverPolicy(settings: settings)
        group.notify(queue: detectQueue) { [weak self, weak s] in
            let newOCR = box.ocr ?? []
            let ocrLines: [TextLine]
            if let r = ocrROI, box.ocr != nil {
                ocrLines = previousOCR.filter { !$0.frame.intersects(r) } + newOCR
            } else {
                ocrLines = newOCR
            }
            let allLines = box.ax + ocrLines
            let input = DetectionInput(windowSize: size, kind: kind, lines: allLines, image: pixels,
                                       scope: kind == .normal ? (rule?.scope ?? .auto) : .auto,
                                       custom: rule?.custom ?? CustomInsets(), hideMentions: hideMentions)
            // 사람별(목록/대화방/알림, 특정 방, 가림 방식)·방별 규칙 적용
            let titles = CoverPolicy.titleCandidates(from: allLines, windowHeight: size.height)
            let regions = policy.regions(hits: det.detectHits(input), windowKind: kind, windowSize: size,
                                         titles: titles, detector: det)
            DispatchQueue.main.async {
                guard let self, let s else { return }
                self.finishDetection(s, regions: regions, ocrLines: ocrLines, signature: sigAtStart, size: size,
                                     frameChanged: changedSinceLast, started: started)
            }
        }
    }

    private func finishDetection(_ s: WindowSession, regions: [CoverRegion], ocrLines: [TextLine], signature: [Float]?,
                                 size: CGSize, frameChanged: Bool, started: CFTimeInterval) {
        s.detecting = false
        guard sessions[s.id] === s, s.onScreen else { return }
        var adjusted = regions
        // 인식하는 동안 스크롤됐다면 결과를 현재 위치로 옮김
        if let sig = signature, let cur = s.latest, cur.pointSize == size, cur.signature != sig {
            let d = ScrollEstimator.compare(prevSig: sig, curSig: cur.signature, height: cur.pixels.height)
            if let shift = d.shift {
                adjusted = regions.map { r in
                    var r = r
                    if r.rect.midY >= CGFloat(d.bandTop) - 4 && r.rect.midY <= CGFloat(d.bandBottom) + 4 {
                        r.rect = r.rect.offsetBy(dx: 0, dy: CGFloat(-shift))
                    }
                    return r
                }
            }
            s.dirty = true
        }
        s.ocrLines = ocrLines
        s.lastDetectedSignature = signature
        s.lastDetectedSize = size
        s.everDetected = s.everDetected || signature != nil || !settings.recognition.useOCR
        s.tracker.update(with: adjusted, frameChanged: frameChanged, holdPasses: settings.recognition.holdMissedPasses)
        lastRecognitionMS = Int((CACurrentMediaTime() - started) * 1000)
        requestRender(s)
        refreshOverlay(s)
        updateClickTargets()
        if s.dirty { scheduleDetection(s) }
    }

    // MARK: 그리기

    /// 오버레이에 실제로 그릴 영역 (여백·스크롤 고정영역 보정 포함)
    private func displayRect(_ b: TrackedBlind, in s: WindowSession) -> CGRect? {
        let pad = CGFloat(settings.style.padding)
        // 여백: + 바깥으로, − 안쪽으로 (너무 작아지면 최소 4pt 유지)
        // 목록 줄·방 전체·알림 카드는 이미 경계가 정확해 바깥으로는 넓히지 않음 (옆 줄로 삐져나감 방지)
        let tight = b.kind == .row || b.kind == .room || b.kind == .card || b.kind == .provisional
        let p = tight ? min(0, pad) : pad
        var r = b.rect.insetBy(dx: -p, dy: -p)
        if r.width < 4 || r.height < 4 { r = b.rect.insetBy(dx: max(0, (b.rect.width - 4) / 2), dy: max(0, (b.rect.height - 4) / 2)) }
        r = r.intersection(s.windowBounds)
        if !b.provisional, let c = s.tracker.clipToScrollArea(r) { r = c }
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return nil }
        return r
    }

    private func requestRender(_ s: WindowSession) {
        let style = settings.style
        guard style.kind == .mosaic || style.kind == .blur, !s.tracker.isEmpty,
              let frame = s.latest, !s.renderInFlight else { return }
        var rects: [CGRect] = []
        var veils: [RGBA?] = []
        for b in s.tracker.blinds {
            guard let r = displayRect(b, in: s) else { continue }
            rects.append(r)
            veils.append(sampleBackground(r, kind: b.kind, pixels: frame.pixels))
        }
        let key = zip(rects, veils).map { r, v in
            "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height)),\(v?.quantKey ?? 0)"
        }.joined(separator: ";")
        guard s.processedFrame !== frame || s.processedKey != key else { return }
        s.renderInFlight = true
        let scale = CGFloat(CVPixelBufferGetWidth(frame.buffer)) / max(1, frame.pointSize.width)
        let background = style.kind == .blur && style.veilMatchesBackground
            ? frame.pixels.dominantColor(in: frame.pixels.bounds, step: 6) : nil
        renderer.render(buffer: frame.buffer, style: style, scale: scale, background: background, rects: rects, veils: veils) { [weak self, weak s] img in
            guard let self, let s else { return }
            s.renderInFlight = false
            s.processed = img
            s.processedFrame = frame
            s.processedKey = key
            self.refreshOverlay(s)
            self.requestRender(s)   // 그 사이 프레임이나 위치가 바뀌었으면 다시
        }
    }

    private func refreshOverlay(_ s: WindowSession) {
        guard s.onScreen, isActive else { s.overlay.hide(); return }
        let style = settings.style
        let now = Date()
        let liveIDs = Set(s.tracker.blinds.map { $0.id })
        if s.fillCache.count > liveIDs.count { s.fillCache = s.fillCache.filter { liveIDs.contains($0.key) } }
        let blinds: [OverlayBlind] = s.tracker.blinds.compactMap { b in
            guard let r = displayRect(b, in: s) else { return nil }
            var ob = OverlayBlind(id: b.id, rect: r, revealed: b.isRevealed(at: now), provisional: b.provisional)
            ob.label = b.label
            ob.hovered = style.hoverPeek && b.id == hoveredBlind
            ob.passThrough = style.listClickOpens && b.kind == .row
            ob.holes = b.holes.map { $0.offsetBy(dx: b.rect.minX - r.minX, dy: b.rect.minY - r.minY) }
            // 배경색 방식의 채움색, 블러/모자이크가 준비되기 전 바탕색 (회색 대신 주변 배경색)
            if style.kind == .background || style.kind == .blur || style.kind == .mosaic {
                ob.fill = backgroundFill(for: b.id, rect: r, kind: b.kind, in: s, style: style)
            }
            return ob
        }
        // 처리 이미지 크기가 지금 창 크기와 다르면(크기 변경 직후) 쓰지 않음
        var processed: CGImage?
        if let p = s.processed, let f = s.processedFrame, f.pointSize == s.info.frame.size { processed = p }
        s.overlay.targetPID = s.info.pid
        s.overlay.update(frameCG: s.info.frame, level: s.panelLevel, blinds: blinds, occluders: s.occludersLocal,
                         style: style, processed: processed, customImage: customImage,
                         fallback: NSColor(calibratedWhite: 0.82, alpha: 1).cgColor, directClick: !clicks.isRunning)
    }

    /// 배경색 방식: 가림막 바로 바깥 테두리의 가장 흔한 색 + 살짝 대비
    /// 가림막 자리의 배경색.
    /// 목록 줄은 그 줄의 가리지 않은 오른쪽 끝(스크롤 막대 옆)을 읽어, 선택(파랑)·마우스 올림(회색) 색을 그대로 따라감
    private func sampleBackground(_ rect: CGRect, kind: RegionKind, pixels px: PixelImage) -> RGBA {
        if kind == .row {
            let strip = CGRect(x: rect.maxX + 2, y: rect.minY + 3, width: CGFloat(px.width) - rect.maxX - 4, height: rect.height - 6)
            if strip.width >= 3, strip.height >= 3 { return px.dominantColor(in: strip, step: 1) }
        }
        return px.dominantBorderColor(of: rect.insetBy(dx: -3, dy: -3))
    }

    private func backgroundFill(for id: UUID, rect: CGRect, kind: RegionKind, in s: WindowSession, style: BlindStyle) -> CGColor {
        let key = "\(Int(rect.minX))|\(Int(rect.minY))|\(Int(rect.width))|\(Int(rect.height))|\(style.backgroundTint)"
        if let cached = s.fillCache[id], cached.key == key, cached.frame === s.latest { return cached.color }
        var color = NSColor(calibratedWhite: 0.95, alpha: 1).cgColor
        if let px = s.latest?.pixels {
            let c = sampleBackground(rect, kind: kind, pixels: px)
            if c.a >= 16 {
                let r = Double(c.r) / 255, g = Double(c.g) / 255, b = Double(c.b) / 255
                let lum = 0.299 * r + 0.587 * g + 0.114 * b
                // 목록 줄은 줄 배경과 똑같이 (대비를 주면 오른쪽 끝 여백과 색이 달라 보임)
                let t = kind == .row ? 0 : max(0, min(0.3, style.backgroundTint))
                // 밝은 배경은 살짝 어둡게, 어두운 배경은 살짝 밝게
                func adj(_ v: Double) -> CGFloat { CGFloat(lum > 0.5 ? v * (1 - t) : v + (1 - v) * t) }
                color = NSColor(srgbRed: adj(r), green: adj(g), blue: adj(b), alpha: 1).cgColor
            }
        }
        s.fillCache[id] = (key, s.latest, color)
        return color
    }

    /// 마우스 아래 가림막 찾기 (다른 창에 가려진 부분은 제외)
    private func updateHover() {
        guard settings.style.hoverPeek else { hoveredBlind = nil; return }
        let p = ScreenGeometry.cgPoint(fromCocoa: NSEvent.mouseLocation)
        var found: UUID?
        for s in sessions.values where s.onScreen && s.info.frame.contains(p) {
            if s.occludersGlobal.contains(where: { $0.contains(p) }) { continue }
            let local = CGPoint(x: p.x - s.info.frame.minX, y: p.y - s.info.frame.minY)
            for b in s.tracker.blinds.reversed() {
                if let r = displayRect(b, in: s), r.contains(local) { found = b.id; break }
            }
            if found != nil { break }
        }
        hoveredBlind = found
    }

    // MARK: 클릭 공개

    private func ensureClickInterceptor() {
        if !clicks.isRunning && Permissions.accessibility { clicks.start() }
    }

    private func updateClickTargets() {
        guard clicks.isRunning else { return }
        let pad = CGFloat(settings.style.padding)
        var targets: [ClickInterceptor.Target] = []
        for s in sessions.values where s.onScreen && s.overlay.isShown {
            let origin = s.info.frame.origin
            for b in s.tracker.blinds {
                let r = b.rect.insetBy(dx: -pad, dy: -pad).intersection(s.windowBounds)
                guard !r.isNull else { continue }
                var t = ClickInterceptor.Target(windowID: s.id, blindID: b.id, rect: r.offsetBy(dx: origin.x, dy: origin.y),
                                                occluders: s.occludersGlobal)
                t.passThrough = settings.style.listClickOpens && b.kind == .row
                targets.append(t)
            }
        }
        clicks.setTargets(targets)
    }

    func toggleReveal(windowID: CGWindowID, blindID: UUID) {
        guard let s = sessions[windowID] else { return }
        s.tracker.toggleReveal(id: blindID, duration: settings.reveal.interval)
        refreshOverlay(s)
    }

    /// 메뉴에서 "모두 다시 가리기"
    func hideAllRevealed() {
        for s in sessions.values {
            _ = s.tracker.expireReveals()
            for b in s.tracker.blinds where b.revealedUntil != nil { s.tracker.toggleReveal(id: b.id, duration: nil) }
            refreshOverlay(s)
        }
    }

    // MARK: 상태

    private func publishStatus(force: Bool) {
        let now = CACurrentMediaTime()
        guard force || now - lastStatusPublish > 0.5 else { return }
        lastStatusPublish = now
        var st = EngineStatus()
        st.running = isActive
        let visible = sessions.values.filter { $0.onScreen }
        st.windowCount = visible.count
        st.blindCount = visible.reduce(0) { $0 + $1.tracker.blinds.filter { !$0.provisional }.count }
        var names: [String] = []
        for s in visible {
            let n: String
            if s.kind == .notification { n = "macOS 알림" }
            else { n = settings.rule(for: s.info.bundleID)?.displayName ?? s.info.ownerName }
            if !names.contains(n) { names.append(n) }
        }
        st.watchedApps = names
        st.lastRecognitionMS = lastRecognitionMS
        st.clickMode = clicks.isRunning ? "클릭 가로채기" : (Permissions.accessibility ? "-" : "패널 직접 클릭 (손쉬운 사용 권한 필요)")
        onStatus?(st)
    }

    private func loadCustomImage() {
        if let p = settings.style.imagePath, let img = NSImage(contentsOfFile: p) { customImage = img } else { customImage = nil }
    }
}

import AppKit
import CoreGraphics
import QuartzCore
import SmartBlindCore

/// 오버레이에 그릴 가림막 하나
struct OverlayBlind {
    let id: UUID
    /// 창 기준 좌표 (왼쪽 위 원점, 여백 포함)
    let rect: CGRect
    let revealed: Bool
    let provisional: Bool
    /// 배경색 방식일 때 채울 색 (주변 배경에서 뽑음)
    var fill: CGColor? = nil
    /// 가림막 위 대체 글자
    var label: String? = nil
    /// 뚫어 둘 곳 (rect 왼쪽 위 기준)
    var holes: [CGRect] = []
}

/// 감시 중인 창 하나 위에 겹치는 투명 패널. 가림막은 이 패널 안의 레이어로 그린다.
/// - 패널은 마우스를 통과시키고(클릭 공개는 이벤트 탭이 처리), 다른 창에 가려진 부분은 마스크로 잘라낸다.
/// - 나타남/사라짐/공개/위치 이동은 짧은 애니메이션으로 부드럽게 바뀐다.
final class OverlayWindow {
    /// 애니메이션 시간
    static let fadeIn: CFTimeInterval = 0.22
    static let fadeOut: CFTimeInterval = 0.20
    static let move: CFTimeInterval = 0.16
    static let reveal: CFTimeInterval = 0.25

    let panel: NSPanel
    private let host = OverlayView()

    /// 가림막 하나 = 테두리/모양 컨테이너 + 내용(블러 이미지 등)
    private final class BlindLayer {
        let container = CALayer()
        let content = CALayer()
        let label = CATextLayer()
        let shape = CAShapeLayer()
        var contentKey: String?
        var revealed = false
        init() {
            container.masksToBounds = true
            content.contentsGravity = .resize
            container.addSublayer(content)
            label.fontSize = 12
            label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            label.alignmentMode = .left
            label.truncationMode = .end
            label.isWrapped = false
            label.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            container.addSublayer(label)
        }
    }
    private var blindLayers: [UUID: BlindLayer] = [:]
    private let maskLayer = CAShapeLayer()
    private var lastFrame: CGRect = .null
    private var hideWork: DispatchWorkItem?
    private(set) var isShown = false

    /// 이벤트 탭을 못 쓸 때(손쉬운 사용 권한 없음) 패널이 직접 클릭을 받는다. 창 기준 좌표.
    var targetPID: pid_t {
        get { host.targetPID }
        set { host.targetPID = newValue }
    }

    var onDirectClick: ((CGPoint) -> Void)? {
        get { host.onClick }
        set { host.onClick = newValue }
    }

    init() {
        // 테두리 없는 패널은 키/메인 창이 되지 않으므로 포커스를 뺏지 않는다
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isMovable = false
        panel.contentView = host
        host.wantsLayer = true
        host.layer?.masksToBounds = true
    }

    var windowNumber: Int { panel.windowNumber }

    func setDirectClickMode(_ on: Bool) {
        if panel.ignoresMouseEvents == on { panel.ignoresMouseEvents = !on }
    }

    /// 즉시 숨김 (Space 전환, 창이 사라짐 등 — 이전 위치에 남으면 안 되는 경우)
    func hide() {
        hideWork?.cancel()
        hideWork = nil
        guard isShown else { return }
        panel.orderOut(nil)
        isShown = false
        removeAllLayers()
    }

    func close() {
        hide()
        panel.close()
    }

    /// - frameCG: 대상 창 위치 (CG 전역)
    /// - occluders: 대상 창 위에 있는 다른 창들 (창 기준 좌표)
    /// - processed: 창 전체를 모자이크/블러 처리한 이미지 (버퍼 픽셀 크기)
    func update(frameCG: CGRect, level lv: Int, blinds: [OverlayBlind], occluders: [CGRect],
                style: BlindStyle, processed: CGImage?, customImage: NSImage?, fallback: CGColor, directClick: Bool) {
        guard let root = host.layer else { return }
        let H = frameCG.height
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height) }

        // 창 위치/크기·레벨은 애니메이션 없이 즉시 (창을 끌 때 가림막이 뒤처지지 않게)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let cocoa = ScreenGeometry.cocoaRect(fromCG: frameCG)
        let resized = lastFrame.isNull || cocoa.size != lastFrame.size
        if cocoa != lastFrame {
            panel.setFrame(cocoa, display: false)
            lastFrame = cocoa
        }
        let newLevel = NSWindow.Level(rawValue: max(NSWindow.Level.floating.rawValue, lv))
        if panel.level != newLevel { panel.level = newLevel }
        setDirectClickMode(directClick)

        // 다른 창에 가려진 부분 잘라내기
        let bounds = CGRect(x: 0, y: 0, width: frameCG.width, height: H)
        let occ = occluders.map { flip($0) }.filter { $0.intersects(bounds) }
        if occ.isEmpty {
            root.mask = nil
        } else {
            let holes = CGMutablePath()
            for r in occ { holes.addRect(r) }
            maskLayer.frame = bounds
            maskLayer.path = CGPath(rect: bounds, transform: nil).subtracting(holes, using: .winding)
            maskLayer.fillRule = .nonZero
            root.mask = maskLayer
        }
        host.hitRects = directClick ? blinds.map { $0.rect } : []
        CATransaction.commit()

        if blinds.isEmpty {
            fadeOutAll()
            return
        }
        hideWork?.cancel()
        hideWork = nil

        let color = Self.color(hex: style.colorHex)
        let scale = processed.map { CGFloat($0.width) / max(1, frameCG.width) } ?? 1
        var alive = Set<UUID>()

        for b in blinds {
            alive.insert(b.id)
            let target = flip(b.rect)
            let bl: BlindLayer
            var isNew = false
            if let existing = blindLayers[b.id] {
                bl = existing
            } else {
                bl = BlindLayer()
                blindLayers[b.id] = bl
                root.addSublayer(bl.container)
                isNew = true
            }

            // 1) 위치·크기: 새 가림막은 그 자리에서, 기존 것은 부드럽게 이동 (멀리 튀면 즉시)
            let old = bl.container.presentation()?.frame ?? bl.container.frame
            let jump = abs(old.midY - target.midY) > 220 || abs(old.midX - target.midX) > 220
            CATransaction.begin()
            if isNew || resized || jump || old == target {
                CATransaction.setDisableActions(true)
            } else {
                CATransaction.setAnimationDuration(Self.move)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            }
            bl.container.frame = target
            bl.container.cornerRadius = CGFloat(max(0, style.cornerRadius))
            CATransaction.commit()

            // 2) 내용: 블러 이미지 교체는 애니메이션 없이 (프레임마다 바뀜)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bl.content.frame = CGRect(origin: .zero, size: target.size)
            // 뚫어 둘 곳(안 읽은 수 배지): 둥근 모양 + 구멍 마스크
            if b.holes.isEmpty {
                bl.container.mask = nil
            } else {
                let size = target.size
                let path = CGMutablePath()
                let radius = min(CGFloat(max(0, style.cornerRadius)), min(size.width, size.height) / 2)
                path.addRoundedRect(in: CGRect(origin: .zero, size: size), cornerWidth: radius, cornerHeight: radius)
                for h in b.holes {
                    // 위 원점 → 레이어(아래 원점)
                    let hr = CGRect(x: h.minX, y: size.height - h.maxY, width: h.width, height: h.height)
                        .intersection(CGRect(origin: .zero, size: size))
                    if !hr.isNull && hr.width > 1 && hr.height > 1 {
                        path.addRoundedRect(in: hr, cornerWidth: min(hr.height / 2, 9), cornerHeight: min(hr.height / 2, 9))
                    }
                }
                bl.shape.frame = CGRect(origin: .zero, size: size)
                bl.shape.path = path
                bl.shape.fillRule = .evenOdd
                bl.container.mask = bl.shape
            }
            // 대체 글자 (방 이름 등): 가운데 높이, 왼쪽 정렬. 배경 밝기에 맞춰 글자색
            if let text = b.label, !text.isEmpty, target.height >= 18 {
                let dark = Self.isDark(b.fill)
                bl.label.string = text
                bl.label.foregroundColor = (dark ? NSColor(white: 1, alpha: 0.75) : NSColor(white: 0, alpha: 0.55)).cgColor
                let h: CGFloat = 16
                let x: CGFloat = min(16, target.width / 4)
                let holeLeft = b.holes.map { $0.minX }.min() ?? target.width
                let w = max(0, min(target.width - x - 8, holeLeft - x - 8))
                bl.label.frame = CGRect(x: x, y: (target.height - h) / 2, width: w, height: h)
                bl.label.isHidden = b.revealed
            } else {
                bl.label.isHidden = true
            }
            applyContent(bl, blind: b, style: style, processed: processed, scale: scale,
                         customImage: customImage, color: color, fallback: fallback)
            CATransaction.commit()

            // 3) 나타남: 투명 → 설정한 불투명도
            let alpha = Float(min(1, max(0.3, style.opacity)))
            if isNew {
                bl.revealed = b.revealed
                bl.content.opacity = b.revealed ? 0 : 1
                bl.container.borderWidth = (b.revealed && style.showRevealOutline) ? 1 : 0
                Self.animateOpacity(bl.container, from: 0, to: alpha, duration: Self.fadeIn)
            } else if bl.container.animation(forKey: "fade") == nil && abs(bl.container.opacity - alpha) > 0.001 {
                Self.animateOpacity(bl.container, from: bl.container.opacity, to: alpha, duration: Self.fadeIn)
            }
            if !isNew && bl.revealed != b.revealed {
                // 4) 클릭 공개/다시 가림: 내용만 서서히
                bl.revealed = b.revealed
                Self.animateOpacity(bl.content, from: bl.content.presentation()?.opacity ?? bl.content.opacity,
                                    to: b.revealed ? 0 : 1, duration: Self.reveal)
                CATransaction.begin()
                CATransaction.setAnimationDuration(Self.reveal)
                bl.container.borderWidth = (b.revealed && style.showRevealOutline) ? 1 : 0
                CATransaction.commit()
            }
            bl.container.borderColor = NSColor.secondaryLabelColor.withAlphaComponent(0.45).cgColor
            // 직접 클릭 모드에서는 완전 투명이면 클릭이 통과되므로 공개 중에도 아주 옅게 채운다
            bl.container.backgroundColor = (b.revealed && directClick) ? NSColor(white: 1, alpha: 0.02).cgColor : nil
        }

        // 사라진 가림막: 서서히 사라진 뒤 제거
        for (id, bl) in blindLayers where !alive.contains(id) {
            blindLayers[id] = nil
            Self.fadeOutAndRemove(bl.container)
        }

        if !isShown {
            panel.orderFrontRegardless()
            isShown = true
        }
    }

    private func applyContent(_ bl: BlindLayer, blind b: OverlayBlind, style: BlindStyle, processed: CGImage?,
                              scale: CGFloat, customImage: NSImage?, color: CGColor, fallback: CGColor) {
        let layer = bl.content
        switch style.kind {
        case .solid:
            layer.contents = nil
            bl.contentKey = nil
            layer.backgroundColor = color
        case .mosaic, .blur:
            layer.backgroundColor = b.fill ?? fallback
            if let img = processed {
                let key = "\(ObjectIdentifier(img).hashValue)|\(b.rect.integral)"
                if bl.contentKey != key {
                    layer.contents = Self.crop(img, rect: b.rect, scale: scale)
                    bl.contentKey = key
                }
            } else {
                layer.contents = nil
                bl.contentKey = nil
            }
        case .background:
            layer.contents = nil
            bl.contentKey = nil
            layer.backgroundColor = b.fill ?? fallback
        case .image:
            bl.contentKey = nil
            if let img = customImage {
                switch style.imageMode {
                case .fill:
                    layer.contents = img
                    layer.contentsGravity = .resizeAspectFill
                    layer.backgroundColor = color
                case .tile:
                    layer.contents = nil
                    layer.backgroundColor = NSColor(patternImage: img).cgColor
                }
            } else {
                layer.contents = nil
                layer.backgroundColor = color
            }
        }
    }

    /// 끄기/일시정지: 서서히 사라진 뒤 닫힘
    func fadeAwayAndClose() {
        fadeOutAll()
        let p = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeOut + 0.1) { p.orderOut(nil); p.close() }
    }

    /// 모든 가림막을 서서히 지우고, 끝나면 패널을 내림
    private func fadeOutAll() {
        guard isShown else { return }
        for (_, bl) in blindLayers { Self.fadeOutAndRemove(bl.container) }
        blindLayers.removeAll()
        guard hideWork == nil else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.blindLayers.isEmpty else { return }
            self.panel.orderOut(nil)
            self.isShown = false
            self.hideWork = nil
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeOut + 0.05, execute: w)
    }

    private func removeAllLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (_, bl) in blindLayers { bl.container.removeFromSuperlayer() }
        host.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        blindLayers.removeAll()
        CATransaction.commit()
    }

    /// 채움색이 어두운지 (글자색 결정)
    static func isDark(_ c: CGColor?) -> Bool {
        guard let c, let comps = c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components,
              comps.count >= 3 else { return false }
        return 0.299 * comps[0] + 0.587 * comps[1] + 0.114 * comps[2] < 0.5
    }

    static func animateOpacity(_ layer: CALayer, from: Float, to: Float, duration: CFTimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = to
        CATransaction.commit()
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(a, forKey: "fade")
    }

    static func fadeOutAndRemove(_ layer: CALayer) {
        let from = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
        animateOpacity(layer, from: from, to: 0, duration: fadeOut)
        CATransaction.commit()
    }

    static func crop(_ img: CGImage, rect: CGRect, scale: CGFloat) -> CGImage? {
        let px = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            .outwardIntegral
            .intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        guard !px.isNull, px.width >= 1, px.height >= 1 else { return nil }
        return img.cropping(to: px)
    }

    static func color(hex: String) -> CGColor {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return NSColor.gray.cgColor }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1).cgColor
    }
}

/// 직접 클릭 모드용 뷰 (가림막 위 클릭만 받음)
final class OverlayView: NSView {
    var onClick: ((CGPoint) -> Void)?
    var hitRects: [CGRect] = []
    /// 가림막 위 스크롤을 메신저로 넘길 대상 프로세스
    var targetPID: pid_t = 0

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let p = CGPoint(x: local.x, y: bounds.height - local.y)
        return hitRects.contains(where: { $0.contains(p) }) ? self : nil
    }

    /// 직접 클릭 모드에서도 가림막 위 스크롤은 메신저로 그대로 전달
    override func scrollWheel(with event: NSEvent) {
        if targetPID > 0, let cg = event.cgEvent { cg.postToPid(targetPID) }
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        onClick?(CGPoint(x: local.x, y: bounds.height - local.y))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

import AppKit
import CoreGraphics
import QuartzCore

/// 메신저 창 오른쪽에 붙는 작은 켜기/끄기 버튼 (전체 블라인드 ON/OFF)
/// - 위아래로 끌어서 위치를 옮길 수 있고, 위치는 앱별로 기억한다.
final class ToggleButtonPanel {
    static let size: CGFloat = 30
    /// 스크롤 막대 왼쪽에 둠
    static let rightInset: CGFloat = 16 + 8

    let panel: NSPanel
    private let view = ToggleButtonView()
    private(set) var isShown = false

    var onToggle: (() -> Void)? {
        get { view.onToggle }
        set { view.onToggle = newValue }
    }
    /// 끌어서 옮긴 뒤 새 세로 위치 비율 (0 위 ~ 1 아래)
    var onMoved: ((CGFloat) -> Void)? {
        get { view.onMoved }
        set { view.onMoved = newValue }
    }

    init() {
        let s = Self.size
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: s, height: s),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isMovable = false
        panel.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: s, height: s)
        view.wantsLayer = true
    }

    var windowNumber: Int { panel.windowNumber }

    /// - windowFrameCG: 메신저 창 (CG 전역)
    /// - fraction: 세로 위치 비율
    /// - blocked: 다른 창에 가려졌으면 숨김
    func update(windowFrameCG: CGRect, fraction: CGFloat, level: Int, on: Bool, blocked: Bool) {
        guard !blocked, windowFrameCG.width > 120, windowFrameCG.height > 160 else { hide(); return }
        let rect = Self.buttonRect(windowFrameCG: windowFrameCG, fraction: fraction)
        view.windowFrameCG = windowFrameCG
        let cocoa = ScreenGeometry.cocoaRect(fromCG: rect)
        if panel.frame != cocoa { panel.setFrame(cocoa, display: false) }
        let lv = NSWindow.Level(rawValue: max(NSWindow.Level.floating.rawValue, level) + 1)
        if panel.level != lv { panel.level = lv }
        view.setOn(on)
        if !isShown {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            isShown = true
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard isShown else { return }
        panel.orderOut(nil)
        isShown = false
    }

    func close() {
        hide()
        panel.close()
    }

    /// 버튼 위치 (CG 전역)
    static func buttonRect(windowFrameCG f: CGRect, fraction: CGFloat) -> CGRect {
        let s = size
        let minY = f.minY + 60, maxY = f.maxY - 60 - s
        let y = min(max(minY, f.minY + f.height * fraction - s / 2), max(minY, maxY))
        return CGRect(x: f.maxX - rightInset - s, y: y, width: s, height: s)
    }
}

final class ToggleButtonView: NSView {
    var onToggle: (() -> Void)?
    var onMoved: ((CGFloat) -> Void)?
    var windowFrameCG: CGRect = .zero

    private var on = true
    private var hovering = false
    private var dragStart: NSPoint?
    private var dragged = false
    private var tracking: NSTrackingArea?
    private let icon = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = ToggleButtonPanel.size / 2
        layer?.borderWidth = 0.5
        layer?.addSublayer(icon)
        toolTip = "SmartBlind 켜기/끄기 (끌어서 위치 이동)"
        refresh(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let s: CGFloat = 16
        icon.frame = CGRect(x: (bounds.width - s) / 2, y: (bounds.height - s) / 2, width: s, height: s)
    }

    func setOn(_ value: Bool) {
        guard value != on else { return }
        on = value
        refresh(animated: true)
    }

    private func refresh(animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.25 : 0)
        CATransaction.setDisableActions(!animated)
        let base = on ? NSColor(calibratedWhite: 0.15, alpha: hovering ? 0.85 : 0.6)
                      : NSColor(calibratedWhite: 1.0, alpha: hovering ? 0.95 : 0.8)
        layer?.backgroundColor = base.cgColor
        layer?.borderColor = NSColor(calibratedWhite: 0.5, alpha: 0.35).cgColor
        let name = on ? "eye.slash.fill" : "eye"
        let tint = on ? NSColor.white : NSColor(calibratedWhite: 0.25, alpha: 1)
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)) {
            icon.contents = Self.tinted(img, tint)
            icon.contentsGravity = .resizeAspect
        }
        CATransaction.commit()
    }

    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        let img = NSImage(size: image.size)
        img.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        img.unlockFocus()
        return img
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refresh(animated: true) }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh(animated: true) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let win = window else { return }
        let now = NSEvent.mouseLocation
        if !dragged && abs(now.y - start.y) < 4 { return }
        dragged = true
        var f = win.frame
        f.origin.y += now.y - start.y
        dragStart = now
        win.setFrame(f, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        if dragged, let win = window, windowFrameCG.height > 0 {
            // Cocoa → CG 로 바꿔 창 안에서의 세로 비율 저장
            let cgCenterY = ScreenGeometry.primaryHeight - win.frame.midY
            let fraction = (cgCenterY - windowFrameCG.minY) / windowFrameCG.height
            onMoved?(min(0.95, max(0.05, fraction)))
            dragged = false
            return
        }
        onToggle?()
    }
}

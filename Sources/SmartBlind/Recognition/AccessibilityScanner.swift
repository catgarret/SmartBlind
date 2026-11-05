import AppKit
import ApplicationServices
import SmartBlindCore

/// 손쉬운 사용(Accessibility) 트리에서 메신저 창의 글자와 위치를 읽는다.
/// OCR보다 빠르고 정확하며, 행/셀/말풍선 같은 UI 묶음 영역도 알 수 있다.
/// (앱이 접근성 정보를 제공하지 않으면 빈 결과 → OCR이 대신함)
final class AccessibilityScanner {
    private let queue = DispatchQueue(label: "smartblind.ax", qos: .userInitiated)
    private var manualEnabled = Set<pid_t>()
    private let lock = NSLock()

    private static let attributes: CFArray = [
        kAXRoleAttribute as String, kAXValueAttribute as String, kAXTitleAttribute as String,
        kAXDescriptionAttribute as String, kAXPositionAttribute as String, kAXSizeAttribute as String,
        kAXChildrenAttribute as String,
    ] as CFArray

    private static let textRoles: Set<String> = [
        "AXStaticText", "AXTextField", "AXTextArea", "AXHeading", "AXLink", "AXButton", "AXCell", "AXImage", "AXMenuButton",
    ]
    private static let containerRoles: Set<String> = ["AXRow", "AXCell", "AXGroup", "AXListItem", "AXOutlineRow"]

    /// - windowFrame: CG 전역 좌표
    /// - completion: AX 큐에서 호출, 창 기준 좌표
    func scan(pid: pid_t, windowFrame: CGRect, completion: @escaping ([TextLine]) -> Void) {
        queue.async { [weak self] in
            guard let self, AXIsProcessTrusted() else { completion([]); return }
            completion(self.scanSync(pid: pid, windowFrame: windowFrame))
        }
    }

    private func scanSync(pid: pid_t, windowFrame: CGRect) -> [TextLine] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        lock.lock()
        let needManual = !manualEnabled.contains(pid)
        if needManual { manualEnabled.insert(pid) }
        lock.unlock()
        if needManual {
            // Electron 기반 메신저(Slack, Discord, Teams 등)는 이 값을 켜야 접근성 트리를 만든다
            _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return [] }
        guard let window = windows.first(where: { w in
            guard let f = Self.frame(of: w) else { return false }
            return abs(f.minX - windowFrame.minX) < 6 && abs(f.minY - windowFrame.minY) < 6
                && abs(f.width - windowFrame.width) < 8 && abs(f.height - windowFrame.height) < 8
        }) else { return [] }

        var lines: [TextLine] = []
        let start = Date()
        var visited = 0
        // (요소, 깊이, 가장 가까운 묶음 영역, 스크롤 영역 잘림)
        var stack: [(AXUIElement, Int, CGRect?, CGRect)] = [(window, 0, nil, windowFrame)]
        while let item = stack.popLast() {
            let (el, depth, container, clip) = item
            visited += 1
            if visited > 4000 || Date().timeIntervalSince(start) > 0.15 { break }
            guard let info = Self.read(el) else { continue }
            let frame = info.frame
            var nextClip = clip
            var nextContainer = container
            if let f = frame {
                if info.role == "AXScrollArea" || info.role == "AXList" || info.role == "AXTable" || info.role == "AXOutline" {
                    nextClip = clip.intersection(f)
                }
                if Self.containerRoles.contains(info.role), f.height <= 220, f.width >= 20 {
                    nextContainer = f
                }
                if Self.textRoles.contains(info.role) {
                    for text in [info.value, info.title, info.desc].compactMap({ $0 }) where !text.isEmpty && text.count <= 400 {
                        let visible = f.intersection(clip)
                        guard !visible.isNull, visible.width * visible.height >= 0.6 * f.width * f.height else { continue }
                        let local = f.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY)
                        let localContainer = (nextContainer ?? container)?.intersection(clip)
                            .offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY)
                        // 여러 줄 텍스트는 줄별 위치를 알 수 없으므로 첫 줄 이름 판별에만 쓰이도록 그대로 둔다
                        lines.append(TextLine(text: text.replacingOccurrences(of: "\n", with: " "), frame: local,
                                              source: .accessibility, container: localContainer, subrangeResolver: nil))
                        break
                    }
                }
                // 창 밖이거나 잘린 영역 밖이면 자식도 볼 필요 없음
                if f.intersection(nextClip).isNull && depth > 1 { continue }
            }
            if depth < 40 {
                for child in info.children.reversed() { stack.append((child, depth + 1, nextContainer, nextClip)) }
            }
        }
        return lines
    }

    private struct ElementInfo {
        var role: String
        var value: String?
        var title: String?
        var desc: String?
        var frame: CGRect?
        var children: [AXUIElement]
    }

    private static func read(_ el: AXUIElement) -> ElementInfo? {
        var valuesRef: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(el, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &valuesRef)
        guard err == .success, let values = valuesRef as? [AnyObject], values.count == 7 else { return nil }
        func string(_ o: AnyObject) -> String? {
            if let s = o as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let a = o as? NSAttributedString { return a.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            return nil
        }
        var point = CGPoint.zero, size = CGSize.zero
        var hasPoint = false, hasSize = false
        if CFGetTypeID(values[4]) == AXValueGetTypeID() {
            let v = values[4] as! AXValue
            if AXValueGetType(v) == .cgPoint { hasPoint = AXValueGetValue(v, .cgPoint, &point) }
        }
        if CFGetTypeID(values[5]) == AXValueGetTypeID() {
            let v = values[5] as! AXValue
            if AXValueGetType(v) == .cgSize { hasSize = AXValueGetValue(v, .cgSize, &size) }
        }
        let frame = (hasPoint && hasSize && size.width > 0 && size.height > 0) ? CGRect(origin: point, size: size) : nil
        return ElementInfo(role: string(values[0]) ?? "", value: string(values[1]), title: string(values[2]),
                           desc: string(values[3]), frame: frame, children: (values[6] as? [AXUIElement]) ?? [])
    }

    private static func frame(of el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        _ = AXValueGetValue(posRef as! AXValue, .cgPoint, &p)
        _ = AXValueGetValue(sizeRef as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }
}

import AppKit
import CoreGraphics

/// 화면에 보이는 창 하나 (CGWindowList 기준)
struct WindowInfo: Equatable {
    let id: CGWindowID
    let pid: pid_t
    let ownerName: String
    let bundleID: String?
    /// CG 전역 좌표
    let frame: CGRect
    let layer: Int
    let alpha: Double
}

/// 현재 화면의 창 목록 (앞 → 뒤 순서)
final class WindowCatalog {
    private var bundleCache: [pid_t: String] = [:]
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// 우리 앱의 오버레이 창 번호 (가림 계산에서 제외)
    var overlayWindowNumbers: Set<CGWindowID> = []

    func snapshot() -> [WindowInfo] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [WindowInfo] = []
        out.reserveCapacity(list.count)
        for d in list {
            guard let num = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pidNum = d[kCGWindowOwnerPID as String] as? NSNumber,
                  let boundsDict = d[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            if overlayWindowNumbers.contains(num) { continue }
            let pid = pidNum.int32Value
            let layer = (d[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let alpha = (d[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            let owner = d[kCGWindowOwnerName as String] as? String ?? ""
            out.append(WindowInfo(id: num, pid: pid, ownerName: owner, bundleID: bundleID(for: pid),
                                  frame: frame, layer: layer, alpha: alpha))
        }
        return out
    }

    func bundleID(for pid: pid_t) -> String? {
        if let b = bundleCache[pid] { return b.isEmpty ? nil : b }
        let b = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        bundleCache[pid] = b
        return b.isEmpty ? nil : b
    }

    func forget(pid: pid_t) { bundleCache[pid] = nil }

    var ownProcessID: pid_t { ownPID }
}

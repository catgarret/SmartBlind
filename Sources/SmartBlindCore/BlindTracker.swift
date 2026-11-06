import Foundation
#if canImport(CoreGraphics)
import CoreGraphics   // macOS: CGRect 기하 함수(minX, union 등)는 CoreGraphics에 있음
#endif

/// 화면에 유지되는 가림막 하나
public struct TrackedBlind: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var personID: UUID?
    /// 창 기준 좌표
    public var rect: CGRect
    public var kind: RegionKind
    /// nil = 가림 상태. 값이 있으면 그 시각까지 공개 (distantFuture = 직접 닫을 때까지)
    public var revealedUntil: Date?
    /// 연속으로 인식에서 빠진 횟수
    public var misses: Int
    /// 새 알림 창을 인식 전까지 미리 가린 임시 가림막
    public var provisional: Bool

    public func isRevealed(at now: Date) -> Bool {
        guard let u = revealedUntil else { return false }
        return u > now
    }
}

/// 창 하나의 가림막 목록을 인식 결과에 맞춰 갱신·추적한다. (메인 스레드에서 사용)
public final class BlindTracker {
    public private(set) var blinds: [TrackedBlind] = []
    public var windowSize: CGSize

    /// 스크롤되는 영역 (y 범위). 스크롤 중 바뀌지 않는 위쪽 고정 영역(공지, 제목줄 등)은 가리지 않도록 잘라내는 데 씀
    public private(set) var scrollArea: ClosedRange<CGFloat>?

    public init(windowSize: CGSize) { self.windowSize = windowSize }

    /// 스크롤 영역 안에서 감지된 가림막이 위쪽 고정 영역(공지·제목줄)으로 넘치지 않게 윗부분만 자름.
    /// (아래쪽은 입력창 크기에 따라 계속 바뀌므로 자르지 않음)
    public func clipToScrollArea(_ r: CGRect) -> CGRect? {
        guard let a = scrollArea, r.midY >= a.lowerBound else { return r }
        let top = max(r.minY, a.lowerBound)
        guard r.maxY - top >= 2 else { return nil }
        return CGRect(x: r.minX, y: top, width: r.width, height: r.maxY - top)
    }

    /// 창 크기가 바뀌면 고정 영역 정보도 다시 배움
    public func resetScrollArea() { scrollArea = nil }

    public var isEmpty: Bool { blinds.isEmpty }

    /// 스크롤 추정값으로 바뀐 구간 안의 가림막을 즉시 이동
    public func applyShift(_ shift: Int, bandTop: Int, bandBottom: Int) {
        guard shift != 0 else { return }
        scrollArea = CGFloat(bandTop)...CGFloat(bandBottom)
        let bounds = CGRect(origin: .zero, size: windowSize)
        blinds = blinds.compactMap { b in
            guard !b.provisional else { return b }
            let mid = b.rect.midY
            guard mid >= CGFloat(bandTop) - 4 && mid <= CGFloat(bandBottom) + 4 else { return b }
            var nb = b
            // 이동 후 고정 영역(위 공지·제목줄)으로 넘어간 부분은 잘라냄
            guard let moved = clipToScrollArea(b.rect.offsetBy(dx: 0, dy: CGFloat(-shift))) else { return nil }
            nb.rect = moved
            return nb.rect.intersects(bounds) ? nb : nil
        }
    }

    /// 인식 결과 반영.
    /// - frameChanged: 이전 인식 이후 화면이 바뀌었는지. 바뀌었는데 안 보이면 즉시 제거, 그대로인데 놓쳤으면 잠시 유지.
    public func update(with regions: [CoverRegion], frameChanged: Bool, holdPasses: Int) {
        var old = blinds.filter { !$0.provisional }
        var next: [TrackedBlind] = []
        let regions = regions.compactMap { r -> CoverRegion? in
            guard let c = clipToScrollArea(r.rect) else { return nil }
            var r = r; r.rect = c; return r
        }
        for r in regions {
            var bestIndex: Int?
            var bestScore: CGFloat = 0
            for (i, b) in old.enumerated() where b.personID == r.personID {
                let s = Self.similarity(b.rect, r.rect)
                if s > bestScore { bestScore = s; bestIndex = i }
            }
            if let i = bestIndex, bestScore >= 0.25 {
                var b = old.remove(at: i)
                b.rect = r.rect
                b.kind = r.kind
                b.misses = 0
                next.append(b)
            } else {
                next.append(TrackedBlind(id: UUID(), personID: r.personID, rect: r.rect, kind: r.kind,
                                         revealedUntil: nil, misses: 0, provisional: false))
            }
        }
        if !frameChanged {
            for var b in old where b.misses < holdPasses {
                b.misses += 1
                next.append(b)
            }
        }
        blinds = next
    }

    /// 새 팝업 창 전체를 인식 전까지 가림
    public func addProvisional(_ rect: CGRect) {
        guard !blinds.contains(where: { $0.provisional }) else { return }
        blinds.append(TrackedBlind(id: UUID(), personID: nil, rect: rect, kind: .provisional,
                                   revealedUntil: nil, misses: 0, provisional: true))
    }

    public func removeAll() { blinds.removeAll() }

    /// 클릭 공개/다시 가림
    @discardableResult
    public func toggleReveal(id: UUID, duration: TimeInterval?, now: Date = Date()) -> Bool {
        guard let i = blinds.firstIndex(where: { $0.id == id }) else { return false }
        if blinds[i].isRevealed(at: now) {
            blinds[i].revealedUntil = nil
        } else {
            blinds[i].revealedUntil = duration.map { now.addingTimeInterval($0) } ?? .distantFuture
        }
        return true
    }

    /// 공개 시간이 끝난 가림막을 다시 가림. 바뀐 게 있으면 true
    public func expireReveals(now: Date = Date()) -> Bool {
        var changed = false
        for i in blinds.indices {
            if let u = blinds[i].revealedUntil, u <= now { blinds[i].revealedUntil = nil; changed = true }
        }
        return changed
    }

    public var nextRevealExpiry: Date? {
        blinds.compactMap { $0.revealedUntil }.filter { $0 != .distantFuture }.min()
    }

    public func hit(_ point: CGPoint) -> TrackedBlind? {
        blinds.last { $0.rect.contains(point) }
    }

    /// IoU 또는 중심 거리 기반 유사도 (0~1)
    static func similarity(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        let iou: CGFloat
        if inter.isNull || inter.isEmpty { iou = 0 } else {
            let i = inter.width * inter.height
            iou = i / (a.width * a.height + b.width * b.height - i)
        }
        let d = hypot(a.midX - b.midX, a.midY - b.midY)
        let near = max(0, 1 - d / max(30, min(a.height, b.height) * 0.6))
        return max(iou, near * 0.5)
    }
}

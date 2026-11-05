import Foundation
#if canImport(CoreGraphics)
import CoreGraphics   // macOS: CGRect 기하 함수(minX, union 등)는 CoreGraphics에 있음
#endif

/// 두 프레임 비교 결과
public struct FrameDiff: Equatable, Sendable {
    public var changed: Bool
    /// 바뀐 행 범위 (창 기준 y, pt)
    public var bandTop: Int
    public var bandBottom: Int
    /// 내용이 위로 이동한 양 (아래로 스크롤하면 +). 가림막은 y -= shift. 추정 불가면 nil
    public var shift: Int?
    /// 바뀐 행 비율 (0~1)
    public var changedFraction: Double

    public static let unchanged = FrameDiff(changed: false, bandTop: 0, bandBottom: 0, shift: nil, changedFraction: 0)
}

/// 행 단위 특징으로 화면 변화와 스크롤 이동량을 빠르게 추정한다.
/// OCR이 끝나기 전에 기존 가림막을 예상 위치로 옮겨 순간 노출을 줄이는 데 쓴다.
public enum ScrollEstimator {
    static let buckets = 16

    /// 각 행을 16칸 평균 밝기로 요약
    public static func rowSignatures(_ img: PixelImage) -> [Float] {
        let w = img.width, h = img.height
        var sig = [Float](repeating: 0, count: h * buckets)
        guard w >= buckets else { return sig }
        let bw = w / buckets
        for y in 0..<h {
            for b in 0..<buckets {
                var s = 0
                let x0 = b * bw
                var x = x0
                while x < x0 + bw { s += img.luminance(x, y); x += 2 }
                sig[y * buckets + b] = Float(s) / Float(max(1, (bw + 1) / 2))
            }
        }
        return sig
    }

    @inline(__always)
    static func rowDistance(_ a: [Float], _ ya: Int, _ b: [Float], _ yb: Int) -> Float {
        var d: Float = 0
        let ia = ya * buckets, ib = yb * buckets
        for k in 0..<buckets { d += abs(a[ia + k] - b[ib + k]) }
        return d / Float(buckets)
    }

    public static func compare(prev: PixelImage, cur: PixelImage) -> FrameDiff {
        guard prev.width == cur.width, prev.height == cur.height, cur.height > 4 else {
            return FrameDiff(changed: true, bandTop: 0, bandBottom: cur.height, shift: nil, changedFraction: 1)
        }
        return compare(prevSig: rowSignatures(prev), curSig: rowSignatures(cur), height: cur.height)
    }

    public static func compare(prevSig: [Float], curSig: [Float], height h: Int) -> FrameDiff {
        guard prevSig.count == curSig.count, prevSig.count == h * buckets else {
            return FrameDiff(changed: true, bandTop: 0, bandBottom: h, shift: nil, changedFraction: 1)
        }
        var top = -1, bottom = -1, changedRows = 0
        for y in 0..<h where rowDistance(prevSig, y, curSig, y) > 1.0 {
            if top < 0 { top = y }
            bottom = y
            changedRows += 1
        }
        guard top >= 0 else { return .unchanged }
        let band = bottom - top + 1
        var diff = FrameDiff(changed: true, bandTop: top, bandBottom: bottom + 1, shift: nil,
                             changedFraction: Double(changedRows) / Double(h))
        guard band >= 24 else { return diff }

        // cur[y] ≈ prev[y + s] 를 만족하는 s 탐색 (행 2칸 간격 샘플)
        let maxS = min(Int(Double(band) * 0.85), 900)
        func cost(_ s: Int) -> (Float, Int) {
            var total: Float = 0, n = 0
            var y = top
            while y <= bottom {
                let py = y + s
                if py >= 0 && py < h { total += rowDistance(curSig, y, prevSig, py); n += 1 }
                y += 2
            }
            return (n > 0 ? total / Float(n) : .infinity, n)
        }
        let base = cost(0).0
        var bestS = 0
        var best = base
        let minOverlap = max(10, band / 6)
        var s = -maxS
        while s <= maxS {
            if s != 0 {
                let (c, n) = cost(s)
                if n >= minOverlap && c < best { best = c; bestS = s }
            }
            s += 1
        }
        if bestS != 0 && best < base * 0.4 && best < 6 {
            diff.shift = bestS
        }
        return diff
    }
}

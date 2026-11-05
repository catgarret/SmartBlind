import Foundation
#if canImport(CoreGraphics)
import CoreGraphics   // macOS: CGRect 기하 함수(minX, union 등)는 CoreGraphics에 있음
#endif

/// 분석용 RGBA8 이미지. 1픽셀 = 1pt (창 기준 좌표, 왼쪽 위 원점).
public struct PixelImage: Sendable {
    public let width: Int
    public let height: Int
    /// RGBA, 위쪽 행부터
    public var data: [UInt8]

    public init(width: Int, height: Int, data: [UInt8]) {
        precondition(data.count >= width * height * 4, "PixelImage: data too small")
        self.width = width
        self.height = height
        self.data = data
    }

    public init(width: Int, height: Int, fill: RGBA = RGBA(255, 255, 255, 255)) {
        self.width = width
        self.height = height
        var d = [UInt8](repeating: 0, count: width * height * 4)
        var i = 0
        while i < d.count { d[i] = fill.r; d[i + 1] = fill.g; d[i + 2] = fill.b; d[i + 3] = fill.a; i += 4 }
        self.data = d
    }

    @inline(__always)
    public func pixel(_ x: Int, _ y: Int) -> RGBA {
        let i = (y * width + x) * 4
        return RGBA(data[i], data[i + 1], data[i + 2], data[i + 3])
    }

    @inline(__always)
    public func luminance(_ x: Int, _ y: Int) -> Int {
        let i = (y * width + x) * 4
        return (Int(data[i]) * 77 + Int(data[i + 1]) * 150 + Int(data[i + 2]) * 29) >> 8
    }

    public var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    /// 투명 픽셀(알파 < 16)이 의미 있게 있는지 (알림 배너처럼 카드 바깥이 투명한 창)
    public var hasTransparency: Bool {
        var count = 0
        let step = max(1, (width * height) / 4000)
        var p = 0
        while p < width * height {
            if data[p * 4 + 3] < 16 { count += 1; if count > 20 { return true } }
            p += step
        }
        return false
    }

    /// 사각형 안의 가장 흔한 색 (배경색 추정). 4비트 양자화.
    public func dominantColor(in rect: CGRect, step: Int = 2) -> RGBA {
        let r = clampedIntRect(rect)
        guard r.w > 0, r.h > 0 else { return RGBA(255, 255, 255, 255) }
        var counts: [Int: Int] = [:]
        var best = 0, bestKey = 0
        var y = r.y
        while y < r.y + r.h {
            var x = r.x
            while x < r.x + r.w {
                let key = pixel(x, y).quantKey
                let c = (counts[key] ?? 0) + 1
                counts[key] = c
                if c > best { best = c; bestKey = key }
                x += step
            }
            y += step
        }
        return averageColor(ofKey: bestKey, in: r, step: step)
    }

    /// 양자화 칸이 같은 픽셀들의 실제 평균색 (칸 중앙값을 쓰면 미세한 색 차이를 놓침)
    func averageColor(ofKey key: Int, in r: IntRect, step: Int) -> RGBA {
        if key < 0 { return RGBA(0, 0, 0, 0) }
        var sr = 0, sg = 0, sb = 0, n = 0
        var y = r.y
        while y < r.y + r.h {
            var x = r.x
            while x < r.x + r.w {
                let p = pixel(x, y)
                if p.quantKey == key { sr += Int(p.r); sg += Int(p.g); sb += Int(p.b); n += 1 }
                x += step
            }
            y += step
        }
        guard n > 0 else { return RGBA(quantKey: key) }
        return RGBA(UInt8(sr / n), UInt8(sg / n), UInt8(sb / n), 255)
    }

    /// 사각형 테두리 픽셀의 가장 흔한 색
    public func dominantBorderColor(of rect: CGRect) -> RGBA {
        let r = clampedIntRect(rect)
        guard r.w > 1, r.h > 1 else { return RGBA(255, 255, 255, 255) }
        var counts: [Int: Int] = [:]
        func add(_ x: Int, _ y: Int) { counts[pixel(x, y).quantKey, default: 0] += 1 }
        for x in r.x..<(r.x + r.w) { add(x, r.y); add(x, r.y + r.h - 1) }
        for y in r.y..<(r.y + r.h) { add(r.x, y); add(r.x + r.w - 1, y) }
        let key = counts.max { $0.value < $1.value }?.key ?? RGBA(255, 255, 255, 255).quantKey
        // 테두리 픽셀 중 같은 칸의 평균
        var sr = 0, sg = 0, sb = 0, n = 0
        func acc(_ x: Int, _ y: Int) {
            let p = pixel(x, y)
            if p.quantKey == key { sr += Int(p.r); sg += Int(p.g); sb += Int(p.b); n += 1 }
        }
        for x in r.x..<(r.x + r.w) { acc(x, r.y); acc(x, r.y + r.h - 1) }
        for y in r.y..<(r.y + r.h) { acc(r.x, y); acc(r.x + r.w - 1, y) }
        if key < 0 || n == 0 { return RGBA(quantKey: key) }
        return RGBA(UInt8(sr / n), UInt8(sg / n), UInt8(sb / n), 255)
    }

    public struct IntRect: Equatable, Sendable { public var x, y, w, h: Int }

    public func clampedIntRect(_ rect: CGRect) -> IntRect {
        let x0 = max(0, min(width, Int(rect.minX.rounded(.down))))
        let y0 = max(0, min(height, Int(rect.minY.rounded(.down))))
        let x1 = max(0, min(width, Int(rect.maxX.rounded(.up))))
        let y1 = max(0, min(height, Int(rect.maxY.rounded(.up))))
        return IntRect(x: x0, y: y0, w: max(0, x1 - x0), h: max(0, y1 - y0))
    }

    /// 부분 이미지 (테스트·디버그용)
    public func cropped(_ rect: CGRect) -> PixelImage {
        let r = clampedIntRect(rect)
        var d = [UInt8](repeating: 0, count: max(0, r.w * r.h * 4))
        for yy in 0..<r.h {
            let src = ((r.y + yy) * width + r.x) * 4
            let dst = yy * r.w * 4
            for k in 0..<(r.w * 4) { d[dst + k] = data[src + k] }
        }
        return PixelImage(width: r.w, height: r.h, data: d)
    }
}

public struct RGBA: Equatable, Sendable {
    public var r, g, b, a: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) { self.r = r; self.g = g; self.b = b; self.a = a }

    /// 투명이면 하나의 키로 묶음
    public var quantKey: Int {
        if a < 16 { return -1 }
        return (Int(r >> 4) << 8) | (Int(g >> 4) << 4) | Int(b >> 4)
    }

    public init(quantKey k: Int) {
        if k < 0 { self.init(0, 0, 0, 0); return }
        self.init(UInt8(((k >> 8) & 0xF) << 4 | 0x8), UInt8(((k >> 4) & 0xF) << 4 | 0x8), UInt8((k & 0xF) << 4 | 0x8), 255)
    }

    /// 두 색의 차이 (채널 최대 차 + 알파 차)
    @inline(__always)
    public func distance(_ o: RGBA) -> Int {
        if a < 16 && o.a < 16 { return 0 }
        if (a < 16) != (o.a < 16) { return 255 }
        let dr = abs(Int(r) - Int(o.r)), dg = abs(Int(g) - Int(o.g)), db = abs(Int(b) - Int(o.b))
        return max(dr, max(dg, db))
    }
}

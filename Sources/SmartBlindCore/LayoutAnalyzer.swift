import Foundation
#if canImport(CoreGraphics)
import CoreGraphics   // macOS: CGRect 기하 함수(minX, union 등)는 CoreGraphics에 있음
#endif

/// 감시하는 창의 종류
public enum WindowKind: String, Sendable {
    /// 메신저 본 창 (친구 목록, 채팅 목록, 대화창)
    case normal
    /// 메신저가 띄우는 자체 토스트/작은 알림 창
    case toast
    /// macOS 알림 센터 배너
    case notification
}

public enum RegionKind: String, Sendable {
    case name, nameAvatar, block, row, line, card, custom, container, provisional
}

/// 가려야 할 영역 (창 기준 좌표)
public struct CoverRegion: Equatable, Sendable {
    public var personID: UUID?
    public var rect: CGRect
    public var kind: RegionKind

    public init(personID: UUID?, rect: CGRect, kind: RegionKind) {
        self.personID = personID
        self.rect = rect
        self.kind = kind
    }
}

/// 픽셀과 글자 위치로 "이 이름과 연결된 UI 영역"을 계산한다.
///
/// 원칙: 확신이 없으면 이름만 가린다 (관련 없는 사람 메시지를 가리지 않도록).
public struct LayoutAnalyzer {
    public let image: PixelImage?
    public let size: CGSize

    /// 배경과 다르다고 볼 색 차이
    static let contentThreshold = 26

    public init(image: PixelImage?, size: CGSize) {
        self.image = image
        self.size = size
    }

    // MARK: 프로필 사진

    /// 이름 왼쪽의 프로필 사진(정사각형/원형 덩어리)을 찾는다.
    public func detectAvatar(nextTo name: CGRect) -> CGRect? {
        guard let img = image else { return nil }
        let h = max(8, name.height)
        let x0 = max(0, name.minX - 6 * h)
        let x1 = name.minX - 2
        guard x1 - x0 >= 1.3 * h else { return nil }
        let search = CGRect(x: x0, y: max(0, name.minY - 3 * h), width: x1 - x0,
                            height: min(CGFloat(img.height), name.maxY + 3 * h) - max(0, name.minY - 3 * h))
        let r = img.clampedIntRect(search)
        guard r.w > 4, r.h > 4 else { return nil }
        let bg = img.dominantBorderColor(of: search)

        // 배경과 다른 픽셀 마스크
        var mask = [Bool](repeating: false, count: r.w * r.h)
        for yy in 0..<r.h {
            for xx in 0..<r.w where img.pixel(r.x + xx, r.y + yy).distance(bg) > Self.contentThreshold {
                mask[yy * r.w + xx] = true
            }
        }
        // 연결 요소 (4방향)
        var label = [Int](repeating: -1, count: mask.count)
        var boxes: [(minX: Int, minY: Int, maxX: Int, maxY: Int, count: Int)] = []
        var stack: [Int] = []
        for start in 0..<mask.count where mask[start] && label[start] < 0 {
            let id = boxes.count
            var b = (minX: Int.max, minY: Int.max, maxX: Int.min, maxY: Int.min, count: 0)
            label[start] = id
            stack.append(start)
            while let p = stack.popLast() {
                let px = p % r.w, py = p / r.w
                b.minX = min(b.minX, px); b.maxX = max(b.maxX, px)
                b.minY = min(b.minY, py); b.maxY = max(b.maxY, py)
                b.count += 1
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = px + dx, ny = py + dy
                    guard nx >= 0, ny >= 0, nx < r.w, ny < r.h else { continue }
                    let q = ny * r.w + nx
                    if mask[q] && label[q] < 0 { label[q] = id; stack.append(q) }
                }
            }
            boxes.append(b)
        }
        // 가까운 조각 합치기 (사진 속 흰 부분 때문에 쪼개진 경우)
        var merged: [CGRect] = boxes.filter { $0.count >= 4 }.map {
            CGRect(x: $0.minX, y: $0.minY, width: $0.maxX - $0.minX + 1, height: $0.maxY - $0.minY + 1)
        }
        var changed = true
        while changed {
            changed = false
            outer: for i in 0..<merged.count {
                for j in (i + 1)..<merged.count where merged[i].insetBy(dx: -3, dy: -3).intersects(merged[j]) {
                    merged[i] = merged[i].union(merged[j])
                    merged.remove(at: j)
                    changed = true
                    break outer
                }
            }
        }
        let nameLocal = name.offsetBy(dx: -CGFloat(r.x), dy: -CGFloat(r.y))
        var best: CGRect?
        for b in merged {
            let w = b.width, hh = b.height
            guard w >= 1.5 * h, hh >= 1.5 * h, w <= 6.5 * h, hh <= 6.5 * h else { continue }
            let aspect = w / hh
            guard aspect >= 0.7, aspect <= 1.45 else { continue }
            guard b.maxX >= nameLocal.minX - 2.4 * h else { continue }         // 이름 바로 왼쪽
            guard abs(b.minY - nameLocal.minY) <= 2.4 * h else { continue }     // 윗선이 이름과 비슷
            if best == nil || b.width * b.height > best!.width * best!.height { best = b }
        }
        guard let b = best?.offsetBy(dx: CGFloat(r.x), dy: CGFloat(r.y)) else { return nil }
        // 사진 속 밝은 가장자리 때문에 덜 잡히는 경우가 있어 정사각형으로 맞추고 2pt 넓힌다
        let side = max(b.width, b.height)
        return CGRect(x: b.midX - side / 2, y: b.midY - side / 2, width: side, height: side)
            .insetBy(dx: -2, dy: -2)
            .intersection(img.bounds)
    }

    // MARK: 말풍선/목록 블록

    /// 프로필 사진 + 이름 아래로 이어지는 같은 사람의 내용(말풍선, 사진, 이모티콘, 목록 미리보기)을 찾는다.
    /// 다음 사람의 프로필 사진이 나오거나, 이름 열에서 내용이 끊기면 멈춘다.
    public func expandBlock(name: CGRect, avatar: CGRect) -> (rect: CGRect, listLike: Bool) {
        guard let img = image else { return (name.union(avatar), false) }
        let h = max(8, name.height)
        let W = img.width, H = img.height
        // 배경: 프로필 사진 열의 아래쪽
        let bgProbe = CGRect(x: avatar.minX, y: avatar.maxY + 2, width: avatar.width,
                             height: min(CGFloat(H) - avatar.maxY - 2, 6 * h))
        let bg = bgProbe.height > 2 ? img.dominantColor(in: bgProbe, step: 1) : img.dominantBorderColor(of: avatar.insetBy(dx: -4, dy: -4))

        // 말풍선 배경은 채팅 배경과 아주 미세하게 다를 수 있어 낮은 임계값 사용
        let faint = 12
        let avX0 = Int(avatar.minX + avatar.width * 0.2), avX1 = Int(avatar.maxX - avatar.width * 0.2)
        let contentLeft = Int(name.minX)
        let scanX0 = max(0, contentLeft - 3)
        let scanX1 = min(W, Int(Double(W) * 0.97))
        let avail = max(1, W - contentLeft)
        let maxGap = Int(max(26, 2.2 * h))

        func rowExtent(_ y: Int) -> (Int, Int)? {
            guard scanX0 < scanX1 else { return nil }
            var lo = -1
            for x in scanX0..<scanX1 where img.pixel(x, y).distance(bg) > faint { lo = x; break }
            guard lo >= 0 else { return nil }
            var hi = lo
            var x = scanX1 - 1
            while x > lo { if img.pixel(x, y).distance(bg) > faint { hi = x; break }; x -= 1 }
            return (lo, hi)
        }
        func nextSpeaker(_ y: Int) -> Bool {
            guard CGFloat(y) > avatar.maxY + 3, avX1 > avX0 else { return false }
            var n = 0
            for x in avX0..<avX1 where img.pixel(x, y).distance(bg) > Self.contentThreshold { n += 1 }
            return n * 4 >= (avX1 - avX0)
        }
        /// 이 덩어리(세로로 이어진 내용)가 같은 사람 것인가?
        /// - 이름 열에서 시작하면 그 사람 것
        /// - 조금 안쪽에서 시작해도 오른쪽 끝에 붙어 있지 않으면 그 사람 것 (투명 배경 이모티콘 등)
        /// - 오른쪽 정렬(내 메시지), 가운데 정렬(날짜 구분선)은 아님
        func belongs(_ minX: Int, _ maxX: Int) -> Bool {
            if minX <= contentLeft + 20 { return true }
            let centered = abs(Double(minX + maxX) / 2 - Double(W) / 2) < Double(W) * 0.08
            if centered { return false }
            return minX <= contentLeft + Int(Double(avail) * 0.35) && maxX < W - 30
        }

        var bottom = Int(max(avatar.maxY, name.maxY))
        var right = Int(name.maxX)
        var lastEnd = Int(name.maxY)
        var runStart = -1, runMin = Int.max, runMax = Int.min, runLast = -1
        var y = Int(name.maxY) + 1
        var stop = false
        func closeRun() {
            if belongs(runMin, runMax) {
                bottom = max(bottom, runLast + 1)
                right = max(right, runMax)
                lastEnd = runLast
            } else {
                stop = true
            }
            runStart = -1; runMin = Int.max; runMax = Int.min
        }
        while y < H && !stop {
            if nextSpeaker(y) {
                if runStart >= 0 { closeRun() }
                break
            }
            if let (lo, hi) = rowExtent(y) {
                if runStart < 0 {
                    if y - lastEnd > maxGap { break }
                    runStart = y
                }
                runMin = min(runMin, lo); runMax = max(runMax, hi); runLast = y
            } else if runStart >= 0 && y - runLast >= 5 {
                closeRun()
            }
            y += 1
        }
        if runStart >= 0 && !stop { closeRun() }

        let top = min(avatar.minY, name.minY)
        let bottomF = CGFloat(bottom)
        let listLike = (bottomF - top) <= avatar.height * 1.8
        let maxX = listLike ? CGFloat(W) - 4 : CGFloat(min(W, right + 1))
        return (CGRect(x: avatar.minX, y: top, width: maxX - avatar.minX, height: bottomF - top), listLike)
    }

    // MARK: 알림 카드

    /// 알림 배너 카드 영역: 투명 바깥과 구분되는 불투명 영역 중 이름을 포함하는 덩어리.
    public func notificationCard(containing name: CGRect) -> CGRect {
        guard let img = image else { return CGRect(origin: .zero, size: size) }
        if !img.hasTransparency { return img.bounds }
        let step = 2
        let gw = (img.width + step - 1) / step, gh = (img.height + step - 1) / step
        func opaque(_ gx: Int, _ gy: Int) -> Bool {
            let x = min(img.width - 1, gx * step), y = min(img.height - 1, gy * step)
            return img.pixel(x, y).a >= 16
        }
        var sx = Int(name.midX) / step, sy = Int(name.midY) / step
        sx = max(0, min(gw - 1, sx)); sy = max(0, min(gh - 1, sy))
        guard opaque(sx, sy) else { return name }
        var seen = [Bool](repeating: false, count: gw * gh)
        var stack = [sy * gw + sx]
        seen[sy * gw + sx] = true
        var minX = sx, maxX = sx, minY = sy, maxY = sy
        while let p = stack.popLast() {
            let px = p % gw, py = p / gw
            minX = min(minX, px); maxX = max(maxX, px); minY = min(minY, py); maxY = max(maxY, py)
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = px + dx, ny = py + dy
                guard nx >= 0, ny >= 0, nx < gw, ny < gh else { continue }
                let q = ny * gw + nx
                if !seen[q] && opaque(nx, ny) { seen[q] = true; stack.append(q) }
            }
        }
        return CGRect(x: minX * step, y: minY * step, width: (maxX - minX + 1) * step, height: (maxY - minY + 1) * step)
            .intersection(img.bounds)
    }
}

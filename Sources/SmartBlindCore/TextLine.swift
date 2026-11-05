import Foundation
#if canImport(CoreGraphics)
import CoreGraphics   // macOS: CGRect 기하 함수(minX, union 등)는 CoreGraphics에 있음
#endif

/// 화면에서 읽은 한 줄의 텍스트 (OCR 또는 접근성)
public struct TextLine {
    public enum Source: String, Sendable { case ocr, accessibility }

    public var text: String
    /// 창 기준 좌표 (왼쪽 위 원점, pt)
    public var frame: CGRect
    public var source: Source
    /// 접근성 트리에서 얻은, 이 텍스트를 담고 있는 행/셀/말풍선 영역 (창 기준)
    public var container: CGRect?
    /// 글자 범위 → 정확한 영역 (Vision이 제공). 없으면 글자 폭 비율로 추정.
    public var subrangeResolver: ((Range<Int>) -> CGRect?)?

    public init(text: String, frame: CGRect, source: Source = .ocr, container: CGRect? = nil,
                subrangeResolver: ((Range<Int>) -> CGRect?)? = nil) {
        self.text = text
        self.frame = frame
        self.source = source
        self.container = container
        self.subrangeResolver = subrangeResolver
    }

    /// 원본 글자 오프셋 범위의 영역
    public func rect(for range: Range<Int>) -> CGRect {
        let chars = Array(text)
        guard !chars.isEmpty, range.lowerBound < range.upperBound else { return frame }
        if range.lowerBound <= 0 && range.upperBound >= chars.count { return frame }
        if let r = subrangeResolver?(range), r.width > 0, r.height > 0 { return r }
        let weights = chars.map(TextLine.glyphWeight)
        let total = max(0.001, weights.reduce(0, +))
        let lo = weights[0..<max(0, min(chars.count, range.lowerBound))].reduce(0, +)
        let hi = weights[0..<max(0, min(chars.count, range.upperBound))].reduce(0, +)
        let x0 = frame.minX + frame.width * CGFloat(lo / total)
        let x1 = frame.minX + frame.width * CGFloat(hi / total)
        return CGRect(x: x0, y: frame.minY, width: max(1, x1 - x0), height: frame.height)
    }

    /// 글자 폭 대략치 (한글/한자 = 1)
    static func glyphWeight(_ c: Character) -> Double {
        if c.isWhitespace { return 0.3 }
        if let v = c.unicodeScalars.first?.value {
            if (0xAC00...0xD7A3).contains(v) || (0x3130...0x318F).contains(v) || (0x4E00...0x9FFF).contains(v)
                || (0x3040...0x30FF).contains(v) || (0xFF00...0xFFEF).contains(v) { return 1.0 }
        }
        if c.isUppercase || c.isNumber { return 0.62 }
        if c.isLetter { return 0.55 }
        return 0.38
    }
}

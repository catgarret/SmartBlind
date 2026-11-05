import Foundation
#if canImport(CoreGraphics)
import CoreGraphics   // macOS: CGRect 기하 함수(minX, union 등)는 CoreGraphics에 있음
#endif

// MARK: - 정규화

/// 비교용으로 정규화한 문자열 + 원본 글자 위치 매핑
public struct NormalizedText: Sendable {
    public let original: [Character]
    /// 정규화된 글자 (NFKC, 소문자, 공백/제어문자 제거)
    public let chars: [Character]
    /// chars[i]가 original의 몇 번째 글자에서 왔는지
    public let map: [Int]
}

public enum TextNormalizer {
    private static let removable: Set<Character> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{00AD}"]

    public static func isIgnorable(_ c: Character) -> Bool {
        if removable.contains(c) { return true }
        return c.isWhitespace || c.unicodeScalars.allSatisfy { CharacterSet.controlCharacters.contains($0) }
    }

    public static func normalizeWithMap(_ s: String) -> NormalizedText {
        let original = Array(s)
        var chars: [Character] = []
        var map: [Int] = []
        chars.reserveCapacity(original.count)
        map.reserveCapacity(original.count)
        for (i, ch) in original.enumerated() {
            if isIgnorable(ch) { continue }
            let n = String(ch).precomposedStringWithCompatibilityMapping.lowercased()
            for nc in n where !isIgnorable(nc) {
                chars.append(nc)
                map.append(i)
            }
        }
        return NormalizedText(original: original, chars: chars, map: map)
    }

    public static func normalize(_ s: String) -> String {
        String(normalizeWithMap(s).chars)
    }

    /// 단어를 이루는 글자 (한글/영문/숫자/밑줄)
    public static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    public static func isHangulSyllable(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value, c.unicodeScalars.count == 1 else { return false }
        return v >= 0xAC00 && v <= 0xD7A3
    }

    /// 한글 음절 → (초성, 중성, 종성) 인덱스
    public static func jamo(_ c: Character) -> (Int, Int, Int)? {
        guard isHangulSyllable(c), let v = c.unicodeScalars.first?.value else { return nil }
        let s = Int(v) - 0xAC00
        return (s / (21 * 28), (s % (21 * 28)) / 28, s % 28)
    }
}

// MARK: - 매칭 결과

public enum MatchRole: String, Sendable {
    /// 보낸 사람/목록 이름처럼 줄 전체가 사실상 이름 (예: "김민준[회사]")
    case header
    /// "김민준: 메시지" 처럼 이름으로 시작하는 미리보기 줄
    case senderPrefix
    /// 다른 사람 글 본문 안에서 이름이 언급됨
    case mention
}

public struct NameMatch: Equatable, Sendable {
    public var personID: UUID
    public var alias: String
    /// 원본 문자열 글자 오프셋 범위
    public var range: Range<Int>
    /// 0 = 정확히 일치
    public var cost: Double
    public var role: MatchRole
}

// MARK: - 매처

public struct NameMatcher: Sendable {
    struct Needle: Sendable {
        let personID: UUID
        let alias: String
        let chars: [Character]
        let isLatin: Bool
    }

    public let mode: MatchMode
    let needles: [Needle]

    public init(people: [Person], mode: MatchMode) {
        self.mode = mode
        var list: [Needle] = []
        for p in people where p.enabled {
            for alias in p.allNames {
                let n = Array(TextNormalizer.normalize(alias))
                // 한 글자 별칭은 오탐이 너무 많아 제외
                guard n.count >= 2 else { continue }
                let latin = n.allSatisfy { $0.isASCII }
                list.append(Needle(personID: p.id, alias: alias, chars: n, isLatin: latin))
            }
        }
        // 긴 별칭 우선 (겹칠 때 긴 쪽을 남김)
        needles = list.sorted { $0.chars.count > $1.chars.count }
    }

    public var isEmpty: Bool { needles.isEmpty }

    /// 한 줄의 텍스트에서 등록된 이름을 모두 찾는다.
    public func matches(in text: String) -> [NameMatch] {
        guard !needles.isEmpty else { return [] }
        let norm = TextNormalizer.normalizeWithMap(text)
        guard !norm.chars.isEmpty else { return [] }
        var found: [NameMatch] = []
        var taken: [Range<Int>] = []   // 원본 기준으로 이미 차지한 범위

        for needle in needles {
            for (nStart, nEnd, cost) in occurrences(of: needle, in: norm.chars) {
                let oStart = norm.map[nStart]
                let oEnd = norm.map[nEnd - 1] + 1
                let r = oStart..<oEnd
                if taken.contains(where: { $0.overlaps(r) }) { continue }
                if mode == .word && !isWordBoundaryOK(norm.original, r, latin: needle.isLatin) { continue }
                let role = MatchClassifier.role(of: r, in: norm.original)
                found.append(NameMatch(personID: needle.personID, alias: needle.alias, range: r, cost: cost, role: role))
                taken.append(r)
            }
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    // 정규화 문자열에서 (시작, 끝, 비용) 목록
    func occurrences(of needle: Needle, in hay: [Character]) -> [(Int, Int, Double)] {
        let m = needle.chars.count
        guard hay.count >= max(1, m - 1) else { return [] }
        switch mode {
        case .word, .contains:
            var out: [(Int, Int, Double)] = []
            guard hay.count >= m else { return [] }
            var i = 0
            while i + m <= hay.count {
                if Array(hay[i..<(i + m)]) == needle.chars {
                    out.append((i, i + m, 0)); i += m
                } else { i += 1 }
            }
            return out
        case .fuzzy:
            return fuzzyOccurrences(needle.chars, in: hay, maxCost: Self.allowedCost(length: m, latin: needle.isLatin))
        }
    }

    static func allowedCost(length m: Int, latin: Bool) -> Double {
        if latin { return m >= 6 ? 1 : 0 }
        switch m {
        case ..<3: return 0
        case 3...4: return 0.5      // 한글 3~4자: 자모 1개 오인식만 허용
        case 5...8: return 1
        default: return 2
        }
    }

    static func substitutionCost(_ a: Character, _ b: Character) -> Double {
        if a == b { return 0 }
        if let ja = TextNormalizer.jamo(a), let jb = TextNormalizer.jamo(b) {
            let diff = (ja.0 != jb.0 ? 1 : 0) + (ja.1 != jb.1 ? 1 : 0) + (ja.2 != jb.2 ? 1 : 0)
            return diff == 1 ? 0.5 : 1
        }
        return 1
    }

    /// Sellers 근사 부분문자열 탐색
    func fuzzyOccurrences(_ p: [Character], in t: [Character], maxCost: Double) -> [(Int, Int, Double)] {
        let m = p.count, n = t.count
        if maxCost <= 0 {
            var out: [(Int, Int, Double)] = []
            guard n >= m else { return [] }
            var i = 0
            while i + m <= n { if Array(t[i..<(i + m)]) == p { out.append((i, i + m, 0)); i += m } else { i += 1 } }
            return out
        }
        // prev[j], start[j]
        var prev = [Double](repeating: 0, count: n + 1)
        var prevStart = Array(0...n)
        var cur = prev
        var curStart = prevStart
        for i in 1...m {
            cur[0] = Double(i); curStart[0] = 0
            for j in 1...n {
                let sub = prev[j - 1] + Self.substitutionCost(p[i - 1], t[j - 1])
                let del = prev[j] + 1
                let ins = cur[j - 1] + 1
                if sub <= del && sub <= ins { cur[j] = sub; curStart[j] = prevStart[j - 1] }
                else if del <= ins { cur[j] = del; curStart[j] = prevStart[j] }
                else { cur[j] = ins; curStart[j] = curStart[j - 1] }
            }
            swap(&prev, &cur); swap(&prevStart, &curStart)
        }
        // 비용이 허용 범위인 끝 위치 중 국소 최솟값만 선택, 겹치지 않게
        var out: [(Int, Int, Double)] = []
        var j = 1
        while j <= n {
            if prev[j] <= maxCost + 1e-9 {
                var best = j
                var k = j + 1
                while k <= n && prev[k] <= maxCost + 1e-9 { if prev[k] < prev[best] { best = k }; k += 1 }
                let s = prevStart[best]
                if best - s >= max(2, m - 1) {
                    if let last = out.last, s < last.1 { /* 겹침 무시 */ } else { out.append((s, best, prev[best])) }
                }
                j = k
            } else { j += 1 }
        }
        return out
    }

    // MARK: 단어 경계

    static let honorifics = ["님", "씨", "군", "양", "프로", "매니저", "책임", "선임", "수석", "대리", "과장", "차장", "부장",
                             "팀장", "실장", "본부장", "이사", "대표", "선배", "후배", "쌤", "선생님"]
    static let particles: Set<String> = ["", "이", "가", "은", "는", "을", "를", "의", "에게", "한테", "께", "께서", "과", "와",
                                         "도", "만", "랑", "이랑", "아", "야", "에게서", "한테서", "이가", "이는", "이도", "이랑"]

    func isWordBoundaryOK(_ original: [Character], _ r: Range<Int>, latin: Bool) -> Bool {
        if r.lowerBound > 0 {
            let before = original[r.lowerBound - 1]
            if TextNormalizer.isWordChar(before) {
                // 영문 별칭 앞에 한글이 붙은 경우는 허용 (예: "님hong123" 같은 OCR 붙음은 드묾) → 그래도 거부
                return false
            }
        }
        var suffix = ""
        var k = r.upperBound
        while k < original.count, TextNormalizer.isWordChar(original[k]) { suffix.append(original[k]); k += 1 }
        if suffix.isEmpty { return true }
        if latin { return false }
        if Self.particles.contains(suffix) { return true }
        for h in Self.honorifics where suffix.hasPrefix(h) {
            if Self.particles.contains(String(suffix.dropFirst(h.count))) { return true }
        }
        return false
    }
}

// MARK: - 역할 판별

public enum MatchClassifier {
    static let openBrackets: Set<Character> = ["[", "(", "<", "{", "【", "「", "『", "［", "（", "＜"]
    static let closeBrackets: Set<Character> = ["]", ")", ">", "}", "】", "」", "』", "］", "）", "＞"]

    /// 매칭된 이름이 줄에서 어떤 역할인지 추정
    public static func role(of r: Range<Int>, in original: [Character]) -> MatchRole {
        let before = Array(original[..<r.lowerBound])
        let after = stripHonorificPrefix(Array(original[r.upperBound...]))
        let beforeMeaningful = meaningfulCount(before)
        // "이름: 메시지" 형태 (알림 본문, 단체방 목록 미리보기)
        if beforeMeaningful == 0, let first = after.first(where: { !$0.isWhitespace }), first == ":" || first == "：" {
            let rest = meaningfulCount(Array(after.drop(while: { $0 != ":" && $0 != "：" }).dropFirst()))
            return rest > 0 ? .senderPrefix : .header
        }
        let afterMeaningful = meaningfulCount(after)
        if beforeMeaningful == 0 && afterMeaningful <= 1 { return .header }
        if beforeMeaningful <= 1 && afterMeaningful == 0 { return .header }
        return .mention
    }

    static func stripHonorificPrefix(_ s: [Character]) -> [Character] {
        var word = ""
        var k = 0
        while k < s.count, TextNormalizer.isWordChar(s[k]) { word.append(s[k]); k += 1 }
        if word.isEmpty { return s }
        if NameMatcher.particles.contains(word) { return Array(s[k...]) }
        for h in NameMatcher.honorifics where word.hasPrefix(h) && NameMatcher.particles.contains(String(word.dropFirst(h.count))) {
            return Array(s[k...])
        }
        return s
    }

    /// 괄호 안 소속([회사]), 시간(오후 5:46), 문장부호/공백을 뺀 의미 있는 글자 수
    static func meaningfulCount(_ s: [Character]) -> Int {
        var depth = 0
        var kept: [Character] = []
        for c in s {
            if openBrackets.contains(c) { depth += 1; continue }
            if closeBrackets.contains(c) { depth = max(0, depth - 1); continue }
            if depth > 0 { continue }
            if TextNormalizer.isWordChar(c) { kept.append(c) }
        }
        var text = String(kept)
        // 시간 표기 제거
        for token in ["오전", "오후", "am", "pm", "AM", "PM"] { text = text.replacingOccurrences(of: token, with: "") }
        text = String(text.filter { !$0.isNumber })
        return text.count
    }
}

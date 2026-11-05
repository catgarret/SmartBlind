import Foundation
#if canImport(CoreGraphics)
import CoreGraphics   // macOS: CGRect 기하 함수(minX, union 등)는 CoreGraphics에 있음
#endif

public struct DetectionInput {
    public var windowSize: CGSize
    public var kind: WindowKind
    public var lines: [TextLine]
    public var image: PixelImage?
    public var scope: CoverScope
    public var custom: CustomInsets
    public var hideMentions: Bool

    public init(windowSize: CGSize, kind: WindowKind, lines: [TextLine], image: PixelImage?,
                scope: CoverScope = .auto, custom: CustomInsets = CustomInsets(), hideMentions: Bool = true) {
        self.windowSize = windowSize; self.kind = kind; self.lines = lines; self.image = image
        self.scope = scope; self.custom = custom; self.hideMentions = hideMentions
    }
}

/// 디버그/상태 표시용 상세 결과
public struct DetectionHit: Sendable {
    public var personID: UUID
    public var alias: String
    public var lineText: String
    public var role: MatchRole
    public var nameRect: CGRect
    public var avatar: CGRect?
    public var region: CoverRegion?
}

/// 텍스트 줄 + 화면 픽셀 → 가림 영역
public struct Detector {
    public let matcher: NameMatcher

    public init(matcher: NameMatcher) { self.matcher = matcher }

    /// 창 오른쪽 스크롤 막대 폭 (pt)
    public static let scrollBarGutter: CGFloat = 16

    public func detect(_ input: DetectionInput) -> [CoverRegion] {
        merge(detectHits(input).compactMap { $0.region }, in: input.windowSize)
    }

    public func detectHits(_ input: DetectionInput) -> [DetectionHit] {
        guard !matcher.isEmpty else { return [] }
        let layout = LayoutAnalyzer(image: input.image, size: input.windowSize)
        // 오른쪽 스크롤 막대 영역(16pt)은 가리지 않음 → 스크롤 막대가 항상 보이고 잡힘
        let gutter = input.kind == .normal ? Detector.scrollBarGutter : 0
        let windowRect = CGRect(x: 0, y: 0, width: max(0, input.windowSize.width - gutter),
                                height: input.windowSize.height)
        var hits: [DetectionHit] = []
        for line in input.lines {
            for m in matcher.matches(in: line.text) {
                let nameRect = line.rect(for: m.range)
                var avatar: CGRect?
                let reg = region(for: m, line: line, nameRect: nameRect, input: input, layout: layout, avatarOut: &avatar)
                var hit = DetectionHit(personID: m.personID, alias: m.alias, lineText: line.text, role: m.role,
                                       nameRect: nameRect, avatar: avatar, region: reg)
                if var r = hit.region {
                    r.rect = r.rect.intersection(windowRect)
                    hit.region = r.rect.isNull || r.rect.width < 1 || r.rect.height < 1 ? nil : r
                }
                hits.append(hit)
            }
        }
        return hits
    }

    func region(for m: NameMatch, line: TextLine, nameRect: CGRect, input: DetectionInput,
                layout: LayoutAnalyzer, avatarOut: inout CGRect?) -> CoverRegion? {
        let pid = m.personID
        let nameOnly = CoverRegion(personID: pid, rect: nameRect, kind: .name)
        let W = input.windowSize.width

        // 본문에서 언급된 이름: 이름 글자만 (또는 가리지 않음)
        if m.role == .mention {
            return input.hideMentions ? nameOnly : nil
        }

        // 알림 배너 / 앱 토스트: 그 사람의 알림 1건 = 카드 전체
        switch input.kind {
        case .notification:
            let card = layout.notificationCard(containing: nameRect)
            if card.height <= 320 { return CoverRegion(personID: pid, rect: card, kind: .card) }
        case .toast:
            if input.windowSize.height <= 320 {
                return CoverRegion(personID: pid, rect: CGRect(origin: .zero, size: input.windowSize), kind: .card)
            }
        case .normal:
            break
        }

        let avatar = (input.scope == .nameOnly || input.scope == .custom) ? nil : layout.detectAvatar(nextTo: nameRect)
        avatarOut = avatar

        switch input.scope {
        case .nameOnly:
            return nameOnly
        case .nameAndAvatar:
            return CoverRegion(personID: pid, rect: avatar.map { nameRect.union($0) } ?? nameRect, kind: avatar == nil ? .name : .nameAvatar)
        case .custom:
            let c = input.custom
            var r = CGRect(x: nameRect.minX - c.left, y: nameRect.minY - c.top,
                           width: nameRect.width + c.left + c.right, height: nameRect.height + c.top + c.bottom)
            if c.toRightEdge { r.size.width = W - 4 - r.minX }
            return CoverRegion(personID: pid, rect: r, kind: .custom)
        case .row:
            let left = avatar?.minX ?? max(0, nameRect.minX - 4)
            let top = min(avatar?.minY ?? nameRect.minY, nameRect.minY)
            let bottom = max(avatar?.maxY ?? 0, nameRect.maxY + 1.6 * nameRect.height)
            return CoverRegion(personID: pid, rect: CGRect(x: left, y: top, width: W - 4 - left, height: bottom - top), kind: .row)
        case .auto:
            break
        }

        // 자동
        if m.role == .senderPrefix {
            // "홍길동: 메시지" 미리보기 줄 → 이름부터 줄 끝까지
            let lineRest = CGRect(x: nameRect.minX, y: line.frame.minY, width: line.frame.maxX - nameRect.minX, height: line.frame.height)
            return CoverRegion(personID: pid, rect: lineRest.union(nameRect), kind: .line)
        }
        // 접근성 트리가 알려준 행/셀/말풍선
        if let c = line.container, c.contains(CGPoint(x: nameRect.midX, y: nameRect.midY)),
           c.height <= max(160, input.windowSize.height * 0.45), c.width >= nameRect.width {
            return CoverRegion(personID: pid, rect: avatar.map { c.union($0) } ?? c, kind: .container)
        }
        if let avatar {
            let block = layout.expandBlock(name: nameRect, avatar: avatar)
            return CoverRegion(personID: pid, rect: block.rect, kind: block.listLike ? .row : .block)
        }
        // 구조를 알 수 없으면 보수적으로 이름만
        return nameOnly
    }

    /// 같은 사람의 겹치는 영역은 합친다.
    public func merge(_ regions: [CoverRegion], in size: CGSize) -> [CoverRegion] {
        var out: [CoverRegion] = []
        for r in regions.sorted(by: { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }) {
            if let i = out.firstIndex(where: { $0.personID == r.personID && $0.rect.insetBy(dx: -2, dy: -2).intersects(r.rect) }) {
                // 큰 영역 안에 거의 포함되면 흡수, 아니면 합집합
                let inter = out[i].rect.intersection(r.rect)
                if inter.width * inter.height >= 0.6 * r.rect.width * r.rect.height {
                    continue
                }
                out[i].rect = out[i].rect.union(r.rect)
            } else {
                out.append(r)
            }
        }
        return out
    }
}

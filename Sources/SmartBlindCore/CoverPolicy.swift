import Foundation
#if canImport(CoreGraphics)
import CoreGraphics   // macOS: CGRect 기하 함수(minX, union 등)는 CoreGraphics에 있음
#endif

/// 화면에서 찾은 이름(사람·방)에 사람별/방별 세부 규칙을 적용해 최종 가림 영역을 만든다.
///
/// - 사람: 대화 목록 / 대화방 안 / 알림 중 어디서 가릴지, 특정 방에서만·특정 방 제외, 가림 방식(대화까지·이름+프로필만)
/// - 방: 대화 목록에서 그 방 줄 가리기, 그 방을 열면 대화 내용 전체 가리기
public struct CoverPolicy: Sendable {
    public enum Context: String, Sendable { case list, chat, notification }

    let people: [UUID: Person]
    let rooms: [UUID: Room]
    let globalMode: CoverMode

    public init(settings: AppSettings) {
        var p: [UUID: Person] = [:]
        for x in settings.people { p[x.id] = x }
        var r: [UUID: Room] = [:]
        for x in settings.rooms { r[x.id] = x }
        people = p
        rooms = r
        globalMode = settings.coverMode
    }

    /// 매처에 넣을 대상 (사람 + 방)
    public static func matchTargets(settings: AppSettings, bundleID: String?, notification: Bool) -> [Person] {
        let ps = settings.people.filter { notification ? $0.enabled : $0.applies(to: bundleID) }
        return ps + settings.activeRooms.map { $0.asPerson }
    }

    /// 창 맨 위 제목 영역에 보이는 글자(방 이름 후보)
    public struct TitleLine: Sendable {
        public var text: String
        public var frame: CGRect
        public init(text: String, frame: CGRect) { self.text = text; self.frame = frame }
    }

    /// 창 위쪽(제목 영역)에 있는 줄만 골라 방 이름 후보로
    public static func titleCandidates(from lines: [TextLine], windowHeight: CGFloat) -> [TitleLine] {
        let limit = min(130, windowHeight * 0.25)
        return lines.filter { $0.frame.minY < limit && $0.frame.height >= 9 }
            .map { TitleLine(text: $0.text, frame: $0.frame) }
    }

    /// 이 창이 어떤 방인지: 등록된 이름이 제목 영역 글자와 일치하면 그 이름과 제목 줄
    static func roomTitleMatch(names: [String], titles: [TitleLine]) -> TitleLine? {
        let keys = names.map { TextNormalizer.normalize($0) }.filter { $0.count >= 2 }
        guard !keys.isEmpty else { return nil }
        for t in titles {
            let n = TextNormalizer.normalize(t.text)
            // 제목 줄은 "디자인 2팀 11" 처럼 뒤에 인원수 등이 붙을 수 있어 '시작' 또는 '포함'으로 본다
            if keys.contains(where: { n == $0 || n.hasPrefix($0) || (n.contains($0) && $0.count >= 3) }) { return t }
        }
        return nil
    }

    public func regions(hits: [DetectionHit], windowKind: WindowKind, windowSize: CGSize,
                        titles: [TitleLine], detector: Detector) -> [CoverRegion] {
        var out: [CoverRegion] = []
        for h in hits {
            guard let region = h.region else { continue }
            if let room = rooms[h.personID] {
                // 방 이름이 목록 줄로 보일 때만 그 줄을 가림 (방 제목줄은 아래 '방 안 전체'에서 처리)
                // 이 창 제목줄에 있는 방 이름이면 목록 줄이 아님
                let isTitle = titles.contains { $0.frame.intersects(h.nameRect) }
                if room.enabled, room.hideInList, !isTitle, windowKind == .normal,
                   region.kind == .row || region.kind == .container {
                    var r = region
                    r.label = room.showLabel ? room.displayLabel : nil
                    if !room.showUnreadBadge { r.holes = [] }
                    out.append(r)
                }
                continue
            }
            guard let p = people[h.personID], p.enabled else { continue }
            let context: Context
            if windowKind != .normal { context = .notification }
            else if region.kind == .row || region.kind == .container { context = .list }
            else { context = .chat }

            switch context {
            case .list: if !p.hideInList { continue }
            case .chat: if !p.hideInChat { continue }
            case .notification: if !p.hideInNotifications { continue }
            }
            if context == .chat && p.roomScope != .all {
                let inRoom = Self.roomTitleMatch(names: p.rooms, titles: titles) != nil
                if p.roomScope == .only && !inRoom { continue }
                if p.roomScope == .except && inRoom { continue }
            }
            let mode = p.coverMode ?? globalMode
            if mode == .profileOnly && h.role != .mention {
                let rect = h.avatar.map { h.nameRect.union($0) } ?? h.nameRect
                out.append(CoverRegion(personID: p.id, rect: rect, kind: h.avatar == nil ? .name : .nameAvatar))
            } else {
                var r = region
                if context == .list {
                    let l = p.listLabel.trimmingCharacters(in: .whitespaces)
                    r.label = p.showLabel ? (l.isEmpty ? "가려진 대화" : l) : nil
                    if !p.showUnreadBadge { r.holes = [] }
                } else {
                    r.holes = []
                }
                out.append(r)
            }
        }

        // 방 안 전체 가리기: 제목 영역에 가릴 방 이름이 보이면 그 아래 대화 영역 전체
        if windowKind == .normal {
            for room in rooms.values where room.enabled && room.hideInside {
                guard let title = Self.roomTitleMatch(names: room.asPerson.allNames, titles: titles) else { continue }
                let top = min(windowSize.height - 20, title.frame.maxY + 10)
                let rect = CGRect(x: 0, y: top, width: max(0, windowSize.width - Detector.scrollBarGutter),
                                  height: max(0, windowSize.height - top))
                out.append(CoverRegion(personID: room.id, rect: rect, kind: .room,
                                       label: room.showLabel ? "\(room.displayLabel) · 가린 대화방 (클릭하면 잠깐 보기)" : nil))
            }
        }
        return detector.merge(out, in: windowSize)
    }
}

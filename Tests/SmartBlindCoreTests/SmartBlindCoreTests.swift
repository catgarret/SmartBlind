import Foundation
#if canImport(CoreGraphics)
import CoreGraphics   // macOS: CGRect 기하 함수(minX, union 등)는 CoreGraphics에 있음
#endif
import XCTest
@testable import SmartBlindCore

// 첨부된 실제 메신저 화면(알림 봇 / 사진 / 이모티콘)과, 그 셋을 이어 붙이고 "내 메시지"를 끼운 대화 화면으로 검증한다.

struct Fixture {
    let image: PixelImage
    let lines: [TextLine]

    static func load(_ name: String) throws -> Fixture {
        // 실제 화면 캡처 fixture는 저장소에 없음 → 없으면 이 테스트는 건너뜀
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        guard FileManager.default.fileExists(atPath: base.appendingPathComponent("\(name).json").path) else {
            throw XCTSkip("로컬 화면 캡처 fixture 없음: \(name)")
        }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: base.appendingPathComponent("\(name).json"))) as! [String: Any]
        let w = json["width"] as! Int, h = json["height"] as! Int
        let raw = try Data(contentsOf: base.appendingPathComponent("\(name).rgba"))
        let lines = (json["lines"] as! [[String: Any]]).map { l in
            TextLine(text: l["text"] as! String,
                     frame: CGRect(x: l["x"] as! Int, y: l["y"] as! Int, width: l["w"] as! Int, height: l["h"] as! Int))
        }
        return Fixture(image: PixelImage(width: w, height: h, data: [UInt8](raw)), lines: lines)
    }

    func input(kind: WindowKind = .normal, scope: CoverScope = .auto, extraLines: [TextLine] = []) -> DetectionInput {
        DetectionInput(windowSize: CGSize(width: image.width, height: image.height), kind: kind,
                       lines: lines + extraLines, image: image, scope: scope)
    }
}

let gildong = Person(name: "홍길동", aliases: ["hong123", "길동"])
let jinhyo = Person(name: "김민준")
let hyunjae = Person(name: "이서준")
let bot = Person(name: "알림 봇")

/// 결과를 시각화용 JSON으로 남김 (SMARTBLIND_DEBUG_OUT 지정 시)
func dump(_ name: String, _ hits: [DetectionHit]) {
    guard let dir = ProcessInfo.processInfo.environment["SMARTBLIND_DEBUG_OUT"] else { return }
    func nums(_ r: CGRect) -> [Double] { [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)] }
    let arr: [[String: Any]] = hits.map { h in
        var d: [String: Any] = ["alias": h.alias, "role": h.role.rawValue, "name": nums(h.nameRect)]
        if let a = h.avatar { d["avatar"] = nums(a) }
        if let r = h.region { d["region"] = nums(r.rect); d["kind"] = r.kind.rawValue }
        return d
    }
    let data = try! JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted])
    try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).hits.json"))
}

final class NameMatcherTests: XCTestCase {
    func testWordModeAllowsHonorificsAndParticles() {
        let m = NameMatcher(people: [gildong], mode: .word)
        XCTAssertEqual(m.matches(in: "홍길동").count, 1)
        XCTAssertEqual(m.matches(in: "홍길동님 안녕하세요").count, 1)
        XCTAssertEqual(m.matches(in: "홍길동[회사]").count, 1)
        XCTAssertEqual(m.matches(in: "어제 홍길동이 말했어").count, 1)
        XCTAssertEqual(m.matches(in: "hong123").count, 1)
        XCTAssertEqual(m.matches(in: "hong1234").count, 0, "영문 아이디는 뒤에 글자가 붙으면 다른 사람")
        XCTAssertEqual(m.matches(in: "길동아 밥먹자").count, 1)
    }

    func testDoesNotMatchLongerDifferentName() {
        let m = NameMatcher(people: [Person(name: "김민")], mode: .word)
        XCTAssertEqual(m.matches(in: "김민준[회사]").count, 0, "'김민'으로 '김민준'를 가리면 안 됨")
        XCTAssertEqual(NameMatcher(people: [Person(name: "김민")], mode: .contains).matches(in: "김민준").count, 1)
    }

    func testOCRSpacingAndFuzzy() {
        let m = NameMatcher(people: [jinhyo], mode: .word)
        XCTAssertEqual(m.matches(in: "김 민준 [회사]").count, 1, "OCR이 띄어쓰기를 넣어도 인식")
        XCTAssertEqual(m.matches(in: "김민주").count, 0)
        let f = NameMatcher(people: [jinhyo], mode: .fuzzy)
        XCTAssertEqual(f.matches(in: "김민주[회사]").count, 1, "오인식 허용 모드: 자모 1개 차이")
        XCTAssertEqual(f.matches(in: "박지수").count, 0)
    }

    func testRoles() {
        let m = NameMatcher(people: [jinhyo], mode: .word)
        XCTAssertEqual(m.matches(in: "김민준[회사]").first?.role, .header)
        XCTAssertEqual(m.matches(in: "김민준").first?.role, .header)
        XCTAssertEqual(m.matches(in: "김민준: 여기에 ㅋㅋㅋ").first?.role, .senderPrefix)
        XCTAssertEqual(m.matches(in: "아까 김민준님이 보낸 사진 봤어?").first?.role, .mention)
        let b = NameMatcher(people: [bot], mode: .word)
        XCTAssertEqual(b.matches(in: "알림 봇").first?.role, .header)
    }

    func testRangeMapsToOriginal() {
        let m = NameMatcher(people: [jinhyo], mode: .word)
        let text = "아까 김민준님이"
        let r = m.matches(in: text).first!.range
        XCTAssertEqual(String(Array(text)[r]), "김민준")
    }
}

final class LayoutTests: XCTestCase {
    func testPhotoMessageBlock() throws {
        let fx = try Fixture.load("photo")
        let d = Detector(matcher: NameMatcher(people: [jinhyo], mode: .word))
        let hits = d.detectHits(fx.input())
        dump("photo", hits)
        let r = try XCTUnwrap(hits.first?.region)
        let av = try XCTUnwrap(hits.first?.avatar, "프로필 사진 인식")
        XCTAssertEqual(av.midX, 31, accuracy: 6); XCTAssertEqual(av.midY, 35, accuracy: 6)
        XCTAssertLessThanOrEqual(r.rect.minX, 20)
        XCTAssertLessThanOrEqual(r.rect.minY, 22)
        XCTAssertGreaterThanOrEqual(r.rect.maxX, 300, "사진 오른쪽 끝까지")
        XCTAssertGreaterThanOrEqual(r.rect.maxY, 420, "사진 + 버튼 + '여기에 ㅋㅋㅋ' 말풍선까지")
    }

    func testStickerBlock() throws {
        let fx = try Fixture.load("sticker")
        let hits = Detector(matcher: NameMatcher(people: [hyunjae], mode: .word)).detectHits(fx.input())
        dump("sticker", hits)
        let r = try XCTUnwrap(hits.first?.region)
        XCTAssertNotNil(hits.first?.avatar)
        XCTAssertGreaterThanOrEqual(r.rect.maxY, 185, "이모티콘 전체")
        XCTAssertGreaterThanOrEqual(r.rect.maxX, 215)
    }

    func testBotNoticeBlock() throws {
        let fx = try Fixture.load("notice")
        let hits = Detector(matcher: NameMatcher(people: [bot], mode: .word)).detectHits(fx.input())
        dump("notice", hits)
        let r = try XCTUnwrap(hits.first?.region)
        XCTAssertNotNil(hits.first?.avatar)
        XCTAssertGreaterThanOrEqual(r.rect.maxY, 135, "말풍선 전체")
        XCTAssertGreaterThanOrEqual(r.rect.maxX, 300)
    }

    func testChatStopsAtOwnMessageAndNextSpeaker() throws {
        let fx = try Fixture.load("chat")
        let d = Detector(matcher: NameMatcher(people: [jinhyo], mode: .word))
        let hits = d.detectHits(fx.input())
        dump("chat_jinhyo", hits)
        let r = try XCTUnwrap(hits.first?.region)
        // 사진 메시지는 150~587 구간, 그 아래 내 메시지(노란 말풍선, 599~633), 그 아래 이서준
        XCTAssertGreaterThanOrEqual(r.rect.maxY, 570)
        XCTAssertLessThan(r.rect.maxY, 600, "내 메시지는 가리지 않음")
        XCTAssertGreaterThanOrEqual(r.rect.minY, 140, "위의 다른 사람(알림 봇)은 가리지 않음")
    }

    func testChatOnlyBlindedPersonIsCovered() throws {
        let fx = try Fixture.load("chat")
        let d = Detector(matcher: NameMatcher(people: [hyunjae], mode: .word))
        let hits = d.detectHits(fx.input())
        dump("chat_hyunjae", hits)
        let r = try XCTUnwrap(hits.first?.region)
        XCTAssertGreaterThanOrEqual(r.rect.minY, 640)
        XCTAssertGreaterThanOrEqual(r.rect.maxY, 830)
    }

    func testStopsAtCenteredDateSeparator() throws {
        let fx = try Fixture.load("chat")
        var img = fx.image
        func paint(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: RGBA) {
            for y in y0..<y1 { for x in x0..<x1 { let i = (y * img.width + x) * 4; img.data[i] = c.r; img.data[i + 1] = c.g; img.data[i + 2] = c.b; img.data[i + 3] = c.a } }
        }
        paint(0, 587, img.width, 647, RGBA(255, 255, 255, 255))          // 내 메시지 지우기
        paint(150, 600, 270, 618, RGBA(225, 226, 230, 255))              // 가운데 날짜 구분선
        let input = DetectionInput(windowSize: CGSize(width: img.width, height: img.height), kind: .normal,
                                   lines: fx.lines.filter { $0.text != "나도 보고 싶다" }, image: img)
        let r = try XCTUnwrap(Detector(matcher: NameMatcher(people: [jinhyo], mode: .word)).detect(input).first)
        XCTAssertLessThan(r.rect.maxY, 600, "날짜 구분선에서 멈춤")
        XCTAssertGreaterThanOrEqual(r.rect.maxY, 570)
    }

    func testFriendListRow() {
        // 친구 목록: 56pt 간격 행, 왼쪽 프로필(36x36), 이름 + 상태메시지
        var img = PixelImage(width: 320, height: 200)
        func paint(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ v: UInt8) {
            for y in y0..<y1 { for x in x0..<x1 { let i = (y * 320 + x) * 4; img.data[i] = v; img.data[i + 1] = v / 2; img.data[i + 2] = 90 } }
        }
        var lines: [TextLine] = []
        let names = ["박민수", "홍길동", "이영희"]
        for (k, n) in names.enumerated() {
            let top = 10 + k * 56
            paint(12, top, 48, top + 36, 120)                    // 프로필
            paint(58, top + 3, 100, top + 15, 40)                // 이름 글자
            paint(58, top + 21, 180, top + 31, 140)              // 상태메시지 글자
            paint(270, top + 4, 296, top + 13, 150)              // 오른쪽 시간
            lines.append(TextLine(text: n, frame: CGRect(x: 58, y: top + 3, width: 42, height: 12)))
            lines.append(TextLine(text: "오늘도 화이팅", frame: CGRect(x: 58, y: top + 21, width: 122, height: 10)))
        }
        let r = Detector(matcher: NameMatcher(people: [gildong], mode: .word))
            .detect(DetectionInput(windowSize: CGSize(width: 320, height: 200), kind: .normal, lines: lines, image: img))
        XCTAssertEqual(r.count, 1)
        let rect = r[0].rect
        XCTAssertEqual(r[0].kind, .row)
        XCTAssertLessThanOrEqual(rect.minY, 66); XCTAssertGreaterThanOrEqual(rect.maxY, 97)
        XCTAssertLessThan(rect.maxY, 122, "다음 사람 행은 가리지 않음")
        XCTAssertGreaterThan(rect.minY, 46, "윗사람 행은 가리지 않음")
        XCTAssertGreaterThanOrEqual(rect.maxX, 300, "목록은 스크롤 막대 앞까지")
        XCTAssertLessThanOrEqual(rect.maxX, 304, "스크롤 막대(오른쪽 16pt)는 가리지 않음")
    }

    func testMentionCoversNameOnly() throws {
        let fx = try Fixture.load("sticker")
        let mention = TextLine(text: "아까 김민준님이 보낸 사진", frame: CGRect(x: 80, y: 100, width: 150, height: 12))
        let hits = Detector(matcher: NameMatcher(people: [jinhyo], mode: .word)).detectHits(fx.input(extraLines: [mention]))
        let r = try XCTUnwrap(hits.first?.region)
        XCTAssertEqual(r.kind, .name)
        XCTAssertLessThan(r.rect.width, 60)
    }

    func testNameOnlyWhenNoAvatar() throws {
        // 제목 표시줄처럼 프로필 사진 없이 이름만 있는 경우
        let img = PixelImage(width: 300, height: 100)
        let line = TextLine(text: "김민준", frame: CGRect(x: 120, y: 10, width: 40, height: 13))
        let r = Detector(matcher: NameMatcher(people: [jinhyo], mode: .word))
            .detect(DetectionInput(windowSize: CGSize(width: 300, height: 100), kind: .normal, lines: [line], image: img))
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.first?.kind, .name)
    }

    func testNotificationCardUsesTransparency() {
        // 투명 창 안의 불투명 카드 2개 (알림 2건). 아래 카드에 이름
        var img = PixelImage(width: 360, height: 200, fill: RGBA(0, 0, 0, 0))
        func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
            for y in y0..<y1 { for x in x0..<x1 { let i = (y * 360 + x) * 4; img.data[i] = 240; img.data[i + 1] = 240; img.data[i + 2] = 240; img.data[i + 3] = 255 } }
        }
        fill(10, 10, 350, 80); fill(10, 100, 350, 180)
        let line = TextLine(text: "김민준", frame: CGRect(x: 60, y: 112, width: 40, height: 13))
        let r = Detector(matcher: NameMatcher(people: [jinhyo], mode: .word))
            .detect(DetectionInput(windowSize: CGSize(width: 360, height: 200), kind: .notification, lines: [line], image: img))
        XCTAssertEqual(r.first?.kind, .card)
        XCTAssertEqual(r.first!.rect.minY, 100, accuracy: 3)
        XCTAssertEqual(r.first!.rect.maxY, 180, accuracy: 3)
    }

    func testToastCoversWholeWindow() {
        let line = TextLine(text: "김민준", frame: CGRect(x: 60, y: 12, width: 40, height: 13))
        let r = Detector(matcher: NameMatcher(people: [jinhyo], mode: .word))
            .detect(DetectionInput(windowSize: CGSize(width: 300, height: 80), kind: .toast, lines: [line], image: nil))
        XCTAssertEqual(r.first?.rect, CGRect(x: 0, y: 0, width: 300, height: 80))
    }
}

final class ScrollAndTrackerTests: XCTestCase {
    func testScrollShiftEstimate() throws {
        let fx = try Fixture.load("chat")
        let view = CGRect(x: 0, y: 100, width: 420, height: 500)
        let prev = fx.image.cropped(view)
        let cur = fx.image.cropped(view.offsetBy(dx: 0, dy: 37))    // 37pt 아래로 스크롤
        let diff = ScrollEstimator.compare(prev: prev, cur: cur)
        XCTAssertTrue(diff.changed)
        XCTAssertEqual(diff.shift, 37)
        XCTAssertFalse(ScrollEstimator.compare(prev: prev, cur: prev).changed)
    }

    func testTrackerKeepsRevealAcrossUpdatesAndDropsGone() {
        let t = BlindTracker(windowSize: CGSize(width: 400, height: 800))
        let pid = jinhyo.id
        t.update(with: [CoverRegion(personID: pid, rect: CGRect(x: 10, y: 100, width: 300, height: 200), kind: .block)], frameChanged: true, holdPasses: 1)
        let id = t.blinds[0].id
        t.toggleReveal(id: id, duration: 5, now: Date(timeIntervalSince1970: 0))
        t.applyShift(40, bandTop: 0, bandBottom: 800)
        XCTAssertEqual(t.blinds[0].rect.minY, 60)
        t.update(with: [CoverRegion(personID: pid, rect: CGRect(x: 10, y: 62, width: 300, height: 200), kind: .block)], frameChanged: true, holdPasses: 1)
        XCTAssertEqual(t.blinds.count, 1)
        XCTAssertEqual(t.blinds[0].id, id, "같은 가림막으로 추적")
        XCTAssertTrue(t.blinds[0].isRevealed(at: Date(timeIntervalSince1970: 3)))
        XCTAssertFalse(t.blinds[0].isRevealed(at: Date(timeIntervalSince1970: 6)))
        // 화면이 그대로인데 한 번 놓침 → 유지, 화면이 바뀌었는데 없음 → 즉시 제거
        t.update(with: [], frameChanged: false, holdPasses: 1)
        XCTAssertEqual(t.blinds.count, 1)
        t.update(with: [], frameChanged: true, holdPasses: 1)
        XCTAssertEqual(t.blinds.count, 0)
    }

    func testSettingsDecodeWithMissingKeys() throws {
        let json = #"{"people":[{"name":"홍길동"}],"style":{"kind":"blur"}}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.people.first?.name, "홍길동")
        XCTAssertEqual(s.style.kind, .blur)
        XCTAssertEqual(s.style.padding, BlindStyle().padding)
        XCTAssertEqual(s.reveal, .seconds5)
        XCTAssertFalse(s.apps.isEmpty)
    }
}

final class CoverPolicyTests: XCTestCase {
    func hit(_ p: Person, kind: RegionKind, role: MatchRole = .header) -> DetectionHit {
        DetectionHit(personID: p.id, alias: p.name, lineText: p.name, role: role,
                     nameRect: CGRect(x: 60, y: 300, width: 40, height: 12),
                     avatar: CGRect(x: 10, y: 298, width: 36, height: 36),
                     region: CoverRegion(personID: p.id, rect: CGRect(x: 10, y: 298, width: 300, height: 120), kind: kind))
    }
    let size = CGSize(width: 400, height: 700)
    let det = Detector(matcher: NameMatcher(people: [], mode: .word))
    let title = [CoverPolicy.TitleLine(text: "디자인 2팀 11", frame: CGRect(x: 60, y: 40, width: 90, height: 14))]

    func testListChatNotificationToggles() {
        var p = Person(name: "홍길동"); p.hideInList = false
        let s = AppSettings(people: [p])
        let pol = CoverPolicy(settings: s)
        XCTAssertTrue(pol.regions(hits: [hit(p, kind: .row)], windowKind: .normal, windowSize: size, titles: [], detector: det).isEmpty)
        XCTAssertEqual(pol.regions(hits: [hit(p, kind: .block)], windowKind: .normal, windowSize: size, titles: [], detector: det).count, 1)
        p.hideInNotifications = false
        let pol2 = CoverPolicy(settings: AppSettings(people: [p]))
        XCTAssertTrue(pol2.regions(hits: [hit(p, kind: .card)], windowKind: .notification, windowSize: size, titles: [], detector: det).isEmpty)
    }

    func testRoomScopeOnlyAndExcept() {
        var p = Person(name: "홍길동"); p.roomScope = .only; p.rooms = ["디자인 2팀"]
        var pol = CoverPolicy(settings: AppSettings(people: [p]))
        XCTAssertEqual(pol.regions(hits: [hit(p, kind: .block)], windowKind: .normal, windowSize: size, titles: title, detector: det).count, 1)
        XCTAssertTrue(pol.regions(hits: [hit(p, kind: .block)], windowKind: .normal, windowSize: size, titles: [], detector: det).isEmpty)
        p.roomScope = .except
        pol = CoverPolicy(settings: AppSettings(people: [p]))
        XCTAssertTrue(pol.regions(hits: [hit(p, kind: .block)], windowKind: .normal, windowSize: size, titles: title, detector: det).isEmpty)
    }

    func testProfileOnlyPerPerson() {
        var p = Person(name: "홍길동"); p.coverMode = .profileOnly
        let r = CoverPolicy(settings: AppSettings(people: [p]))
            .regions(hits: [hit(p, kind: .block)], windowKind: .normal, windowSize: size, titles: [], detector: det)
        XCTAssertEqual(r.first?.kind, .nameAvatar)
        XCTAssertLessThan(r.first!.rect.height, 50)
    }

    func testRoomHideInsideAndListRow() {
        let room = Room(name: "디자인 2팀")
        let pol = CoverPolicy(settings: AppSettings(rooms: [room]))
        let inside = pol.regions(hits: [], windowKind: .normal, windowSize: size, titles: title, detector: det)
        XCTAssertEqual(inside.first?.kind, .room)
        XCTAssertGreaterThanOrEqual(inside.first!.rect.minY, 54)
        XCTAssertEqual(inside.first!.rect.maxY, 700)
        let rp = room.asPerson
        let row = pol.regions(hits: [hit(rp, kind: .row)], windowKind: .normal, windowSize: size, titles: [], detector: det)
        XCTAssertEqual(row.count, 1)
        XCTAssertTrue(pol.regions(hits: [hit(rp, kind: .block)], windowKind: .normal, windowSize: size, titles: [], detector: det).isEmpty)
    }
}

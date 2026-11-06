import Foundation
#if canImport(CoreGraphics)
import CoreGraphics   // macOS: CGRect 기하 함수(minX, union 등)는 CoreGraphics에 있음
#endif

// MARK: - 사람(가림 대상)

public struct Person: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// 대표 이름 (예: 홍길동)
    public var name: String
    /// 별칭 (예: hong123, 길동)
    public var aliases: [String]
    public var enabled: Bool
    /// 적용할 앱 번들 ID. 비어 있으면 감시 중인 모든 앱에 적용
    public var appBundleIDs: [String]
    /// 대화 목록(채팅 목록·친구 목록)에서 가리기
    public var hideInList: Bool
    /// 대화방 안(말풍선·프로필)에서 가리기
    public var hideInChat: Bool
    /// 알림(macOS 배너·메신저 토스트)에서 가리기
    public var hideInNotifications: Bool
    /// 대화방 범위: 모든 방 / 지정한 방에서만 / 지정한 방 제외
    public var roomScope: RoomScope
    /// roomScope에 쓰는 방 이름들
    public var rooms: [String]
    /// 이 사람만 다른 가림 방식 (nil = 전체 설정 따름)
    public var coverMode: CoverMode?

    public init(id: UUID = UUID(), name: String, aliases: [String] = [], enabled: Bool = true, appBundleIDs: [String] = [],
                hideInList: Bool = true, hideInChat: Bool = true, hideInNotifications: Bool = true,
                roomScope: RoomScope = .all, rooms: [String] = [], coverMode: CoverMode? = nil) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.enabled = enabled
        self.appBundleIDs = appBundleIDs
        self.hideInList = hideInList
        self.hideInChat = hideInChat
        self.hideInNotifications = hideInNotifications
        self.roomScope = roomScope
        self.rooms = rooms
        self.coverMode = coverMode
    }

    /// 매칭에 쓰는 모든 이름 (대표 이름 + 별칭, 공백 제거·중복 제거)
    public var allNames: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in [name] + aliases {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            let key = TextNormalizer.normalize(t)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(t)
        }
        return out
    }

    public func applies(to bundleID: String?) -> Bool {
        guard enabled else { return false }
        if appBundleIDs.isEmpty { return true }
        guard let bundleID else { return false }
        return appBundleIDs.contains(bundleID)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, aliases, enabled, appBundleIDs, hideInList, hideInChat, hideInNotifications, roomScope, rooms, coverMode
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        appBundleIDs = try c.decodeIfPresent([String].self, forKey: .appBundleIDs) ?? []
        hideInList = try c.decodeIfPresent(Bool.self, forKey: .hideInList) ?? true
        hideInChat = try c.decodeIfPresent(Bool.self, forKey: .hideInChat) ?? true
        hideInNotifications = try c.decodeIfPresent(Bool.self, forKey: .hideInNotifications) ?? true
        roomScope = try c.decodeIfPresent(RoomScope.self, forKey: .roomScope) ?? .all
        rooms = try c.decodeIfPresent([String].self, forKey: .rooms) ?? []
        coverMode = try c.decodeIfPresent(CoverMode.self, forKey: .coverMode)
    }
}

public enum RoomScope: String, Codable, CaseIterable, Sendable {
    case all, only, except
    public var title: String {
        switch self {
        case .all: return "모든 방"
        case .only: return "지정한 방에서만"
        case .except: return "지정한 방은 제외"
        }
    }
}

// MARK: - 단체방(대화방) 가림

public struct Room: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// 방 이름 (예: 디자인 2팀)
    public var name: String
    public var aliases: [String]
    public var enabled: Bool
    /// 대화 목록에서 이 방 줄을 가림
    public var hideInList: Bool
    /// 이 방을 열면 대화 내용 전체를 가림 (방 제목줄 아래)
    public var hideInside: Bool

    public init(id: UUID = UUID(), name: String, aliases: [String] = [], enabled: Bool = true,
                hideInList: Bool = true, hideInside: Bool = true) {
        self.id = id; self.name = name; self.aliases = aliases; self.enabled = enabled
        self.hideInList = hideInList; self.hideInside = hideInside
    }

    /// 매칭용 (사람과 같은 매처를 쓰기 위해 Person 모양으로)
    public var asPerson: Person { Person(id: id, name: name, aliases: aliases, enabled: enabled) }

    enum CodingKeys: String, CodingKey { case id, name, aliases, enabled, hideInList, hideInside }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        hideInList = try c.decodeIfPresent(Bool.self, forKey: .hideInList) ?? true
        hideInside = try c.decodeIfPresent(Bool.self, forKey: .hideInside) ?? true
    }
}

// MARK: - 블라인드 스타일

public enum BlindStyleKind: String, Codable, CaseIterable, Sendable {
    case mosaic, blur, solid, image, background

    public var title: String {
        switch self {
        case .mosaic: return "모자이크"
        case .blur: return "블러"
        case .solid: return "단색"
        case .image: return "이미지"
        case .background: return "배경색"
        }
    }
}

public enum ImageFillMode: String, Codable, CaseIterable, Sendable {
    case fill, tile
    public var title: String { self == .fill ? "채우기" : "바둑판(패턴)" }
}

public struct BlindStyle: Codable, Equatable, Sendable {
    public var kind: BlindStyleKind
    /// 0.0 ~ 1.0 (모자이크 칸 크기 / 블러 반경)
    public var intensity: Double
    /// pt
    public var cornerRadius: Double
    /// 여백 (pt). + 는 바깥으로 넓히고, − 는 안쪽으로 줄인다 (-16 ~ 16)
    public var padding: Double
    /// 단색 색상 (#RRGGBB)
    public var colorHex: String
    /// 커스텀 이미지 경로
    public var imagePath: String?
    public var imageMode: ImageFillMode
    /// 공개(해제) 중일 때 얇은 테두리 표시
    public var showRevealOutline: Bool
    /// 가림막 불투명도 (0.3 ~ 1.0). 낮추면 뒤가 살짝 비침
    public var opacity: Double
    /// 배경색 방식에서 주변보다 얼마나 진하게(어두운 배경이면 밝게) 할지 (0 ~ 0.2). 0이면 배경과 완전히 같은 색
    public var backgroundTint: Double
    /// 블러 위 반투명 막 색을 창 배경색에 맞춤 (끄면 colorHex 사용)
    public var veilMatchesBackground: Bool

    public init(kind: BlindStyleKind = .blur, intensity: Double = 0.9, cornerRadius: Double = 6, padding: Double = 3,
                colorHex: String = "#D9D9DE", imagePath: String? = nil, imageMode: ImageFillMode = .fill,
                showRevealOutline: Bool = true, veilMatchesBackground: Bool = true, opacity: Double = 1.0,
                backgroundTint: Double = 0.04) {
        self.kind = kind
        self.intensity = intensity
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.colorHex = colorHex
        self.imagePath = imagePath
        self.imageMode = imageMode
        self.showRevealOutline = showRevealOutline
        self.veilMatchesBackground = veilMatchesBackground
        self.opacity = opacity
        self.backgroundTint = backgroundTint
    }

    /// 모자이크 한 칸 크기 (pt). 강도 0 → 8pt, 1 → 32pt. 이름을 읽을 수 없도록 최소 8pt.
    public var mosaicCell: Double { 8 + 24 * max(0, min(1, intensity)) }
    /// 블러 반경 (pt). 강도 0 → 10pt, 1 → 40pt.
    public var blurRadius: Double { 10 + 30 * max(0, min(1, intensity)) }
    /// 블러 위에 덮는 반투명 막의 불투명도. 강도 0 → 0.2, 1 → 0.75 (사진 윤곽까지 거의 안 보이게)
    public var blurVeilOpacity: Double { 0.2 + 0.55 * max(0, min(1, intensity)) }

    enum CodingKeys: String, CodingKey { case kind, intensity, cornerRadius, padding, colorHex, imagePath, imageMode, showRevealOutline, veilMatchesBackground, opacity, backgroundTint }
    public init(from decoder: Decoder) throws {
        let d = BlindStyle()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(BlindStyleKind.self, forKey: .kind) ?? d.kind
        intensity = try c.decodeIfPresent(Double.self, forKey: .intensity) ?? d.intensity
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? d.cornerRadius
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? d.padding
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? d.colorHex
        imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath)
        imageMode = try c.decodeIfPresent(ImageFillMode.self, forKey: .imageMode) ?? d.imageMode
        showRevealOutline = try c.decodeIfPresent(Bool.self, forKey: .showRevealOutline) ?? d.showRevealOutline
        veilMatchesBackground = try c.decodeIfPresent(Bool.self, forKey: .veilMatchesBackground) ?? d.veilMatchesBackground
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? d.opacity
        backgroundTint = try c.decodeIfPresent(Double.self, forKey: .backgroundTint) ?? d.backgroundTint
    }
}

// MARK: - 클릭 공개

public enum RevealDuration: Int, Codable, CaseIterable, Sendable {
    case seconds3 = 3, seconds5 = 5, seconds10 = 10, manual = 0

    public var title: String {
        switch self {
        case .seconds3: return "3초"
        case .seconds5: return "5초"
        case .seconds10: return "10초"
        case .manual: return "직접 닫을 때까지"
        }
    }
    public var interval: TimeInterval? { self == .manual ? nil : TimeInterval(rawValue) }
}

// MARK: - 전체 가림 방식

public enum CoverMode: String, Codable, CaseIterable, Sendable {
    /// 프로필 + 이름 + 그 사람의 대화(말풍선·사진·이모티콘), 알림 카드 전체
    case conversation
    /// 이름과 프로필 사진(얼굴)만. 대화 내용과 알림 본문은 보임
    case profileOnly

    public var title: String {
        switch self {
        case .conversation: return "대화까지 가리기"
        case .profileOnly: return "이름·프로필만 가리기"
        }
    }
}

// MARK: - 앱별 가림 범위

public enum CoverScope: String, Codable, CaseIterable, Sendable {
    /// 화면 구조를 보고 연관 영역(프로필+이름+말풍선/목록 행/알림 카드)을 자동 판단.
    /// 판단이 어려우면 이름만 가린다.
    case auto
    case nameOnly
    case nameAndAvatar
    /// 목록형: 프로필 + 이름 + 상태메시지/미리보기 한 줄 전체 폭
    case row
    /// 사용자 지정: 이름 기준으로 상하좌우 확장
    case custom

    public var title: String {
        switch self {
        case .auto: return "자동 (연관 영역 판단)"
        case .nameOnly: return "이름만"
        case .nameAndAvatar: return "이름 + 프로필 사진"
        case .row: return "목록 한 줄 전체"
        case .custom: return "직접 지정"
        }
    }
}

public struct CustomInsets: Codable, Equatable, Sendable {
    /// 이름 영역 기준 확장량 (pt)
    public var left: Double
    public var top: Double
    public var right: Double
    public var bottom: Double
    /// 오른쪽을 창 끝까지
    public var toRightEdge: Bool

    public init(left: Double = 56, top: Double = 8, right: Double = 0, bottom: Double = 40, toRightEdge: Bool = true) {
        self.left = left; self.top = top; self.right = right; self.bottom = bottom; self.toRightEdge = toRightEdge
    }
}

public struct AppRule: Codable, Identifiable, Equatable, Sendable {
    /// 번들 ID
    public var id: String
    public var displayName: String
    public var enabled: Bool
    public var scope: CoverScope
    public var custom: CustomInsets
    /// 앱 자체 토스트(작은 알림 창)도 감시
    public var watchToasts: Bool

    public init(id: String, displayName: String, enabled: Bool = true, scope: CoverScope = .auto,
                custom: CustomInsets = CustomInsets(), watchToasts: Bool = true) {
        self.id = id; self.displayName = displayName; self.enabled = enabled
        self.scope = scope; self.custom = custom; self.watchToasts = watchToasts
    }

    enum CodingKeys: String, CodingKey { case id, displayName, enabled, scope, custom, watchToasts }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? id
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        scope = try c.decodeIfPresent(CoverScope.self, forKey: .scope) ?? .auto
        custom = try c.decodeIfPresent(CustomInsets.self, forKey: .custom) ?? CustomInsets()
        watchToasts = try c.decodeIfPresent(Bool.self, forKey: .watchToasts) ?? true
    }
}

// MARK: - 인식 설정

public enum PerformanceMode: String, Codable, CaseIterable, Sendable {
    case responsive, balanced, saver

    public var title: String {
        switch self {
        case .responsive: return "빠름 (반응 우선)"
        case .balanced: return "균형"
        case .saver: return "절약 (배터리 우선)"
        }
    }
    /// 화면 캡처 최대 프레임 수 (초당)
    public var captureFPS: Int {
        switch self { case .responsive: return 30; case .balanced: return 15; case .saver: return 6 }
    }
    /// 인식(OCR/접근성) 최소 간격 (초)
    public var minRecognitionInterval: TimeInterval {
        switch self { case .responsive: return 0.06; case .balanced: return 0.2; case .saver: return 0.6 }
    }
}

public enum MatchMode: String, Codable, CaseIterable, Sendable {
    /// 단어 단위로 일치 (+ '님', '씨' 같은 호칭/조사 허용)
    case word
    /// 문장 안에 포함되기만 하면
    case contains
    /// 포함 + OCR 오인식 1글자(자모) 허용
    case fuzzy

    public var title: String {
        switch self {
        case .word: return "단어 일치 (권장)"
        case .contains: return "포함"
        case .fuzzy: return "포함 + 오인식 허용"
        }
    }
}

public struct RecognitionSettings: Codable, Equatable, Sendable {
    public var performance: PerformanceMode
    public var matchMode: MatchMode
    /// 접근성(Accessibility) 정보 우선 사용
    public var useAccessibility: Bool
    /// 화면 OCR 보조 인식
    public var useOCR: Bool
    /// 새 알림/토스트 창은 인식이 끝날 때까지 먼저 가림 (순간 노출 방지)
    public var preBlindNewPopups: Bool
    /// 스크롤 중 이전 가림막을 예상 위치로 즉시 이동
    public var predictScroll: Bool
    /// 화면이 그대로인데 한 번 놓친 경우 유지할 인식 횟수
    public var holdMissedPasses: Int
    /// 본문에 이름이 언급된 경우(보낸 사람이 아닌 경우) 이름 글자는 가림
    public var hideMentions: Bool
    /// macOS 알림 배너(알림 센터)도 감시
    public var watchNotificationCenter: Bool

    public init(performance: PerformanceMode = .balanced, matchMode: MatchMode = .word, useAccessibility: Bool = true,
                useOCR: Bool = true, preBlindNewPopups: Bool = true, predictScroll: Bool = true, holdMissedPasses: Int = 1,
                hideMentions: Bool = true, watchNotificationCenter: Bool = true) {
        self.performance = performance; self.matchMode = matchMode; self.useAccessibility = useAccessibility
        self.useOCR = useOCR; self.preBlindNewPopups = preBlindNewPopups; self.predictScroll = predictScroll
        self.holdMissedPasses = holdMissedPasses; self.hideMentions = hideMentions
        self.watchNotificationCenter = watchNotificationCenter
    }

    enum CodingKeys: String, CodingKey {
        case performance, matchMode, useAccessibility, useOCR, preBlindNewPopups, predictScroll, holdMissedPasses, hideMentions, watchNotificationCenter
    }
    public init(from decoder: Decoder) throws {
        let d = RecognitionSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        performance = try c.decodeIfPresent(PerformanceMode.self, forKey: .performance) ?? d.performance
        matchMode = try c.decodeIfPresent(MatchMode.self, forKey: .matchMode) ?? d.matchMode
        useAccessibility = try c.decodeIfPresent(Bool.self, forKey: .useAccessibility) ?? d.useAccessibility
        useOCR = try c.decodeIfPresent(Bool.self, forKey: .useOCR) ?? d.useOCR
        preBlindNewPopups = try c.decodeIfPresent(Bool.self, forKey: .preBlindNewPopups) ?? d.preBlindNewPopups
        predictScroll = try c.decodeIfPresent(Bool.self, forKey: .predictScroll) ?? d.predictScroll
        holdMissedPasses = try c.decodeIfPresent(Int.self, forKey: .holdMissedPasses) ?? d.holdMissedPasses
        hideMentions = try c.decodeIfPresent(Bool.self, forKey: .hideMentions) ?? d.hideMentions
        watchNotificationCenter = try c.decodeIfPresent(Bool.self, forKey: .watchNotificationCenter) ?? d.watchNotificationCenter
    }
}

// MARK: - 전체 설정

public struct AppSettings: Codable, Equatable, Sendable {
    public var people: [Person]
    /// 가릴 단체방
    public var rooms: [Room]
    public var apps: [AppRule]
    public var style: BlindStyle
    public var reveal: RevealDuration
    public var recognition: RecognitionSettings
    public var paused: Bool
    /// 전체 가림 방식: 대화까지 / 이름+프로필만
    public var coverMode: CoverMode
    /// 메신저 창 오른쪽에 켜기/끄기 버튼 표시
    public var showToggleButton: Bool

    public init(people: [Person] = [], rooms: [Room] = [], apps: [AppRule] = AppSettings.defaultApps, style: BlindStyle = BlindStyle(),
                reveal: RevealDuration = .seconds5, recognition: RecognitionSettings = RecognitionSettings(), paused: Bool = false, coverMode: CoverMode = .conversation, showToggleButton: Bool = true) {
        self.people = people; self.rooms = rooms; self.apps = apps; self.style = style; self.reveal = reveal
        self.recognition = recognition; self.paused = paused; self.coverMode = coverMode; self.showToggleButton = showToggleButton
    }

    /// 처음 실행 시 기본으로 넣어 두는 메신저 (사용자가 켜거나 지울 수 있음).
    /// NAVER WORKS는 설치본마다 번들 ID가 달라 앱이 실행될 때 이름으로 찾아 맨 위에 자동 등록한다.
    public static let defaultApps: [AppRule] = [
        AppRule(id: "com.kakao.KakaoTalkMac", displayName: "카카오톡", enabled: false),
        AppRule(id: "com.tinyspeck.slackmacgap", displayName: "Slack", enabled: false),
        AppRule(id: "com.microsoft.teams2", displayName: "Microsoft Teams", enabled: false),
        AppRule(id: "jp.naver.line.mac", displayName: "LINE", enabled: false),
    ]

    /// macOS 알림 센터(배너) 프로세스 번들 ID
    public static let notificationCenterBundleID = "com.apple.notificationcenterui"

    public func rule(for bundleID: String?) -> AppRule? {
        guard let bundleID else { return nil }
        return apps.first { $0.id == bundleID }
    }

    public var activePeople: [Person] { people.filter { $0.enabled && !$0.allNames.isEmpty } }
    public var activeRooms: [Room] { rooms.filter { $0.enabled && !$0.asPerson.allNames.isEmpty } }
    /// 가릴 대상(사람 또는 방)이 하나라도 있는지
    public var hasTargets: Bool { !activePeople.isEmpty || !activeRooms.isEmpty }

    enum CodingKeys: String, CodingKey { case people, rooms, apps, style, reveal, recognition, paused, coverMode, showToggleButton }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        people = try c.decodeIfPresent([Person].self, forKey: .people) ?? []
        rooms = try c.decodeIfPresent([Room].self, forKey: .rooms) ?? []
        apps = try c.decodeIfPresent([AppRule].self, forKey: .apps) ?? AppSettings.defaultApps
        style = try c.decodeIfPresent(BlindStyle.self, forKey: .style) ?? BlindStyle()
        reveal = try c.decodeIfPresent(RevealDuration.self, forKey: .reveal) ?? .seconds5
        recognition = try c.decodeIfPresent(RecognitionSettings.self, forKey: .recognition) ?? RecognitionSettings()
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        coverMode = try c.decodeIfPresent(CoverMode.self, forKey: .coverMode) ?? .conversation
        showToggleButton = try c.decodeIfPresent(Bool.self, forKey: .showToggleButton) ?? true
    }
}

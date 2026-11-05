import AppKit

/// 설치·실행 중인 메신저를 찾아 감시 대상으로 자동 등록한다.
/// NAVER WORKS는 배포 경로(웹 설치본/App Store)에 따라 번들 ID가 다를 수 있어 이름으로 찾는다.
enum AppDiscovery {
    struct Found: Equatable {
        let bundleID: String
        let name: String
    }

    private static let naverWorksNames = ["naver works", "naverworks", "네이버 웍스", "네이버웍스", "works mobile", "worksmobile"]

    static func isNaverWorks(name: String?, bundleID: String?) -> Bool {
        let n = (name ?? "").lowercased()
        let b = (bundleID ?? "").lowercased()
        if b.contains("helper") { return false }                       // Electron 보조 프로세스 제외
        if naverWorksNames.contains(where: { n.contains($0) }) { return true }
        return b.contains("worksmobile") || (b.contains("naver") && b.contains("works"))
    }

    /// 실행 중인 앱 + /Applications, ~/Applications 에서 NAVER WORKS 찾기
    static func findNaverWorks() -> [Found] {
        var found: [String: String] = [:]
        let own = Bundle.main.bundleIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != own else { continue }
            if isNaverWorks(name: app.localizedName, bundleID: id) { found[id] = app.localizedName ?? "NAVER WORKS" }
        }
        let fm = FileManager.default
        let dirs = [URL(fileURLWithPath: "/Applications"),
                    fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in items where url.pathExtension == "app" {
                let name = url.deletingPathExtension().lastPathComponent
                guard let id = Bundle(url: url)?.bundleIdentifier, id != own else { continue }
                if isNaverWorks(name: name, bundleID: id) { found[id] = name }
            }
        }
        return found.map { Found(bundleID: $0.key, name: $0.value) }.sorted { $0.bundleID < $1.bundleID }
    }
}

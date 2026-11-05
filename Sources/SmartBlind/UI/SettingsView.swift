import CoreGraphics
import SwiftUI
import SmartBlindCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            PeopleSettingsView()
                .tabItem { Label("대상", systemImage: "person.crop.circle.badge.xmark") }
            StyleSettingsView()
                .tabItem { Label("블라인드", systemImage: "square.grid.3x3.fill") }
            RecognitionSettingsView()
                .tabItem { Label("인식", systemImage: "text.viewfinder") }
            AppsSettingsView()
                .tabItem { Label("앱별 범위", systemImage: "macwindow.on.rectangle") }
            StatusSettingsView()
                .tabItem { Label("상태", systemImage: "gauge.with.dots.needle.33percent") }
        }
        .padding(16)
    }
}

/// 설정 화면 공통 도우미
extension Binding where Value == String {
    /// "a, b, c" ↔ ["a","b","c"]
    static func commaList(_ source: Binding<[String]>) -> Binding<String> {
        Binding<String>(
            get: { source.wrappedValue.joined(separator: ",") },
            set: { text in
                // 입력한 그대로 왕복되도록 공백/빈 항목을 건드리지 않음 (매칭할 때 앞뒤 공백·빈 항목은 무시됨)
                source.wrappedValue = text.replacingOccurrences(of: "\n", with: ",").components(separatedBy: ",")
            }
        )
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
        }
    }
}

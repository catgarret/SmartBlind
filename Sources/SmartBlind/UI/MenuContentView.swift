import CoreGraphics
import SwiftUI
import SmartBlindCore

/// 메뉴 막대 아이콘을 눌렀을 때 나오는 작은 창
struct MenuContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: model.settings.paused ? "eye" : "eye.slash.fill")
                    .foregroundStyle(model.settings.paused ? Color.secondary : Color.accentColor)
                Text("SmartBlind").font(.headline)
                Spacer()
                Text(stateText).font(.caption).foregroundStyle(.secondary)
            }

            if !model.screenCaptureGranted || !model.accessibilityGranted {
                VStack(alignment: .leading, spacing: 6) {
                    Label("권한이 필요해요", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.subheadline.weight(.semibold))
                    if !model.screenCaptureGranted {
                        Button("화면 기록 권한 열기") { model.requestScreenCapture() }.controlSize(.small)
                    }
                    if !model.accessibilityGranted {
                        Button("손쉬운 사용 권한 열기") { model.requestAccessibility() }.controlSize(.small)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
            }

            if !model.naverWorksWatched {
                HStack {
                    Image(systemName: "questionmark.app.dashed").foregroundStyle(.orange)
                    Text("NAVER WORKS가 등록되지 않았어요").font(.callout)
                    Spacer()
                    Button("찾기") { model.ensureNaverWorks(force: true) }.controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                row("감시 중", model.status.watchedApps.isEmpty ? "-" : model.status.watchedApps.joined(separator: ", "))
                row("가림", "\(model.status.blindCount)개")
                row("대상 인물", "\(model.settings.people.filter { $0.enabled }.count)명")
            }
            .font(.callout)

            Divider()

            Picker("", selection: $model.settings.coverMode) {
                ForEach(CoverMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Toggle(isOn: Binding(get: { !model.settings.paused }, set: { model.settings.paused = !$0 })) {
                Text("블라인드 켜기")
            }
            .toggleStyle(.switch)

            HStack {
                Button("공개한 것 다시 가리기") { model.hideAllRevealed() }
                Spacer()
            }
            HStack {
                Button("설정…") { SettingsWindowController.shared.show() }
                    .keyboardShortcut(",")
                Spacer()
                Button("종료") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 290)
    }

    private var stateText: String {
        if model.settings.paused { return "일시정지" }
        if model.settings.activePeople.isEmpty { return "대상 없음" }
        return model.status.running ? "작동 중" : "대기"
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(v).lineLimit(2)
        }
    }
}

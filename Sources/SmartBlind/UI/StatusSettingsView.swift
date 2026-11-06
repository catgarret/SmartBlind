import CoreGraphics
import SwiftUI
import SmartBlindCore

/// 상태: 감시 중인 앱, 감지 수, 권한, 일시정지
struct StatusSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("작동") {
                Toggle("블라인드 켜기", isOn: Binding(get: { !model.settings.paused }, set: { model.settings.paused = !$0 }))
                LabeledContent("상태", value: stateText)
                LabeledContent("감시 중인 앱", value: model.status.watchedApps.isEmpty ? "-" : model.status.watchedApps.joined(separator: ", "))
                LabeledContent("감시 중인 창", value: "\(model.status.windowCount)개")
                LabeledContent("감지한 대상", value: "\(model.status.blindCount)곳")
                LabeledContent("최근 인식 시간", value: model.status.lastRecognitionMS > 0 ? "\(model.status.lastRecognitionMS)ms" : "-")
                LabeledContent("클릭 공개 방식", value: model.status.clickMode)
            }
            Section {
                permissionRow(title: "화면 기록", detail: "메신저 화면 글자 인식(OCR), 모자이크/블러", granted: model.screenCaptureGranted) {
                    model.requestScreenCapture()
                }
                permissionRow(title: "손쉬운 사용", detail: "메신저 텍스트 읽기, 가림막 클릭 처리, Option+클릭 전달", granted: model.accessibilityGranted) {
                    model.requestAccessibility()
                }
            } header: {
                Text("권한")
            } footer: {
                Text("권한을 켠 뒤에도 반영되지 않으면 SmartBlind를 종료했다가 다시 실행하세요. 앱을 다시 빌드하면 macOS가 권한을 초기화할 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("기타") {
                Toggle("로그인 시 자동 실행", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                HStack {
                    Button("설정 파일 보기") { model.revealSettingsFile() }
                    Button("공개한 것 다시 가리기") { model.hideAllRevealed() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var stateText: String {
        if model.settings.paused { return "일시정지" }
        if !model.settings.hasTargets { return "가릴 사람이나 단체방을 추가하세요" }
        return model.status.running ? "작동 중" : "대기"
    }

    private func permissionRow(title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.red)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("권한 열기", action: action) }
        }
    }
}

import CoreGraphics
import SwiftUI
import SmartBlindCore

/// 인식 빈도·성능, 이름 일치 방식, 접근성/OCR
struct RecognitionSettingsView: View {
    @EnvironmentObject var model: AppModel

    private var rec: Binding<RecognitionSettings> { $model.settings.recognition }

    var body: some View {
        Form {
            Section("성능") {
                Picker("인식 빈도", selection: rec.performance) {
                    ForEach(PerformanceMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(performanceHelp).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("이름 일치 방식", selection: rec.matchMode) {
                    ForEach(MatchMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("다른 사람 글에 이름이 언급되면 이름 글자만 가리기", isOn: rec.hideMentions)
            } header: {
                Text("이름 일치")
            } footer: {
                Text(matchHelp).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("접근성 정보 우선 사용", isOn: rec.useAccessibility)
                Toggle("화면 글자 인식(OCR) 보조", isOn: rec.useOCR)
                LabeledContent("OCR 언어", value: model.ocrLanguages.joined(separator: ", "))
            } header: {
                Text("인식 방법")
            } footer: {
                Text("접근성 정보를 주는 메신저는 더 빠르고 정확합니다. 그렇지 않은 앱(카카오톡 대화 내용 등)은 화면을 읽어(OCR) 찾습니다. 둘 다 켜 두는 것을 권장합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("macOS 알림 배너도 가리기", isOn: rec.watchNotificationCenter)
                Toggle("새 알림·토스트는 확인될 때까지 먼저 가리기", isOn: rec.preBlindNewPopups)
                Toggle("스크롤 중 가림막을 예상 위치로 먼저 이동", isOn: rec.predictScroll)
                Stepper(value: rec.holdMissedPasses, in: 0...3) {
                    LabeledContent("화면 변화 없이 인식을 놓쳤을 때 유지", value: "\(model.settings.recognition.holdMissedPasses)회")
                }
            } header: {
                Text("노출 방지")
            } footer: {
                Text("'먼저 가리기'를 켜면 새 알림이 뜨는 순간 잠깐(0.1~0.5초) 가렸다가, 대상이 아니면 바로 풀립니다. 화면이 바뀌었는데 이름이 사라지면 가림막은 즉시 제거됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var performanceHelp: String {
        let p = model.settings.recognition.performance
        return "화면 캡처 최대 \(p.captureFPS)fps, 인식 간격 최소 \(Int(p.minRecognitionInterval * 1000))ms. 화면이 바뀌지 않으면 인식하지 않습니다."
    }

    private var matchHelp: String {
        switch model.settings.recognition.matchMode {
        case .word: return "'홍길동', '홍길동님', '홍길동[회사]'는 찾고 '홍길동수'처럼 다른 이름은 건너뜁니다. 영문 아이디는 정확히 같아야 합니다."
        case .contains: return "이름이 글자 안에 들어 있기만 하면 찾습니다. 비슷한 이름의 다른 사람도 가려질 수 있습니다."
        case .fuzzy: return "OCR이 한 글자를 잘못 읽어도(예: 효→호) 찾습니다. 이름이 비슷한 다른 사람도 가려질 수 있습니다."
        }
    }
}

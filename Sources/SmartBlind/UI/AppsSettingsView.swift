import CoreGraphics
import AppKit
import SwiftUI
import SmartBlindCore

/// 감시할 앱 선택 + 앱별 가림 범위
struct AppsSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 0) {
                List(selection: $model.selectedAppID) {
                    ForEach($model.settings.apps) { $app in
                        HStack {
                            Toggle("", isOn: $app.enabled).labelsHidden()
                            if let icon = Self.icon(for: app.id) {
                                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.displayName)
                                Text(app.scope.title).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(app.id)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                HStack(spacing: 4) {
                    Menu {
                        ForEach(runningCandidates, id: \.bundleIdentifier) { app in
                            Button(app.localizedName ?? app.bundleIdentifier ?? "?") { add(app) }
                        }
                    } label: { Image(systemName: "plus") }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    Button { remove() } label: { Image(systemName: "minus") }
                        .buttonStyle(.borderless)
                        .disabled(model.selectedAppID == nil)
                    Spacer()
                }
                .padding(.top, 6)
                Button {
                    let found = model.ensureNaverWorks(force: true)
                    if let first = found.first {
                        model.selectedAppID = first.bundleID
                        model.discoveryMessage = "NAVER WORKS 등록됨 (\(first.bundleID))"
                    } else {
                        model.discoveryMessage = "NAVER WORKS를 찾지 못했어요. NAVER WORKS를 실행한 뒤 다시 눌러 주세요."
                    }
                } label: {
                    Label("NAVER WORKS 찾아서 등록", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .padding(.top, 8)
                if let message = model.discoveryMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
                HStack {
                    TextField("번들 ID 직접 추가", text: $model.manualBundleID).textFieldStyle(.roundedBorder)
                    Button("추가") { addManual() }.disabled(model.manualBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.top, 6)
                Toggle("macOS 알림 배너", isOn: $model.settings.recognition.watchNotificationCenter)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 250)

            if let sel = model.selectedAppID, model.settings.apps.contains(where: { $0.id == sel }) {
                AppRuleEditor(rule: Binding(
                    get: { model.settings.apps.first(where: { $0.id == sel }) ?? AppRule(id: sel, displayName: sel) },
                    set: { new in if let i = model.settings.apps.firstIndex(where: { $0.id == sel }) { model.settings.apps[i] = new } }
                ))
                .id(sel)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "감시할 앱",
                                  subtitle: "켜 둔 앱의 창과, 그 앱이 띄우는 자체 알림(토스트)에서 이름을 찾습니다. NAVER WORKS는 설치돼 있으면 자동으로 맨 위에 등록됩니다. 다른 앱은 왼쪽 + 버튼으로 추가하세요.")
                    Text("앱을 선택하면 가림 범위(이름만 / 프로필 포함 / 목록 한 줄 / 직접 지정)를 바꿀 수 있습니다.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var runningCandidates: [NSRunningApplication] {
        let existing = Set(model.settings.apps.map { $0.id })
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && !existing.contains($0.bundleIdentifier!) }
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func add(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier else { return }
        model.settings.apps.append(AppRule(id: id, displayName: app.localizedName ?? id))
        model.selectedAppID = id
    }

    private func addManual() {
        let id = model.manualBundleID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !model.settings.apps.contains(where: { $0.id == id }) else { return }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
        model.settings.apps.append(AppRule(id: id, displayName: name))
        model.selectedAppID = id
        model.manualBundleID = ""
    }

    private func remove() {
        guard let sel = model.selectedAppID else { return }
        model.settings.apps.removeAll { $0.id == sel }
        model.selectedAppID = nil
    }

    static func icon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

struct AppRuleEditor: View {
    @Binding var rule: AppRule

    var body: some View {
        Form {
            Section {
                TextField("표시 이름", text: $rule.displayName)
                LabeledContent("번들 ID", value: rule.id)
                Toggle("이 앱 감시", isOn: $rule.enabled)
                Toggle("앱 자체 알림(토스트)·작은 창도 감시", isOn: $rule.watchToasts)
            }
            Section {
                Picker("가림 범위", selection: $rule.scope) {
                    ForEach(CoverScope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text(help).font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("가림 범위")
            }
            if rule.scope == .custom {
                Section("직접 지정 (이름 기준으로 넓히기, pt)") {
                    stepper("왼쪽", $rule.custom.left)
                    stepper("위", $rule.custom.top)
                    stepper("아래", $rule.custom.bottom)
                    Toggle("오른쪽은 창 끝까지", isOn: $rule.custom.toRightEdge)
                    if !rule.custom.toRightEdge { stepper("오른쪽", $rule.custom.right) }
                    HStack {
                        Button("목록형 프리셋") { rule.custom = CustomInsets(left: 56, top: 10, right: 0, bottom: 26, toRightEdge: true) }
                        Button("대화형 프리셋") { rule.custom = CustomInsets(left: 56, top: 8, right: 0, bottom: 80, toRightEdge: false) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func stepper(_ title: String, _ value: Binding<Double>) -> some View {
        Stepper(value: value, in: 0...400, step: 4) {
            LabeledContent(title, value: "\(Int(value.wrappedValue))")
        }
    }

    private var help: String {
        switch rule.scope {
        case .auto:
            return "프로필 사진을 찾으면 그 사람의 말풍선·사진·이모티콘(대화창) 또는 목록 한 줄(친구/채팅 목록)까지 가립니다. 다음 사람의 프로필이나 내 메시지가 나오면 멈춥니다. 구조를 판단할 수 없으면 이름만 가립니다."
        case .nameOnly: return "이름 글자만 가립니다."
        case .nameAndAvatar: return "이름과 왼쪽 프로필 사진을 가립니다."
        case .row: return "프로필 + 이름 + 아래 미리보기 한 줄을 창 끝까지 가립니다 (친구·채팅 목록용)."
        case .custom: return "이름 위치를 기준으로 지정한 만큼 넓혀 가립니다."
        }
    }
}

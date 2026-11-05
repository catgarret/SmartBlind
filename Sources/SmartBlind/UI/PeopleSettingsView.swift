import CoreGraphics
import SwiftUI
import SmartBlindCore

/// 대상 관리: 인물 추가·수정·삭제, 이름/별칭, ON/OFF, 적용 앱
struct PeopleSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 0) {
                List(selection: $model.selectedPersonID) {
                    ForEach(model.settings.people) { p in
                        HStack {
                            Image(systemName: p.enabled ? "eye.slash.fill" : "eye")
                                .foregroundStyle(p.enabled ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name.isEmpty ? "(이름 없음)" : p.name)
                                if !p.aliases.filter({ !$0.isEmpty }).isEmpty {
                                    Text(p.aliases.filter { !$0.isEmpty }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .tag(p.id)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                HStack(spacing: 4) {
                    Button { addPerson() } label: { Image(systemName: "plus") }
                    Button { removeSelected() } label: { Image(systemName: "minus") }
                        .disabled(model.selectedPersonID == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.top, 6)
            }
            .frame(width: 220)

            if let sel = model.selectedPersonID, model.settings.people.contains(where: { $0.id == sel }) {
                // 인덱스 대신 ID로 묶어, 편집 중 삭제해도 엉뚱한 사람을 덮어쓰지 않게
                PersonEditor(person: Binding(
                    get: { model.settings.people.first(where: { $0.id == sel }) ?? Person(id: sel, name: "") },
                    set: { new in if let i = model.settings.people.firstIndex(where: { $0.id == sel }) { model.settings.people[i] = new } }
                ), apps: model.settings.apps)
                .id(sel)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "가릴 사람을 추가하세요",
                                  subtitle: "화면에 이 이름이 보이면 프로필·이름·메시지·알림을 자동으로 가립니다. 얼굴이 아니라 '이름 글자'로 인식합니다.")
                    Button("사람 추가") { addPerson() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func addPerson() {
        let p = Person(name: "")
        model.settings.people.append(p)
        model.selectedPersonID = p.id
    }

    private func removeSelected() {
        guard let sel = model.selectedPersonID else { return }
        model.settings.people.removeAll { $0.id == sel }
        model.selectedPersonID = model.settings.people.first?.id
    }
}

struct PersonEditor: View {
    @Binding var person: Person
    let apps: [AppRule]

    var body: some View {
        Form {
            Section {
                TextField("대표 이름", text: $person.name, prompt: Text("예: 홍길동"))
                TextField("별칭", text: .commaList($person.aliases), prompt: Text("예: hong123, 길동  (쉼표로 구분)"))
                HStack {
                    Button("별칭 추천") { suggestAliases() }
                        .disabled(person.name.trimmingCharacters(in: .whitespaces).count < 3)
                    Text("성을 뺀 이름, 영문 표기 등을 추가하면 더 잘 찾습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("이 사람 가리기", isOn: $person.enabled)
            } header: {
                Text("이름")
            } footer: {
                Text("한 글자 별칭은 오탐이 많아 사용하지 않습니다. 짧은 별칭(예: 길동)은 본문에서 언급될 때 이름 글자만 가립니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("적용할 앱") {
                Toggle("감시 중인 모든 앱", isOn: Binding(
                    get: { person.appBundleIDs.isEmpty },
                    set: { all in person.appBundleIDs = all ? [] : apps.filter { $0.enabled }.map { $0.id } }
                ))
                if !person.appBundleIDs.isEmpty {
                    ForEach(apps) { app in
                        Toggle(app.displayName, isOn: Binding(
                            get: { person.appBundleIDs.contains(app.id) },
                            set: { on in
                                if on { if !person.appBundleIDs.contains(app.id) { person.appBundleIDs.append(app.id) } }
                                else { person.appBundleIDs.removeAll { $0 == app.id } }
                                if person.appBundleIDs.isEmpty { person.appBundleIDs = [app.id] }   // 하나는 남김
                            }
                        ))
                    }
                }
                Text("macOS 알림 배너는 어느 앱 알림인지와 관계없이 항상 적용됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// "홍길동" → "길동", 영문이면 소문자 등
    private func suggestAliases() {
        let n = person.name.trimmingCharacters(in: .whitespaces)
        var add: [String] = []
        let chars = Array(n)
        if chars.count == 3, chars.allSatisfy({ TextNormalizer.isHangulSyllable($0) }) {
            add.append(String(chars[1...]))
        }
        if chars.count == 4, chars.allSatisfy({ TextNormalizer.isHangulSyllable($0) }) {
            add.append(String(chars[2...]))   // 복성/네 글자 이름
        }
        if n.contains(" ") { add.append(n.replacingOccurrences(of: " ", with: "")) }
        for a in add where !person.aliases.contains(a) && a != n { person.aliases.append(a) }
    }
}

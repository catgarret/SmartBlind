import CoreGraphics
import SwiftUI
import SmartBlindCore

/// 단체방(대화방) 가리기: 목록에서 그 방 줄, 그 방을 열었을 때 대화 내용 전체
struct RoomsSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 0) {
                List(selection: $model.selectedRoomID) {
                    ForEach(model.settings.rooms) { r in
                        HStack {
                            Image(systemName: r.enabled ? "eye.slash.fill" : "eye")
                                .foregroundStyle(r.enabled ? Color.accentColor : Color.secondary)
                            Text(r.name.isEmpty ? "(이름 없음)" : r.name)
                        }
                        .tag(r.id)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                HStack(spacing: 4) {
                    Button { addRoom() } label: { Image(systemName: "plus") }
                    Button { removeRoom() } label: { Image(systemName: "minus") }
                        .disabled(model.selectedRoomID == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.top, 6)
            }
            .frame(width: 220)

            if let sel = model.selectedRoomID, model.settings.rooms.contains(where: { $0.id == sel }) {
                RoomEditor(room: Binding(
                    get: { model.settings.rooms.first(where: { $0.id == sel }) ?? Room(id: sel, name: "") },
                    set: { new in if let i = model.settings.rooms.firstIndex(where: { $0.id == sel }) { model.settings.rooms[i] = new } }
                ))
                .id(sel)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "가릴 단체방을 추가하세요",
                                  subtitle: "대화 목록에서 그 방 줄을 가리고, 그 방을 열면 제목줄 아래 대화 내용 전체를 가립니다. 특정 사람만 특정 방에서 가리려면 '대상' 탭의 '특정 방'을 쓰세요.")
                    Button("단체방 추가") { addRoom() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func addRoom() {
        let r = Room(name: "")
        model.settings.rooms.append(r)
        model.selectedRoomID = r.id
    }

    private func removeRoom() {
        guard let sel = model.selectedRoomID else { return }
        model.settings.rooms.removeAll { $0.id == sel }
        model.selectedRoomID = model.settings.rooms.first?.id
    }
}

struct RoomEditor: View {
    @Binding var room: Room

    var body: some View {
        Form {
            Section {
                TextField("방 이름", text: $room.name, prompt: Text("예: 디자인 2팀"))
                TextField("다른 이름", text: .commaList($room.aliases), prompt: Text("방 이름이 바뀌었거나 줄여 부르는 이름 (쉼표로 구분)"))
                Toggle("이 방 가리기", isOn: $room.enabled)
            } header: {
                Text("방")
            }
            Section {
                Toggle("대화 목록에서 이 방 줄 가리기", isOn: $room.hideInList)
                Toggle("이 방을 열면 대화 내용 전체 가리기", isOn: $room.hideInside)
            } header: {
                Text("가릴 곳")
            } footer: {
                Text("대화방 창 위쪽 제목에 방 이름이 보이면 그 아래를 모두 가립니다. 가린 곳을 클릭하면 잠깐 볼 수 있고, 창 오른쪽 버튼으로 전체를 끌 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

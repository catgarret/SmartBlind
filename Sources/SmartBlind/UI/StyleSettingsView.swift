import CoreGraphics
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SmartBlindCore

/// 블라인드 디자인 + 클릭 공개 시간
struct StyleSettingsView: View {
    @EnvironmentObject var model: AppModel

    private var style: Binding<BlindStyle> { $model.settings.style }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            Form {
                Section {
                    Picker("가림 방식", selection: $model.settings.coverMode) {
                        ForEach(CoverMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(model.settings.coverMode == .conversation
                         ? "프로필·이름과 그 사람의 대화(말풍선·사진·이모티콘), 알림 카드 전체를 가립니다."
                         : "이름과 프로필 사진(얼굴)만 가립니다. 대화 내용과 알림 본문은 보입니다.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("가림 방식")
                }
                Section("모양") {
                    Picker("방식", selection: style.kind) {
                        ForEach(BlindStyleKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if model.settings.style.kind == .mosaic || model.settings.style.kind == .blur {
                        LabeledContent("강도") {
                            Slider(value: style.intensity, in: 0...1)
                        }
                    }
                    if model.settings.style.kind == .blur {
                        Text("강도가 높을수록 블러 위 반투명 막이 짙어져 사진·이모티콘 윤곽까지 거의 보이지 않습니다. 막 색은 메신저 배경색에 맞추거나 직접 고를 수 있습니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if model.settings.style.kind == .blur {
                        Toggle("막 색을 메신저 배경색에 맞추기", isOn: style.veilMatchesBackground)
                    }
                    if model.settings.style.kind == .solid || model.settings.style.kind == .image
                        || (model.settings.style.kind == .blur && !model.settings.style.veilMatchesBackground) {
                        ColorPicker("색상", selection: Binding(
                            get: { Color(hex: model.settings.style.colorHex) },
                            set: { model.settings.style.colorHex = $0.hexString }
                        ), supportsOpacity: false)
                    }
                    if model.settings.style.kind == .image {
                        LabeledContent("이미지") {
                            HStack {
                                Text(model.settings.style.imagePath.map { ($0 as NSString).lastPathComponent } ?? "선택 안 함")
                                    .foregroundStyle(.secondary).lineLimit(1)
                                Button("선택…") { chooseImage() }
                            }
                        }
                        Picker("표시", selection: style.imageMode) {
                            ForEach(ImageFillMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    }
                }
                Section("크기·투명도") {
                    LabeledContent("불투명도") {
                        HStack {
                            Slider(value: style.opacity, in: 0.3...1.0, step: 0.05)
                            Text("\(Int((model.settings.style.opacity * 100).rounded()))%").monospacedDigit().frame(width: 44)
                        }
                    }
                    LabeledContent("모서리 둥글기") {
                        HStack { Slider(value: style.cornerRadius, in: 0...20); Text("\(Int(model.settings.style.cornerRadius))pt").monospacedDigit().frame(width: 40) }
                    }
                    LabeledContent("여백") {
                        HStack {
                            Text("안쪽").font(.caption).foregroundStyle(.secondary)
                            Slider(value: style.padding, in: -16...16, step: 1)
                            Text("바깥").font(.caption).foregroundStyle(.secondary)
                            Text(String(format: "%+dpt", Int(model.settings.style.padding))).monospacedDigit().frame(width: 44)
                        }
                    }
                    Text("+ 는 감지한 영역보다 넓게, − 는 안쪽으로 좁게 가립니다.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Picker("공개 시간", selection: $model.settings.reveal) {
                        ForEach(RevealDuration.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Toggle("공개 중 얇은 테두리 표시", isOn: style.showRevealOutline)
                    Toggle("메신저 창에 켜기/끄기 버튼 표시", isOn: $model.settings.showToggleButton)
                } header: {
                    Text("클릭해서 보기")
                } footer: {
                    Text("가림막을 클릭하면 잠시 보이고, 다시 클릭하거나 시간이 지나면 가려집니다. Option+클릭은 가림막을 통과해 메신저에 그대로 전달됩니다(예: 사진 열기). 스크롤은 항상 그대로 동작합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            VStack(alignment: .leading, spacing: 8) {
                Text("미리보기").font(.headline)
                BlindPreview(style: model.settings.style)
                    .frame(width: 220, height: 170)
            }
            .padding(.top, 8)
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.style.imagePath = url.path
        }
    }
}

/// 대략적인 모양 미리보기
struct BlindPreview: View {
    let style: BlindStyle

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor))
            VStack(alignment: .leading, spacing: 10) {
                sample
                HStack {
                    Spacer()
                    Text("나도 보고 싶다").font(.caption).padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.8)))
                }
            }
            .padding(12)
        }
    }

    private var sample: some View {
        let content = HStack(alignment: .top, spacing: 8) {
            Circle().fill(Color.orange).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text("홍길동[회사]").font(.caption)
                Text("점심 뭐 먹어요?").font(.caption).padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.18)))
            }
        }
        .padding(4)
        return content.overlay { cover }
    }

    @ViewBuilder private var cover: some View {
        let r = RoundedRectangle(cornerRadius: style.cornerRadius)
        switch style.kind {
        case .solid:
            r.fill(Color(hex: style.colorHex)).padding(-style.padding)
        case .blur:
            ZStack {
                r.fill(.thickMaterial)
                r.fill(Color(hex: style.colorHex).opacity(style.blurVeilOpacity))
            }
            .padding(-style.padding)
        case .mosaic:
            MosaicSwatch(cell: style.mosaicCell).clipShape(r).padding(-style.padding)
        case .image:
            r.fill(Color(hex: style.colorHex).opacity(0.9)).overlay(Image(systemName: "photo").foregroundStyle(.white)).padding(-style.padding)
        }
    }
}

struct MosaicSwatch: View {
    let cell: Double
    var body: some View {
        Canvas { ctx, size in
            let c = max(4, cell)
            var y = 0.0, row = 0
            while y < size.height {
                var x = 0.0, col = 0
                while x < size.width {
                    let shade = 0.55 + 0.25 * Double((row * 7 + col * 3) % 5) / 4
                    ctx.fill(Path(CGRect(x: x, y: y, width: c, height: c)), with: .color(Color(white: shade)))
                    x += c; col += 1
                }
                y += c; row += 1
            }
        }
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0xD9D9DE
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        let r = Int((ns.redComponent * 255).rounded()), g = Int((ns.greenComponent * 255).rounded()), b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

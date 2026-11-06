import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import SmartBlindCore

/// 모자이크/블러 이미지를 만든다 (GPU).
/// 가림막 영역마다 따로 처리해(영역 밖 픽셀은 쓰지 않음) 옆 줄·옆 말풍선 색이 번져 들어오지 않게 하고,
/// 결과를 창 크기 이미지 한 장에 모아 오버레이가 잘라 쓴다.
final class BlindRenderer {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let queue = DispatchQueue(label: "smartblind.render", qos: .userInteractive)

    /// - scale: 버퍼 픽셀 / pt
    /// - completion: 메인 스레드
    /// - background: 창 배경색 (블러 막 색을 배경에 맞출 때)
    /// - rects: 가림막 영역 (창 기준 pt, 왼쪽 위 원점)
    /// - veils: 영역별 막 색 (목록 줄은 그 줄의 배경색: 선택·마우스 올림 색을 따라감). rects와 같은 순서
    func render(buffer: CVPixelBuffer, style: BlindStyle, scale: CGFloat, background: RGBA?, rects: [CGRect], veils: [RGBA?] = [],
                completion: @escaping (CGImage?) -> Void) {
        let kind = style.kind
        let cell = CGFloat(style.mosaicCell) * scale
        let radius = CGFloat(style.blurRadius) * scale
        let veil = CGFloat(style.blurVeilOpacity)
        let intensity = CGFloat(max(0, min(1, style.intensity)))
        let base: CIColor
        if style.veilMatchesBackground, let bg = background, bg.a >= 16 {
            base = CIColor(red: CGFloat(bg.r) / 255, green: CGFloat(bg.g) / 255, blue: CGFloat(bg.b) / 255)
        } else {
            base = Self.veilColor(hex: style.colorHex)
        }
        let veilColor = CIColor(red: base.red, green: base.green, blue: base.blue, alpha: veil)
        let matchBackground = style.veilMatchesBackground
        queue.async { [context] in
            let full = CIImage(cvPixelBuffer: buffer)
            let fullExtent = full.extent
            var composite = CIImage.empty()
            for (index, r) in rects.enumerated() {
                var veilColor = veilColor
                if matchBackground, index < veils.count, let v = veils[index], v.a >= 16 {
                    veilColor = CIColor(red: CGFloat(v.r) / 255, green: CGFloat(v.g) / 255, blue: CGFloat(v.b) / 255, alpha: veil)
                }
                // pt(왼쪽 위 원점) → 버퍼 픽셀(CI는 왼쪽 아래 원점)
                let px = CGRect(x: r.minX * scale, y: fullExtent.height - r.maxY * scale,
                                width: r.width * scale, height: r.height * scale).integral.intersection(fullExtent)
                guard !px.isNull, px.width >= 2, px.height >= 2 else { continue }
                let input = full.cropped(to: px).clampedToExtent()
                let extent = px
                var output: CIImage?
            switch kind {
            case .mosaic:
                let f = CIFilter.pixellate()
                f.inputImage = input
                f.scale = Float(max(4, cell))
                f.center = CGPoint(x: extent.minX, y: extent.maxY)   // 창 왼쪽 위 기준으로 칸 정렬
                output = f.outputImage?.cropped(to: extent)
            case .blur:
                // 1) 큰 칸 모자이크로 글자·얼굴 윤곽을 먼저 없앰 (블러만 하면 사진은 형태가 비침)
                let p = CIFilter.pixellate()
                p.inputImage = input
                p.scale = Float(max(8, radius * 0.9))
                p.center = CGPoint(x: extent.minX, y: extent.maxY)
                // 2) 강한 가우시안 블러로 칸 경계까지 뭉갬
                let g = CIFilter.gaussianBlur()
                g.inputImage = (p.outputImage ?? input).clampedToExtent()
                g.radius = Float(max(6, radius))
                // 3) 대비·채도를 낮춰 밝고 어두운 덩어리도 흐리게
                let c = CIFilter.colorControls()
                c.inputImage = g.outputImage?.cropped(to: extent)
                c.contrast = Float(1 - 0.55 * intensity)
                c.saturation = Float(1 - 0.6 * intensity)
                // 4) 반투명 막을 덮어 거의 안 보이게
                let blurred = c.outputImage?.cropped(to: extent)
                let veilImage = CIImage(color: veilColor).cropped(to: extent)
                output = blurred.map { veilImage.composited(over: $0) }
            case .solid, .image, .background:
                output = nil
            }
                if let o = output?.cropped(to: extent) { composite = o.composited(over: composite) }
            }
            let cg = rects.isEmpty ? nil : context.createCGImage(composite, from: fullExtent)
            DispatchQueue.main.async { completion(cg) }
        }
    }

    /// 블러 막 색 (#RRGGBB). 기본은 옅은 회색
    static func veilColor(hex: String) -> CIColor {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0xD9D9DE
        return CIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255)
    }
}

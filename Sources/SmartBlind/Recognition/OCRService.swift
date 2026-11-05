import CoreGraphics
import CoreVideo
import Foundation
import SmartBlindCore
import Vision

/// Apple Vision 글자 인식 (한국어 + 영어)
///
/// - 한국어는 정확도 모드(.accurate)에서만 지원되므로 항상 정확도 모드
/// - 이름 인식이 목적이라 언어 보정(자동 교정)은 끔
final class OCRService {
    private let queue = DispatchQueue(label: "smartblind.ocr", qos: .userInteractive, attributes: .concurrent)
    let languages: [String]

    init() {
        let wanted = ["ko-KR", "en-US", "ja-JP", "zh-Hans"]
        let probe = VNRecognizeTextRequest()
        probe.recognitionLevel = .accurate
        probe.revision = VNRecognizeTextRequestRevision3
        let supported = (try? probe.supportedRecognitionLanguages()) ?? ["en-US"]
        let picked = wanted.filter { supported.contains($0) }
        languages = picked.isEmpty ? ["en-US"] : Array(picked.prefix(2))   // ko + en (언어가 많을수록 느려짐)
    }

    /// - roi: 창 기준(왼쪽 위 원점, pt) 관심 영역. nil이면 창 전체.
    /// - completion: OCR 큐에서 호출 (창 기준 좌표의 줄 목록)
    func recognize(buffer: CVPixelBuffer, pointSize: CGSize, roi: CGRect?, completion: @escaping ([TextLine]) -> Void) {
        let langs = languages
        queue.async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.revision = VNRecognizeTextRequestRevision3
            request.usesLanguageCorrection = false
            request.recognitionLanguages = langs
            // 기본값(이미지 높이의 1/32)이면 긴 창에서 작은 이름을 놓친다
            request.minimumTextHeight = Float(max(0.002, 7.0 / max(1, Double(roi?.height ?? pointSize.height))))

            var roiN = CGRect(x: 0, y: 0, width: 1, height: 1)
            if let roi, pointSize.width > 0, pointSize.height > 0 {
                let r = roi.intersection(CGRect(origin: .zero, size: pointSize))
                if !r.isNull, r.width > 4, r.height > 4 {
                    // Vision 정규화 좌표: 왼쪽 아래 원점
                    roiN = CGRect(x: r.minX / pointSize.width, y: 1 - r.maxY / pointSize.height,
                                  width: r.width / pointSize.width, height: r.height / pointSize.height)
                    request.regionOfInterest = roiN
                }
            }
            let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
            do { try handler.perform([request]) } catch { completion([]); return }

            let W = pointSize.width, H = pointSize.height
            // ROI 기준 정규화 → 창 기준 pt
            func toWindow(_ b: CGRect) -> CGRect {
                let nx = roiN.minX + b.minX * roiN.width
                let ny = roiN.minY + b.minY * roiN.height
                let nw = b.width * roiN.width
                let nh = b.height * roiN.height
                return CGRect(x: nx * W, y: (1 - ny - nh) * H, width: nw * W, height: nh * H)
            }
            var lines: [TextLine] = []
            for obs in request.results ?? [] {
                guard let cand = obs.topCandidates(1).first else { continue }
                let text = cand.string
                guard !text.isEmpty else { continue }
                let frame = toWindow(obs.boundingBox)
                let resolver: (Range<Int>) -> CGRect? = { range in
                    let count = text.count
                    guard range.lowerBound >= 0, range.upperBound <= count, range.lowerBound < range.upperBound else { return nil }
                    let lo = text.index(text.startIndex, offsetBy: range.lowerBound)
                    let hi = text.index(text.startIndex, offsetBy: range.upperBound)
                    guard let box = try? cand.boundingBox(for: lo..<hi) else { return nil }
                    return toWindow(box.boundingBox)
                }
                lines.append(TextLine(text: text, frame: frame, source: .ocr, container: nil, subrangeResolver: resolver))
            }
            completion(lines)
        }
    }
}

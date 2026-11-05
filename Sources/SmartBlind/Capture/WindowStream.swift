import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import SmartBlindCore

/// 캡처된 한 프레임
final class CapturedFrame {
    /// 원본 해상도 (Retina면 pt × 2) BGRA
    let buffer: CVPixelBuffer
    /// 분석용 1pt = 1px RGBA
    let pixels: PixelImage
    /// 행 특징 (변화·스크롤 감지)
    let signature: [Float]
    /// 창 크기 (pt)
    let pointSize: CGSize

    init(buffer: CVPixelBuffer, pixels: PixelImage, signature: [Float], pointSize: CGSize) {
        self.buffer = buffer
        self.pixels = pixels
        self.signature = signature
        self.pointSize = pointSize
    }
}

/// 창 하나를 ScreenCaptureKit으로 캡처한다. 다른 창에 가려져 있어도 그 창 내용만 받는다.
/// 화면이 바뀌지 않으면 프레임이 오지 않아(idle) OCR 반복을 자연스럽게 줄인다.
final class WindowStream: NSObject, SCStreamOutput, SCStreamDelegate {
    let windowID: CGWindowID
    /// 캡처 큐에서 호출
    var onFrame: ((CapturedFrame) -> Void)?
    /// 메인에서 호출
    var onStop: ((Error?) -> Void)?

    private var stream: SCStream?
    private let queue: DispatchQueue
    private var pointSize: CGSize = .zero
    private var scale: CGFloat = 2
    private var fps: Int = 15
    private(set) var isRunning = false

    init(windowID: CGWindowID) {
        self.windowID = windowID
        self.queue = DispatchQueue(label: "smartblind.capture.\(windowID)", qos: .userInteractive)
        super.init()
    }

    func start(window: SCWindow, pointSize: CGSize, scale: CGFloat, fps: Int, completion: @escaping (Error?) -> Void) {
        self.pointSize = pointSize
        self.scale = scale
        self.fps = fps
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let s = SCStream(filter: filter, configuration: makeConfig(), delegate: self)
        do {
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        } catch {
            completion(error)
            return
        }
        stream = s
        s.startCapture { [weak self] err in
            DispatchQueue.main.async {
                self?.isRunning = (err == nil)
                completion(err)
            }
        }
    }

    func update(pointSize: CGSize, scale: CGFloat, fps: Int) {
        guard let stream = self.stream else { return }
        let sizeChanged = abs(pointSize.width - self.pointSize.width) >= 1 || abs(pointSize.height - self.pointSize.height) >= 1
        guard sizeChanged || scale != self.scale || fps != self.fps else { return }
        self.pointSize = pointSize
        self.scale = scale
        self.fps = fps
        stream.updateConfiguration(makeConfig()) { _ in }
    }

    func stop() {
        guard let s = stream else { return }
        stream = nil
        isRunning = false
        s.stopCapture { _ in }
    }

    private func makeConfig() -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = max(2, Int((pointSize.width * scale).rounded()))
        c.height = max(2, Int((pointSize.height * scale).rounded()))
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.showsCursor = false
        c.queueDepth = 5
        c.ignoreShadowsSingleWindow = true
        return c
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw), status == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let size = pointSize
        guard size.width >= 2, size.height >= 2 else { return }
        let pixels = Self.downsample(buffer, to: size)
        let sig = ScrollEstimator.rowSignatures(pixels)
        onFrame?(CapturedFrame(buffer: buffer, pixels: pixels, signature: sig, pointSize: size))
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.isRunning = false
            self?.onStop?(error)
        }
    }

    /// BGRA 원본 → 1pt=1px RGBA (최근접 샘플링). 알파 유지 (알림 배너 카드 판별용)
    static func downsample(_ buffer: CVPixelBuffer, to size: CGSize) -> PixelImage {
        let w = max(1, Int(size.width.rounded()))
        let h = max(1, Int(size.height.rounded()))
        var out = [UInt8](repeating: 0, count: w * h * 4)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return PixelImage(width: w, height: h, data: out) }
        let bw = CVPixelBufferGetWidth(buffer), bh = CVPixelBufferGetHeight(buffer)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let src = base.assumingMemoryBound(to: UInt8.self)
        let sx = Double(bw) / Double(w), sy = Double(bh) / Double(h)
        for y in 0..<h {
            let syy = min(bh - 1, Int((Double(y) + 0.5) * sy))
            let row = src + syy * bpr
            var o = y * w * 4
            for x in 0..<w {
                let sxx = min(bw - 1, Int((Double(x) + 0.5) * sx))
                let p = row + sxx * 4
                out[o] = p[2]; out[o + 1] = p[1]; out[o + 2] = p[0]; out[o + 3] = p[3]
                o += 4
            }
        }
        return PixelImage(width: w, height: h, data: out)
    }
}

/// SCShareableContent 조회 (창 ID → SCWindow)
enum ShareableWindows {
    static func fetch(completion: @escaping ([CGWindowID: SCWindow]) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
            var map: [CGWindowID: SCWindow] = [:]
            for w in content?.windows ?? [] { map[w.windowID] = w }
            let result = map
            DispatchQueue.main.async { completion(result) }
        }
    }
}

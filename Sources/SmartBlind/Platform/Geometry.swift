import AppKit

/// 좌표계 변환
///
/// - CG 전역 좌표: 주 화면 왼쪽 위 원점, y 아래로 증가 (CGWindowList, 접근성 API, 마우스 이벤트 탭)
/// - Cocoa 좌표: 주 화면 왼쪽 아래 원점, y 위로 증가 (NSWindow/NSScreen)
/// - 창 기준 좌표: 대상 창 왼쪽 위 원점, pt (SmartBlindCore 전체)
enum ScreenGeometry {
    /// 메뉴 막대가 있는 주 화면의 높이. 다중 모니터에서도 변환 기준은 항상 이 화면.
    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    static func cocoaRect(fromCG r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func cgPoint(fromCocoa p: NSPoint) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    /// 창이 가장 많이 걸쳐 있는 화면의 배율 (Retina = 2)
    static func backingScale(forCG r: CGRect) -> CGFloat {
        let c = cocoaRect(fromCG: r)
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for s in NSScreen.screens {
            let i = s.frame.intersection(c)
            let area = i.isNull ? 0 : i.width * i.height
            if area > bestArea { bestArea = area; best = s }
        }
        return (best ?? NSScreen.main)?.backingScaleFactor ?? 2
    }
}

extension CGRect {
    /// 소수점 좌표를 바깥쪽 정수로
    var outwardIntegral: CGRect {
        let x0 = floor(minX), y0 = floor(minY), x1 = ceil(maxX), y1 = ceil(maxY)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

import UIKit
import CoreText

/// 한글 자음·모음 글자를 **"검은 외곽선 + 흰 속"** 색칠 도안 이미지로 렌더한다.
/// (기획/디자인 §기본 제공 한글 앨범 — 일러스트 에셋이 아니라 폰트 글리프 윤곽을 앱 내에서 생성.)
///
/// 원리: CoreText 로 글리프 **외곽선 path** 를 뽑아 `CGContext` 로 그린다.
///  - 속(interior)은 fill(흰/파스텔), 경계는 stroke(잉크) → `RegionPaintEngine` 이 글자 속을 "칸"으로 잡는다.
///  - **fill+stroke 를 직접 제어**하므로 NSAttributedString 으로는 못 하던 **둥근 모서리(`lineJoin/Cap = .round`)** 가 가능.
///
/// "더 뚱뚱하게 + 색칠 영역 넓힘"(2026-06-09 요청):
///  - 가장 굵은 한글 웨이트(**Heavy**)로 글자 몸통을 두껍게 → 칠할 속이 넓어짐.
///  - 글자가 도안에서 차지하는 비율(`glyphRatio`)을 키움(여백 축소).
///  - 모서리는 둥근 조인/캡으로 부드럽게.
///
/// UIKit/CoreText 렌더링은 백그라운드 스레드에서 안전하므로 `nonisolated` 로 둔다(시더가 오프메인 호출).
enum HangulGlyphRenderer {

    /// 외곽선 잉크색 = 디자인 Theme.ink (#3B3A4E). 채색 엔진의 경계 판정(어두운 픽셀)에 충분히 진하다.
    private static let ink = UIColor(red: 0x3B/255, green: 0x3A/255, blue: 0x4E/255, alpha: 1)
    /// 글리프가 도안에서 차지하는 비율(여백 ~12% → 76%). 클수록 색칠 영역↑.
    private static let glyphRatio: CGFloat = 0.76
    /// 외곽선 두께 = 도안 짧은변의 ~2.6%. (선은 얇게 유지 → 색칠 영역 안 깎임. 모서리 둥글기는 아래 path 라운딩이 담당.)
    private static let strokeRatio: CGFloat = 0.026
    /// 모서리 라운딩 반경 = 글리프 짧은변의 비율. 선 두께와 무관하게 **글리프 path 자체의 직선-직선 모서리**를 둥글린다.
    private static let cornerRoundFactor: CGFloat = 0.18

    /// 가장 굵은(Heavy) 한글 웨이트 우선 — 글자 몸통이 두꺼워 색칠 영역이 넓다.
    nonisolated private static func boldKoreanFontName() -> String {
        for name in ["AppleSDGothicNeo-Heavy", "AppleSDGothicNeo-ExtraBold", "AppleSDGothicNeo-Bold"] {
            if UIFont(name: name, size: 12) != nil { return name }
        }
        return UIFont.systemFont(ofSize: 12, weight: .black).fontName
    }

    /// 글자 → 글리프 외곽선 CGPath(폰트 좌표, y-up). 폰트가 한글 글리프를 못 가지면 cascade(`CTFontCreateForString`)로 보강.
    nonisolated private static func glyphPath(_ glyph: String, fontSize: CGFloat) -> CGPath? {
        let base = CTFontCreateWithName(boldKoreanFontName() as CFString, fontSize, nil)
        let ctFont = CTFontCreateForString(base, glyph as CFString,
                                           CFRange(location: 0, length: (glyph as NSString).length))
        let utf16 = Array(glyph.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        guard CTFontGetGlyphsForCharacters(ctFont, utf16, &glyphs, utf16.count),
              let g = glyphs.first else { return nil }
        return CTFontCreatePathForGlyph(ctFont, g, nil)
    }

    // MARK: 모서리 라운딩 (직선-직선 모서리를 기하학적으로 둥글림)

    /// 글리프 path 의 **직선만으로 이뤄진 윤곽(subpath)** 의 모서리를 반경 R 로 둥글린다.
    /// 곡선이 섞인 윤곽(ㅅ·ㅎ·ㅇ 등)은 원형 보존을 위해 그대로 통과. 선 두께와 무관하게 모서리만 다듬는다.
    nonisolated private static func roundedCorners(_ path: CGPath, factor: CGFloat) -> CGPath {
        enum Seg { case line(CGPoint); case quad(CGPoint, CGPoint); case curve(CGPoint, CGPoint, CGPoint) }
        struct Sub { var start = CGPoint.zero; var segs: [Seg] = []; var closed = false; var has = false }

        var subs: [Sub] = []
        var cur = Sub()
        path.applyWithBlock { ep in
            let e = ep.pointee
            switch e.type {
            case .moveToPoint:
                if cur.has { subs.append(cur) }
                cur = Sub(); cur.start = e.points[0]; cur.has = true
            // move 없이 들어온 세그먼트는 무시(유효 path는 항상 move 선행 — 가짜 (0,0) 정점 혼입 방지).
            case .addLineToPoint:      if cur.has { cur.segs.append(.line(e.points[0])) }
            case .addQuadCurveToPoint: if cur.has { cur.segs.append(.quad(e.points[0], e.points[1])) }
            case .addCurveToPoint:     if cur.has { cur.segs.append(.curve(e.points[0], e.points[1], e.points[2])) }
            case .closeSubpath:        if cur.has { cur.closed = true; subs.append(cur) }; cur = Sub()
            @unknown default: break
            }
        }
        if cur.has { subs.append(cur) }

        let bb = path.boundingBoxOfPath
        let R = min(bb.width, bb.height) * factor
        let out = CGMutablePath()

        for s in subs {
            let lineOnly = s.segs.allSatisfy { if case .line = $0 { return true }; return false }
            var v = [s.start]
            for seg in s.segs { if case .line(let p) = seg { v.append(p) } }
            // 닫힌(또는 시작≈끝) **직선 윤곽**만 라운딩. 곡선 포함/열린 윤곽은 원형·형태 보존 위해 원본 복제.
            let geomClosed = v.count >= 2 && hypot(v.first!.x - v.last!.x, v.first!.y - v.last!.y) < 1.0
            if lineOnly && (s.closed || geomClosed) {
                let poly = dedupAdjacent(v)         // 인접 중복 정점 제거(0길이 변 방지, 시작==끝 포함)
                if poly.count >= 3 { roundedPolygon(poly, radius: R, into: out); continue }
            }
            // 곡선 포함 윤곽(ㅅ·ㅎ·ㅇ) 또는 라운딩 부적합 → 원본 그대로 복제.
            out.move(to: s.start)
            for seg in s.segs {
                switch seg {
                case .line(let e):              out.addLine(to: e)
                case .quad(let c, let e):       out.addQuadCurve(to: e, control: c)
                case .curve(let c1, let c2, let e): out.addCurve(to: e, control1: c1, control2: c2)
                }
            }
            if s.closed { out.closeSubpath() }
        }
        return out
    }

    /// 인접한(그리고 시작↔끝) 중복 정점을 제거한다 — 0길이 변에서 라운드 모서리가 누락되는 것을 막는다.
    nonisolated private static func dedupAdjacent(_ pts: [CGPoint]) -> [CGPoint] {
        guard pts.count > 1 else { return pts }
        var r: [CGPoint] = []
        for p in pts {
            if let last = r.last, hypot(p.x - last.x, p.y - last.y) < 0.5 { continue }
            r.append(p)
        }
        if r.count > 1, let f = r.first, let l = r.last, hypot(f.x - l.x, f.y - l.y) < 0.5 { r.removeLast() }
        return r
    }

    /// 닫힌 다각형 정점들을 반경 R(정점별로 인접 변 절반으로 클램프)로 둥글려 `out` 에 추가한다.
    nonisolated private static func roundedPolygon(_ v: [CGPoint], radius R: CGFloat, into out: CGMutablePath) {
        let n = v.count
        guard n >= 3 else { return }
        func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        func unit(_ a: CGPoint, _ b: CGPoint) -> CGPoint {   // a→b 단위벡터
            let dx = b.x - a.x, dy = b.y - a.y, l = hypot(dx, dy)
            return l < 0.0001 ? .zero : CGPoint(x: dx / l, y: dy / l)
        }
        var t1 = [CGPoint](repeating: .zero, count: n)   // 들어오는 변에서 정점 근처(트림 끝점)
        var t2 = [CGPoint](repeating: .zero, count: n)   // 나가는 변에서 정점 근처(트림 시작점)
        for i in 0..<n {
            let p = v[(i - 1 + n) % n], c = v[i], nx = v[(i + 1) % n]
            let ri = min(R, dist(p, c) / 2, dist(c, nx) / 2)
            let up = unit(c, p), un = unit(c, nx)
            t1[i] = CGPoint(x: c.x + up.x * ri, y: c.y + up.y * ri)
            t2[i] = CGPoint(x: c.x + un.x * ri, y: c.y + un.y * ri)
        }
        out.move(to: t2[0])
        for i in 1...n {
            let j = i % n
            out.addLine(to: t1[j])                       // 직선 구간
            out.addQuadCurve(to: t2[j], control: v[j])   // 모서리 라운드(제어점=원래 꼭짓점)
        }
        out.closeSubpath()
    }

    /// 글자 한 자를 `rect` 중앙에 그린다(흰/파스텔 속 채움 + 둥근 잉크 외곽선).
    nonisolated private static func draw(_ glyph: String, in rect: CGRect, fill: UIColor, cg: CGContext) {
        guard let raw = glyphPath(glyph, fontSize: 256) else { return }
        let path = roundedCorners(raw, factor: cornerRoundFactor)
        let bbox = path.boundingBoxOfPath
        guard bbox.width > 0, bbox.height > 0 else { return }

        let avail = rect.width * glyphRatio
        let scale = min(avail / bbox.width, avail / bbox.height)
        let lineWidth = rect.width * strokeRatio

        cg.saveGState()
        cg.translateBy(x: rect.midX, y: rect.midY)
        cg.scaleBy(x: scale, y: -scale)            // 폰트 좌표(y-up) → 캔버스(y-down) 보정
        cg.translateBy(x: -bbox.midX, y: -bbox.midY)
        cg.setLineJoin(.round)                     // 모서리 둥글게
        cg.setLineCap(.round)
        cg.setLineWidth(lineWidth / scale)         // CTM 스케일 보정 → 의도한 device px 두께
        cg.setFillColor(fill.cgColor)
        cg.setStrokeColor(ink.cgColor)
        cg.addPath(path)
        cg.drawPath(using: .fillStroke)            // 속 채움 → 그 위 둥근 외곽선
        cg.restoreGState()
    }

    // MARK: - 공개 API (백그라운드 호출 안전)

    /// 글자 한 자 → 흰 배경 정사각 PNG(검은 외곽선 + 흰 속 = 색칠 도안).
    /// 색칠용(side≈1024)·썸네일용(side≈480)을 각각 직접 렌더해 선이 흐려지지 않게 한다.
    nonisolated static func outlineImage(_ glyph: String, side: CGFloat, fill: UIColor = .white) -> Data? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1                       // 픽셀=포인트(이미 픽셀 크기로 지정)
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            cg.setFillColor(UIColor.white.cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: side, height: side))
            draw(glyph, in: CGRect(x: 0, y: 0, width: side, height: side), fill: fill, cg: cg)
        }
        return image.pngData()
    }

    /// '한글' 앨범 커버 자동 생성 — 소프트 블루(#E9EEFF) 배경에 윤곽 글자 4자(2×2),
    /// 일부는 옅게 채워(인비팅). 전용 에셋 불필요(디자인 §32-1).
    nonisolated static func coverImage(side: CGFloat) -> Data? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            cg.setFillColor(UIColor(red: 0xE9/255, green: 0xEE/255, blue: 0xFF/255, alpha: 1).cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: side, height: side))

            let cell = side / 2
            // (글자, 채움) — ㄴ 핑크 / ㅏ 옐로는 옅게 채워 "칠하는 앨범" 느낌.
            let pink = UIColor(red: 1, green: 0xD7/255, blue: 0xE9/255, alpha: 1)
            let yellow = UIColor(red: 1, green: 0xE9/255, blue: 0xA8/255, alpha: 1)
            let layout: [(String, UIColor, Int, Int)] = [
                ("ㄱ", .white, 0, 0), ("ㄴ", pink, 1, 0),
                ("ㅏ", yellow, 0, 1), ("ㅑ", .white, 1, 1),
            ]
            for (glyph, fill, col, row) in layout {
                let rect = CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                draw(glyph, in: rect, fill: fill, cg: cg)
            }
        }
        return image.pngData()
    }
}

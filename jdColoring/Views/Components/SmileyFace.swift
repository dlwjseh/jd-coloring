import SwiftUI

/// 사진이 없는 프로필에 표시하는 기본 스마일 일러스트.
/// 좌표는 지름 대비 비율이라 어떤 크기에서도 동일하게 보인다.
struct SmileyFace: View {
    var size: CGFloat

    var body: some View {
        Canvas { ctx, sz in
            let w = sz.width, h = sz.height
            let ink = GraphicsContext.Shading.color(Theme.ink)

            // 눈
            let eyeR = w * 0.052
            ctx.fill(Path(ellipseIn: CGRect(x: w * 0.34 - eyeR, y: h * 0.42 - eyeR,
                                            width: eyeR * 2, height: eyeR * 2)), with: ink)
            ctx.fill(Path(ellipseIn: CGRect(x: w * 0.66 - eyeR, y: h * 0.42 - eyeR,
                                            width: eyeR * 2, height: eyeR * 2)), with: ink)

            // 볼터치
            let cheekR = w * 0.06
            let pink = GraphicsContext.Shading.color(Color(hex: 0xFF6FAF, alpha: 0.4))
            ctx.fill(Path(ellipseIn: CGRect(x: w * 0.24 - cheekR, y: h * 0.6 - cheekR,
                                            width: cheekR * 2, height: cheekR * 2)), with: pink)
            ctx.fill(Path(ellipseIn: CGRect(x: w * 0.76 - cheekR, y: h * 0.6 - cheekR,
                                            width: cheekR * 2, height: cheekR * 2)), with: pink)

            // 미소
            var smile = Path()
            smile.move(to: CGPoint(x: w * 0.32, y: h * 0.58))
            smile.addQuadCurve(to: CGPoint(x: w * 0.68, y: h * 0.58),
                               control: CGPoint(x: w * 0.5, y: h * 0.74))
            ctx.stroke(smile, with: ink,
                       style: StrokeStyle(lineWidth: w * 0.046, lineCap: .round))
        }
        .frame(width: size, height: size)
    }
}

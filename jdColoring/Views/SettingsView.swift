import SwiftUI

/// 앱 설정 시트 — 화면 1 좌상단 기어 버튼에서 진입하는 모달 시트.
/// 기기 전역 설정(AppSettings)을 변경한다.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var s = settings
        VStack(alignment: .leading, spacing: 0) {
            Text("설정")
                .font(Theme.rounded(22, weight: .heavy))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 12)

            Divider()

            // 펜 전용 토글
            HStack(spacing: 16) {
                Circle()
                    .fill(Color(hex: 0xEEF4FF))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: "pencil.tip")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Color(hex: 0x4A90D9))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("펜으로만 색칠하기")
                        .font(Theme.rounded(17, weight: .bold))
                        .foregroundStyle(Theme.ink)
                    Text("Apple Pencil로만 색칠할 수 있어요")
                        .font(Theme.rounded(13))
                        .foregroundStyle(Theme.subText)
                }

                Spacer()

                Toggle("펜으로만 색칠하기", isOn: $s.penOnly)
                    .labelsHidden()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider()

            Spacer()
        }
        .background(Theme.card)
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            SettingsView()
                .environment(AppSettings())
        }
}

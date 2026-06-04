import SwiftUI
import MultipeerConnectivity

/// iPhone 부모 제어판 — 타이머 설정·진행 화면.
/// 디자인 스펙 §23.
struct ParentControlView: View {

    @Environment(PeerSession.self) private var peer

    // 타이머 상태
    @State private var selectedMinutes = 20
    @State private var timerEnd: Date? = nil
    @State private var now = Date()
    @State private var showCustomInput = false
    @State private var customText = ""

    private let presets = [10, 15, 20, 30]
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var remaining: TimeInterval? {
        guard let end = timerEnd else { return nil }
        return max(0, end.timeIntervalSince(now))
    }
    private var timerRunning: Bool { timerEnd != nil }

    var body: some View {
        ZStack {
            Theme.bgGradient.ignoresSafeArea()
            BubbleBackground()

            VStack(spacing: 0) {
                connectionBar
                    .padding(.top, 52)
                    .padding(.horizontal, 24)

                Spacer()

                if timerRunning {
                    runningContent
                } else {
                    idleContent
                }

                Spacer()
            }
        }
        .onReceive(clock) { now = $0 }
        .onChange(of: remaining) { _, rem in
            // iPhone 측 카운트다운도 만료 시 초기화
            if rem == 0 { timerEnd = nil }
        }
        .onChange(of: peer.isConnected) { _, connected in
            // 재연결 시 현재 타이머 상태 재전송
            if connected, let end = timerEnd { peer.sendTimerStart(endDate: end) }
        }
    }

    // MARK: - 연결 상태 바

    private var connectionBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(peer.isConnected ? Color(hex: 0x5FD08A) : Color(hex: 0xB6A89B))
                .frame(width: 10, height: 10)

            if peer.isConnected, let name = peer.connectedPeerName {
                Text(name)
                    .font(Theme.rounded(15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("연결됨")
                    .font(Theme.rounded(13, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x5FD08A))

            } else if !peer.nearbyPeers.isEmpty {
                Text(peer.nearbyPeers[0].displayName)
                    .font(Theme.rounded(15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Button("연결") { peer.invite(peer.nearbyPeers[0]) }
                    .font(Theme.rounded(13, weight: .semibold))
                    .foregroundStyle(Theme.coral)

            } else {
                Text("iPad 검색 중…")
                    .font(Theme.rounded(15, weight: .semibold))
                    .foregroundStyle(Theme.subText)
                Spacer()
                ProgressView().scaleEffect(0.85)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 20).fill(Theme.card.opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.cardBorder, lineWidth: 1))
        .shadow(color: Theme.softShadow, radius: 6, x: 0, y: 2)
    }

    // MARK: - 대기 화면

    private var idleContent: some View {
        VStack(spacing: 28) {
            // 타이틀
            VStack(spacing: 6) {
                Text("색칠 타이머")
                    .font(Theme.rounded(28, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                Text("아이의 색칠 시간을 설정하세요")
                    .font(Theme.rounded(14))
                    .foregroundStyle(Theme.subText)
            }

            Rectangle().fill(Theme.cardBorder).frame(height: 1).padding(.horizontal, 24)

            // 프리셋 그리드
            VStack(spacing: 10) {
                Text("빠른 설정")
                    .font(Theme.rounded(12, weight: .semibold))
                    .foregroundStyle(Theme.faintText)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(presets, id: \.self) { min in
                        presetCard(min)
                    }
                }
                .padding(.horizontal, 24)
            }

            // 직접 입력
            if showCustomInput {
                HStack(spacing: 10) {
                    TextField("분", text: $customText)
                        .keyboardType(.numberPad)
                        .font(Theme.rounded(20, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .frame(width: 72, height: 44)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.cardBorder, lineWidth: 1))
                    Text("분")
                        .font(Theme.rounded(16))
                        .foregroundStyle(Theme.subText)
                    Button("확인") {
                        if let m = Int(customText), m > 0 { selectedMinutes = m }
                        showCustomInput = false
                        customText = ""
                    }
                    .font(Theme.rounded(15, weight: .semibold))
                    .foregroundStyle(Theme.coral)
                }
            } else {
                Button("직접 입력") { showCustomInput = true }
                    .font(Theme.rounded(14))
                    .foregroundStyle(Theme.subText)
                    .underline()
            }

            // 시작 버튼
            Button {
                let end = Date().addingTimeInterval(TimeInterval(selectedMinutes * 60))
                timerEnd = end
                peer.sendTimerStart(endDate: end)
            } label: {
                Text("시작")
                    .font(Theme.rounded(18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 22)
                            .fill(peer.isConnected ? Theme.coral : Theme.subText.opacity(0.35))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!peer.isConnected)
            .padding(.horizontal, 24)
        }
    }

    private func presetCard(_ min: Int) -> some View {
        let selected = selectedMinutes == min
        return Button { selectedMinutes = min } label: {
            VStack(spacing: 2) {
                Text("\(min)")
                    .font(Theme.rounded(26, weight: .bold))
                    .foregroundStyle(selected ? .white : Theme.coral)
                Text("분")
                    .font(Theme.rounded(12))
                    .foregroundStyle(selected ? .white.opacity(0.8) : Theme.subText)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 74)
            .background(RoundedRectangle(cornerRadius: 20).fill(selected ? Theme.coral : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(selected ? .clear : Theme.cardBorder, lineWidth: 1))
            .shadow(color: Theme.softShadow, radius: 5, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 타이머 진행 화면

    private var runningContent: some View {
        VStack(spacing: 24) {
            Text("남은 시간")
                .font(Theme.rounded(13, weight: .semibold))
                .foregroundStyle(Theme.subText)

            // 원형 링 + 카운트다운
            ZStack {
                Circle()
                    .stroke(Theme.cardBorder, lineWidth: 14)
                    .frame(width: 200, height: 200)

                if let rem = remaining {
                    let fraction = rem / max(1, TimeInterval(selectedMinutes * 60))
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(ringColor(rem), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                        .frame(width: 200, height: 200)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: fraction)
                }

                VStack(spacing: 4) {
                    if let rem = remaining {
                        Text(formatTime(rem))
                            .font(Theme.rounded(42, weight: .heavy))
                            .foregroundStyle(ringColor(remaining ?? 0))
                    }
                    Text("\(selectedMinutes)분 설정")
                        .font(Theme.rounded(13))
                        .foregroundStyle(Theme.subText)
                }
            }

            // 경고 칩
            if let rem = remaining {
                if rem <= 60 {
                    warningChip("⏱ 1분이 남았어요",
                                bg: Color(hex: 0xFFE8E8), fg: Color(hex: 0xFF5A5F))
                } else if rem <= 300 {
                    warningChip("⚠ 5분이 남았어요",
                                bg: Color(hex: 0xFFF3E0), fg: Color(hex: 0xD4720A))
                }
            }

            // 취소 버튼
            Button {
                timerEnd = nil
                peer.sendTimerCancel()
            } label: {
                Text("취소")
                    .font(Theme.rounded(16, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x7A6E64))
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(RoundedRectangle(cornerRadius: 22).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.cardBorder, lineWidth: 1.5))
                    .shadow(color: Theme.softShadow, radius: 5, x: 0, y: 2)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)

            Text("만료 시 iPad → 색칠 저장 후 즉시 홈 복귀")
                .font(Theme.rounded(12))
                .foregroundStyle(Theme.subText)
        }
    }

    // MARK: - 헬퍼

    private func ringColor(_ rem: TimeInterval) -> Color {
        if rem <= 60  { return Color(hex: 0xFF5A5F) }
        if rem <= 300 { return Color(hex: 0xD4720A) }
        return Color(hex: 0x2F6CB8)
    }

    private func warningChip(_ text: String, bg: Color, fg: Color) -> some View {
        Text(text)
            .font(Theme.rounded(13, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Capsule().fill(bg))
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

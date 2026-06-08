import SwiftUI
import MultipeerConnectivity

/// iPhone 부모 제어판 — 프로필 지정 타이머 설정·진행 화면.
/// 디자인 스펙 §23·§31 / 기획서 §「프로필 지정 타이머」.
struct ParentControlView: View {

    @Environment(PeerSession.self) private var peer

    // 타이머 설정 상태 — 텍스트 필드가 단일 진실 공급원
    @State private var inputText: String = ""        // 항상 보이는 분 수 입력 필드
    @State private var selectedMinutes: Int? = nil   // 강조 중인 프리셋 (nil = 없음)
    @State private var startedMinutes: Int = 0       // 진행 중 링 표시용 (시작 시 고정)

    // 대상 아이 선택 (필수)
    @State private var selectedProfile: ProfileSummary? = nil   // 대기 화면 선택
    @State private var timerTarget: ProfileSummary? = nil       // 진행 중 표시·재전송용

    // 타이머 진행 상태
    @State private var timerEnd: Date? = nil
    @State private var now = Date()

    private let presets = [10, 15, 20, 30]
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var remaining: TimeInterval? {
        guard let end = timerEnd else { return nil }
        return max(0, end.timeIntervalSince(now))
    }
    private var timerRunning: Bool { timerEnd != nil }

    // inputText 에서 파싱한 유효 분 수 (0 이하·파싱 실패 → nil)
    private var validMinutes: Int? {
        guard let m = Int(inputText), m > 0 else { return nil }
        return m
    }

    /// 시작 가능: 연결됨 + 시간 유효 + 대상 아이 선택.
    private var canStart: Bool {
        peer.isConnected && validMinutes != nil && selectedProfile != nil
    }

    var body: some View {
        ZStack {
            Theme.bgGradient.ignoresSafeArea()
            BubbleBackground()

            VStack(spacing: 0) {
                connectionBar
                    .padding(.top, 52)
                    .padding(.horizontal, 24)

                if timerRunning {
                    Spacer()
                    runningContent
                    Spacer()
                } else {
                    ScrollView {
                        idleContent.padding(.vertical, 24)
                    }
                }
            }
        }
        // 타이머 진행 중일 때만 매초 갱신 (대기 화면 불필요한 body 재평가 방지)
        .onReceive(clock) { date in
            guard timerRunning else { return }
            now = date
        }
        .onChange(of: remaining) { _, rem in
            if let rem, rem <= 0 { timerEnd = nil }   // m-3: 동치 대신 임계 비교
        }
        .onChange(of: peer.isConnected) { _, connected in
            // 재연결 시 진행 중 타이머를 대상과 함께 다시 전송.
            if connected, let end = timerEnd, let target = timerTarget {
                peer.sendTimerStart(endDate: end, targetProfileId: target.id)
            }
        }
        // 목록 갱신으로 선택했던 아이가 사라지면 선택 해제.
        .onChange(of: peer.availableProfiles) { _, list in
            if let sel = selectedProfile, !list.contains(where: { $0.id == sel.id }) {
                selectedProfile = nil
            }
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
        VStack(spacing: 24) {
            // 타이틀
            VStack(spacing: 6) {
                Text("색칠 타이머")
                    .font(Theme.rounded(26, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                Text("아이를 고르고 색칠 시간을 정하세요")
                    .font(Theme.rounded(13))
                    .foregroundStyle(Theme.subText)
            }

            // 누구에게 — 프로필 선택
            profileSection

            Rectangle().fill(Theme.cardBorder).frame(height: 1).padding(.horizontal, 24)

            // 얼마나 — 시간 설정
            timeSection

            // 시작 버튼
            startButton
                .padding(.horizontal, 24)
                .padding(.top, 4)

            // 보조 안내
            Text(startHint)
                .font(Theme.rounded(12))
                .foregroundStyle(Theme.subText)
                .multilineTextAlignment(.center)
        }
    }

    private var startHint: String {
        if !peer.isConnected { return "iPad와 연결되면 아이를 고를 수 있어요" }
        return "아이·시간 모두 골라야 시작돼요"
    }

    // MARK: - 누구에게 (프로필 선택)

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("누구에게 걸까요?")
                .font(Theme.rounded(12, weight: .bold))
                .foregroundStyle(Color(hex: 0xB6A89B))
                .padding(.horizontal, 24)

            if peer.availableProfiles.isEmpty {
                profilePlaceholder
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 22) {
                        ForEach(peer.availableProfiles) { p in
                            profileChip(p)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 4)
                }
                .accessibilityLabel("타이머 대상 아이 선택")
            }
        }
    }

    private func profileChip(_ p: ProfileSummary) -> some View {
        let selected = selectedProfile?.id == p.id
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) { selectedProfile = p }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    SummaryAvatar(summary: p, diameter: 56)
                    if selected {
                        Circle()
                            .stroke(Theme.coral, lineWidth: 4)
                            .frame(width: 66, height: 66)
                        // 우하단 코랄 체크 배지
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Theme.coral))
                            .offset(x: 22, y: 22)
                    }
                }
                .frame(width: 66, height: 66)

                Text(p.name)
                    .font(Theme.rounded(13, weight: selected ? .bold : .semibold))
                    .foregroundStyle(selected ? Theme.coral : Color(hex: 0x7A6E64))
                    .lineLimit(1)
                    .frame(maxWidth: 72)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(p.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("이 아이에게 타이머를 걸어요")
    }

    private var profilePlaceholder: some View {
        VStack(spacing: 10) {
            HStack(spacing: 22) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .strokeBorder(style: StrokeStyle(lineWidth: 2.5, dash: [5, 5]))
                        .foregroundStyle(Color(hex: 0xD8CCBE))
                        .frame(width: 56, height: 56)
                }
            }
            Text("iPad와 연결되면 아이 목록이 표시돼요")
                .font(Theme.rounded(13))
                .foregroundStyle(Theme.subText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    // MARK: - 얼마나 (시간 설정)

    private var timeSection: some View {
        VStack(spacing: 16) {
            // 프리셋 카드 그리드
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(presets, id: \.self) { min in
                    presetCard(min)
                }
            }
            .padding(.horizontal, 24)

            // 분 수 입력 필드 — 항상 표시, 텍스트 필드가 단일 진실 공급원
            minuteInputField
                .padding(.horizontal, 24)
        }
    }

    // MARK: - 시작 버튼

    private var startButton: some View {
        Button {
            guard let mins = validMinutes, let target = selectedProfile else { return }
            startedMinutes = mins
            timerTarget = target
            let end = Date().addingTimeInterval(TimeInterval(mins * 60))
            timerEnd = end
            now = Date()
            peer.sendTimerStart(endDate: end, targetProfileId: target.id)
        } label: {
            Text(startLabel)
                .font(Theme.rounded(18, weight: .bold))
                .foregroundStyle(canStart ? .white : Theme.subText)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 22)
                        .fill(canStart ? Theme.coral : Color(hex: 0xECE3DA))
                )
        }
        .buttonStyle(.plain)
        .disabled(!canStart)
    }

    private var startLabel: String {
        if let target = selectedProfile, let mins = validMinutes {
            return "\(target.name)에게 \(mins)분 시작"
        }
        return "시작"
    }

    // MARK: - 분 수 입력 필드

    private var minuteInputField: some View {
        ZStack(alignment: .trailing) {
            TextField("분 수 입력", text: $inputText)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(Theme.rounded(22, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .onChange(of: inputText) { _, newVal in
                    // 숫자만 허용
                    let digits = newVal.filter { $0.isNumber }
                    if digits != newVal { inputText = digits }
                    // 프리셋 강조 동기화
                    withAnimation(.easeInOut(duration: 0.18)) {
                        let parsed = Int(digits)
                        selectedMinutes = (parsed ?? 0) > 0 ? parsed : nil
                    }
                }

            // "분" 라벨은 우측 고정, 터치 차단
            Text("분")
                .font(Theme.rounded(15, weight: .medium))
                .foregroundStyle(Theme.subText)
                .padding(.trailing, 16)
                .allowsHitTesting(false)
        }
        .frame(height: 52)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.cardBorder, lineWidth: 1.5))
        .shadow(color: Theme.softShadow, radius: 4, x: 0, y: 2)
    }

    // MARK: - 프리셋 카드

    private func presetCard(_ min: Int) -> some View {
        let selected = selectedMinutes == min
        return Button {
            // inputText 만 업데이트 → .onChange 가 selectedMinutes 를 애니메이션과 함께 동기화
            inputText = "\(min)"
        } label: {
            VStack(spacing: 2) {
                Text("\(min)")
                    .font(Theme.rounded(26, weight: .bold))
                    .foregroundStyle(selected ? .white : Theme.coral)
                Text("분")
                    .font(Theme.rounded(12))
                    .foregroundStyle(selected ? .white.opacity(0.82) : Theme.subText)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 68)
            .background(RoundedRectangle(cornerRadius: 20).fill(selected ? Theme.coral : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(selected ? .clear : Theme.cardBorder, lineWidth: 1))
            .shadow(color: Theme.softShadow, radius: 5, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 타이머 진행 화면

    private var runningContent: some View {
        VStack(spacing: 24) {
            // 대상 아이 표시
            if let target = timerTarget {
                HStack(spacing: 8) {
                    SummaryAvatar(summary: target, diameter: 30)
                    Text("\(target.name)에게")
                        .font(Theme.rounded(15, weight: .bold))
                        .foregroundStyle(Theme.ink)
                }
            }

            Text("남은 시간")
                .font(Theme.rounded(13, weight: .semibold))
                .foregroundStyle(Theme.subText)

            ZStack {
                Circle()
                    .stroke(Theme.cardBorder, lineWidth: 14)
                    .frame(width: 200, height: 200)

                if let rem = remaining {
                    let fraction = rem / max(1, TimeInterval(startedMinutes * 60))
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
                            .font(Theme.rounded(34, weight: .heavy))
                            .foregroundStyle(ringColor(remaining ?? 0))
                            .monospacedDigit()
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                    }
                    Text("\(startedMinutes)분 설정")
                        .font(Theme.rounded(13))
                        .foregroundStyle(Theme.subText)
                }
                .frame(width: 170)
            }

            if let rem = remaining {
                if rem <= 60 {
                    warningChip("⏱ 1분이 남았어요",
                                bg: Color(hex: 0xFFE8E8), fg: Color(hex: 0xFF5A5F))
                } else if rem <= 300 {
                    warningChip("⚠ 5분이 남았어요",
                                bg: Color(hex: 0xFFF3E0), fg: Color(hex: 0xD4720A))
                }
            }

            Button {
                timerEnd = nil
                timerTarget = nil
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

            VStack(spacing: 3) {
                Text("대상 아이가 색칠 중일 때만 iPad에 표시·작동")
                Text("다른 아이가 쓰는 중 만료되면 그냥 사라져요")
            }
            .font(Theme.rounded(12))
            .foregroundStyle(Theme.subText)
            .multilineTextAlignment(.center)
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

    /// 아이 친화 포맷 — iPad 칩(§22)과 동일. 1분 미만은 초만.
    private func formatTime(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let minutes = total / 60
        let seconds = total % 60
        if minutes == 0 { return "\(seconds)초" }
        return "\(minutes)분 \(String(format: "%02d", seconds))초"
    }
}

import Foundation
import MultipeerConnectivity
import UIKit

/// 부모(iPhone) ↔ 아이(iPad) 1:1 로컬 연결.
/// iPad = 광고(Advertiser), iPhone = 탐색(Browser) + 초대.
/// 인터넷 불필요 — WiFi Direct / 블루투스 자동 선택.
///
/// @MainActor: 모든 공개 상태·메서드가 메인 스레드에서만 접근됨.
/// 델리게이트는 nonisolated + Task { @MainActor in } 로 메인으로 hop.
@Observable
@MainActor
final class PeerSession: NSObject {

    enum Role { case pad, phone }

    // MARK: - 공개 상태
    private(set) var isConnected = false
    private(set) var connectedPeerName: String? = nil
    private(set) var nearbyPeers: [MCPeerID] = []   // iPhone 측 탐색 결과

    /// iPad가 수신한 타이머 만료 시각. nil = 타이머 없음(취소 포함).
    var receivedTimerEnd: Date? = nil
    /// iPad가 수신한 타이머 대상 프로필(Profile.uuid). nil = 대상 없음.
    /// 활성 프로필과 일치할 때만 칩 표시·만료 동작이 적용된다.
    var receivedTimerTarget: UUID? = nil

    /// iPhone이 iPad에서 받은 프로필 목록(타이머 대상 후보). 미연결/동기화 전이면 비어 있음.
    private(set) var availableProfiles: [ProfileSummary] = []

    // MARK: - 내부
    private let role: Role
    private let myPeer: MCPeerID
    // nonisolated(unsafe): MPC 객체는 자체 스레드 안전.
    // deinit(비결정적 스레드)과 nonisolated 델리게이트에서도 정리·접근 필요.
    nonisolated(unsafe) private var session: MCSession!
    nonisolated(unsafe) private var advertiser: MCNearbyServiceAdvertiser?
    nonisolated(unsafe) private var browser: MCNearbyServiceBrowser?

    private static let serviceType = "jd-coloring"
    // 매 메시지마다 인스턴스를 생성하지 않도록 정적 재사용 (L-2 해소)
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// 기기별 고유 4자리 suffix — MCPeerID 표시명 중복 방지 (M-5 해소).
    /// 동일 모델명("iPad")이 여러 대여도 화면에서 구분 가능하게.
    private static let peerSuffix: String = {
        let key = "jd.peerSuffix"
        if let s = UserDefaults.standard.string(forKey: key) { return s }
        let s = String(UUID().uuidString.suffix(4))
        UserDefaults.standard.set(s, forKey: key)
        return s
    }()

    init(role: Role) {
        self.role = role
        // 기기 이름 + 고유 suffix 조합으로 표시명 중복 방지
        self.myPeer = MCPeerID(displayName: "\(UIDevice.current.name)-\(Self.peerSuffix)")
        super.init()
        session = MCSession(peer: myPeer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        startNetworking()
    }

    deinit {
        // MPC 메서드는 스레드 안전 → deinit 스레드에서 직접 정리
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session.disconnect()
    }

    // MARK: - 네트워킹 시작 / 백그라운드 대응 (M-4 해소)

    private func startNetworking() {
        switch role {
        case .pad:
            let ad = MCNearbyServiceAdvertiser(peer: myPeer, discoveryInfo: nil,
                                              serviceType: Self.serviceType)
            ad.delegate = self
            ad.startAdvertisingPeer()
            advertiser = ad
        case .phone:
            let br = MCNearbyServiceBrowser(peer: myPeer, serviceType: Self.serviceType)
            br.delegate = self
            br.startBrowsingForPeers()
            browser = br
        }
    }

    /// 앱이 백그라운드로 진입할 때 호출. 광고·탐색을 멈춰 배터리 소모를 줄인다.
    func suspend() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
    }

    /// 앱이 포그라운드로 복귀할 때 호출. 광고·탐색을 재개한다.
    func resume() {
        switch role {
        case .pad: advertiser?.startAdvertisingPeer()
        case .phone: browser?.startBrowsingForPeers()
        }
    }

    // MARK: - 송신 (iPhone → iPad)

    func sendTimerStart(endDate: Date, targetProfileId: UUID) {
        send(.timerStart(endDate: endDate, targetProfileId: targetProfileId))
    }

    func sendTimerCancel() {
        send(.timerCancel)
    }

    /// iPad → iPhone: 프로필 목록 전송(연결 직후 + 추가/수정/삭제 시).
    func sendProfileList(_ profiles: [ProfileSummary]) {
        send(.profileList(profiles))
    }

    /// iPhone: 목록에서 iPad 선택 후 연결 요청.
    func invite(_ peer: MCPeerID) {
        browser?.invitePeer(peer, to: session, withContext: nil, timeout: 15)
    }

    // MARK: - 내부 송신

    private func send(_ message: PeerMessage) {
        guard isConnected else { return }
        let peers = session.connectedPeers
        guard !peers.isEmpty, let data = try? Self.encoder.encode(message) else { return }
        try? session.send(data, toPeers: peers, with: .reliable)
    }
}

// MARK: - MCSessionDelegate
// nonisolated: MPC가 백그라운드 스레드에서 호출 → Task { @MainActor in } 로 상태 업데이트

extension PeerSession: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID,
                              didChange state: MCSessionState) {
        let p = peerID, s = state
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch s {
            case .connected:
                isConnected = true
                connectedPeerName = p.displayName
                nearbyPeers.removeAll { $0 == p }
            case .notConnected:
                if session.connectedPeers.isEmpty {
                    isConnected = false
                    connectedPeerName = nil
                }
            default: break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data,
                              fromPeer peerID: MCPeerID) {
        guard let msg = try? PeerSession.decoder.decode(PeerMessage.self, from: data) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch msg {
            case .timerStart(let endDate, let target):
                // 대상을 먼저 갱신 → receivedTimerEnd 변화를 관찰하는 쪽에서 대상이 이미 보이도록.
                receivedTimerTarget = target
                receivedTimerEnd = endDate
            case .timerCancel:
                receivedTimerEnd = nil
                receivedTimerTarget = nil
            case .profileList(let list):
                availableProfiles = list
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream,
                              withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession,
                              didStartReceivingResourceWithName resourceName: String,
                              fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession,
                              didFinishReceivingResourceWithName resourceName: String,
                              fromPeer peerID: MCPeerID, at localURL: URL?,
                              withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate (iPad)

extension PeerSession: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?,
                                invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }
}

// MARK: - MCNearbyServiceBrowserDelegate (iPhone)

extension PeerSession: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                              withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor [weak self] in
            guard let self, !nearbyPeers.contains(peerID) else { return }
            nearbyPeers.append(peerID)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor [weak self] in
            self?.nearbyPeers.removeAll { $0 == peerID }
        }
    }
}

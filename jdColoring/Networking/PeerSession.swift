import Foundation
import MultipeerConnectivity
import UIKit

/// 부모(iPhone) ↔ 아이(iPad) 1:1 로컬 연결.
/// iPad = 광고(Advertiser), iPhone = 탐색(Browser) + 초대.
/// 인터넷 불필요 — WiFi Direct / 블루투스 자동 선택.
@Observable
final class PeerSession: NSObject {

    enum Role { case pad, phone }

    // MARK: - 공개 상태
    private(set) var isConnected = false
    private(set) var connectedPeerName: String? = nil
    private(set) var nearbyPeers: [MCPeerID] = []   // iPhone 측 탐색 결과

    /// iPad가 수신한 타이머 만료 시각. nil = 타이머 없음(취소 포함).
    var receivedTimerEnd: Date? = nil

    // MARK: - 내부
    private let role: Role
    private let myPeer: MCPeerID
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    private static let serviceType = "jd-coloring"

    init(role: Role) {
        self.role = role
        self.myPeer = MCPeerID(displayName: UIDevice.current.name)
        super.init()
        session = MCSession(peer: myPeer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        start()
    }

    deinit { stop() }

    // MARK: - 시작 / 중지

    private func start() {
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

    private func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session.disconnect()
    }

    // MARK: - 송신 (iPhone → iPad)

    func sendTimerStart(endDate: Date) {
        send(.timerStart(endDate: endDate))
    }

    func sendTimerCancel() {
        send(.timerCancel)
    }

    /// iPhone: 목록에서 iPad 선택 후 연결 요청.
    func invite(_ peer: MCPeerID) {
        browser?.invitePeer(peer, to: session, withContext: nil, timeout: 15)
    }

    // MARK: - 내부 송신

    private func send(_ message: PeerMessage) {
        guard isConnected else { return }
        let peers = session.connectedPeers
        guard !peers.isEmpty, let data = try? JSONEncoder().encode(message) else { return }
        try? session.send(data, toPeers: peers, with: .reliable)
    }
}

// MARK: - MCSessionDelegate

extension PeerSession: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected:
                self.isConnected = true
                self.connectedPeerName = peerID.displayName
                self.nearbyPeers.removeAll { $0 == peerID }
            case .notConnected:
                if session.connectedPeers.isEmpty {
                    self.isConnected = false
                    self.connectedPeerName = nil
                }
            default: break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let msg = try? JSONDecoder().decode(PeerMessage.self, from: data) else { return }
        DispatchQueue.main.async {
            switch msg {
            case .timerStart(let endDate):
                self.receivedTimerEnd = endDate
            case .timerCancel:
                self.receivedTimerEnd = nil
            }
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream,
                 withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate (iPad)

extension PeerSession: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }
}

// MARK: - MCNearbyServiceBrowserDelegate (iPhone)

extension PeerSession: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                 withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async {
            if !self.nearbyPeers.contains(peerID) { self.nearbyPeers.append(peerID) }
        }
    }
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { self.nearbyPeers.removeAll { $0 == peerID } }
    }
}

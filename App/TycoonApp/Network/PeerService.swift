import Foundation
@preconcurrency import MultipeerConnectivity
import TycoonCore

/// Сообщения между телефонами. Хост — единственный, кто меняет партию;
/// остальные отправляют ему действия и получают готовое состояние.
enum NetMessage: Codable {
    /// Клиент → хост: «я подключился, меня зовут так». `device` — постоянный id телефона,
    /// по нему хост узнаёт игрока, вернувшегося после потери связи.
    case hello(name: String, device: String)
    /// Хост → всем: кто сейчас в комнате.
    case lobby(seats: [String])
    /// Хост → клиенту: партия началась, ты — игрок `you`.
    case start(you: PlayerID, config: GameConfig)
    /// Хост → всем: текущее состояние партии.
    case snapshot(Snapshot)
    /// Клиент → хост: действие своего игрока.
    case action(Action)
    /// Хост → клиенту: короткое сообщение (например, «действие отклонено»).
    case notice(String)
}

struct Snapshot: Codable {
    let state: GameState
    let log: [LogEntry]
    /// Сколько секунд осталось на ход (таймер считает хост).
    let secondsLeft: Double?
}

/// Обёртка над MultipeerConnectivity: Bluetooth и Wi-Fi рядом, без интернета.
@MainActor
final class PeerService: NSObject {
    /// До 15 символов: строчные латинские буквы, цифры и дефис. Совпадает с NSBonjourServices в Info.plist.
    static let serviceType = "tycoon-m1"

    let me: MCPeerID
    nonisolated(unsafe) let session: MCSession
    /// Принимать ли новых игроков (после старта партии хост перестаёт).
    nonisolated(unsafe) var acceptingInvites = true

    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    private(set) var connected: [MCPeerID] = []
    private(set) var found: [MCPeerID] = []

    var onMessage: ((NetMessage, MCPeerID) -> Void)?
    var onPeerState: ((MCPeerID, MCSessionState) -> Void)?
    var onFoundChange: (() -> Void)?

    init(displayName: String) {
        // Имя устройства в MultipeerConnectivity ограничено 63 байтами UTF-8.
        var name = displayName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "Игрок" }
        while name.utf8.count > 60 { name.removeLast() }
        me = MCPeerID(displayName: name)
        session = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
    }

    // MARK: - Комната

    func startHosting() {
        acceptingInvites = true
        let advertiser = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: nil, serviceType: Self.serviceType)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser
    }

    func stopAdvertising() {
        acceptingInvites = false
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
    }

    func startBrowsing() {
        let browser = MCNearbyServiceBrowser(peer: me, serviceType: Self.serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
    }

    func join(_ host: MCPeerID) {
        browser?.invitePeer(host, to: session, withContext: nil, timeout: 20)
    }

    func stop() {
        stopAdvertising()
        browser?.stopBrowsingForPeers()
        browser = nil
        session.disconnect()
        connected = []
        found = []
    }

    // MARK: - Отправка

    func send(_ message: NetMessage, to peers: [MCPeerID]? = nil) {
        let targets = peers ?? session.connectedPeers
        guard !targets.isEmpty, let data = try? JSONEncoder().encode(message) else { return }
        try? session.send(data, toPeers: targets, with: .reliable)
    }

    // MARK: - События (уже на главном потоке)

    fileprivate func handleState(_ peer: MCPeerID, _ state: MCSessionState) {
        switch state {
        case .connected:
            if !connected.contains(peer) { connected.append(peer) }
        case .notConnected:
            connected.removeAll { $0 == peer }
        default:
            break
        }
        onPeerState?(peer, state)
    }

    fileprivate func handleFound(_ peer: MCPeerID) {
        guard !found.contains(peer) else { return }
        found.append(peer)
        onFoundChange?()
    }

    fileprivate func handleLost(_ peer: MCPeerID) {
        found.removeAll { $0 == peer }
        onFoundChange?()
    }
}

// MARK: - Делегаты MultipeerConnectivity (приходят с фоновых потоков)

extension PeerService: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in self.handleState(peerID, state) }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = try? JSONDecoder().decode(NetMessage.self, from: data) else { return }
        Task { @MainActor in self.onMessage?(message, peerID) }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream,
                             withName streamName: String, fromPeer peerID: MCPeerID) {}

    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, with progress: Progress) {}

    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension PeerService: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?,
                                invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(acceptingInvites, session)
    }
}

extension PeerService: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                             withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in self.handleFound(peerID) }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in self.handleLost(peerID) }
    }
}

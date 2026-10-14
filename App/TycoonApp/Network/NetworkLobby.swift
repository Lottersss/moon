import SwiftUI
import MultipeerConnectivity
import TycoonCore

/// Комната для игры по Bluetooth: сбор игроков до старта и пересылка сообщений во время партии.
@MainActor
@Observable
final class NetworkLobby {
    enum Role { case host, client }

    struct Seat: Identifiable {
        let id = UUID()
        var name: String
        /// Телефон игрока; `nil` — хост сам или бот.
        var peer: MCPeerID?
        var isBot: Bool
        var isHost: Bool
        /// Постоянный id телефона игрока (для переподключения).
        var device: String? = nil
    }

    let role: Role
    let myName: String
    @ObservationIgnored let service: PeerService

    /// Хост: места в комнате (хост всегда первый). Клиент: имена, присланные хостом.
    private(set) var seats: [Seat] = []
    /// Клиент: найденные рядом комнаты.
    private(set) var hosts: [MCPeerID] = []
    /// Клиент: комната, к которой подключаемся или подключены.
    private(set) var joinedHost: MCPeerID?
    private(set) var isConnectedToHost = false
    private(set) var status = ""

    /// Настройки партии (выбирает хост).
    var mode: GameMode = .classic
    var turnSeconds: Int? = 60
    var maxRounds: Int? = nil

    private(set) var game: GameViewModel?
    var connectionLost = false

    /// Хост: какое место у какого телефона — чтобы вернуть игрока после потери связи.
    @ObservationIgnored private var deviceSeats: [String: PlayerID] = [:]
    /// Клиент: имя хоста, чтобы найти его снова после разрыва.
    @ObservationIgnored private var hostName: String?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

    static let maxSeats = 6

    init(role: Role, name: String) {
        self.role = role
        self.myName = name
        self.service = PeerService(displayName: name)
        service.onMessage = { [weak self] message, peer in self?.handle(message, from: peer) }
        service.onPeerState = { [weak self] peer, state in self?.peerChanged(peer, state) }
        service.onFoundChange = { [weak self] in self?.hosts = self?.service.found ?? [] }

        switch role {
        case .host:
            seats = [Seat(name: name, peer: nil, isBot: false, isHost: true)]
            service.startHosting()
            status = "Комната открыта. Ждём игроков рядом…"
        case .client:
            service.startBrowsing()
            status = "Ищем комнаты рядом…"
        }
    }

    func leave() {
        reconnectTask?.cancel()
        service.stop()
    }

    // MARK: - Хост

    var canStart: Bool {
        guard role == .host else { return false }
        if mode == .teams { return seats.count == 4 }
        return (2...Self.maxSeats).contains(seats.count)
    }

    func addBot() {
        guard role == .host, seats.count < Self.maxSeats, game == nil else { return }
        let number = seats.filter(\.isBot).count + 1
        seats.append(Seat(name: "Бот \(number)", peer: nil, isBot: true, isHost: false))
        broadcastLobby()
    }

    func removeSeat(_ seat: Seat) {
        guard role == .host, game == nil, !seat.isHost else { return }
        if let peer = seat.peer { service.session.cancelConnectPeer(peer) }
        seats.removeAll { $0.id == seat.id }
        broadcastLobby()
    }

    func start() {
        guard canStart, game == nil else { return }
        var config = GameConfig()
        config.mode = mode
        config.turnSeconds = turnSeconds
        config.maxRounds = maxRounds
        config.passDevicePrompt = false
        config.players = seats.map { PlayerSetup(name: $0.name, isBot: $0.isBot) }

        var peers: [MCPeerID: PlayerID] = [:]
        for (index, seat) in seats.enumerated() {
            if let peer = seat.peer { peers[peer] = index }
            if let device = seat.device { deviceSeats[device] = index }
        }
        // Комната остаётся видимой: игроки, потерявшие связь, смогут вернуться. Новых не пускаем.

        // Сначала каждому телефону — его место и настройки, потом движок пришлёт первый снимок.
        for (peer, id) in peers {
            service.send(.start(you: id, config: config), to: [peer])
        }
        game = GameViewModel(hosting: config, me: 0, service: service, peers: peers)
    }

    private func broadcastLobby() {
        guard role == .host else { return }
        service.send(.lobby(seats: seats.map { $0.isBot ? "🤖 \($0.name)" : $0.name }))
        let waiting = seats.count < 2 ? "Ждём игроков рядом…" : "Можно начинать"
        status = "В комнате \(seats.count) из \(Self.maxSeats). \(waiting)"
    }

    // MARK: - Клиент

    func join(_ host: MCPeerID) {
        guard role == .client else { return }
        joinedHost = host
        hostName = host.displayName
        status = "Подключаемся к «\(host.displayName)»…"
        service.join(host)
    }

    // MARK: - Переподключение (клиент)

    /// Связь с хостом пропала посреди партии: ищем его снова 30 секунд, потом сдаёмся.
    private func startReconnect() {
        joinedHost = nil
        // Уже переподключаемся: неудачная попытка просто освобождает место для следующей.
        if game?.reconnecting == true { return }
        game?.reconnecting = true
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            for _ in 0..<60 {
                guard let self, !Task.isCancelled else { return }
                if self.isConnectedToHost { return }
                if self.joinedHost == nil,
                   let host = self.service.found.first(where: { $0.displayName == self.hostName }) {
                    self.joinedHost = host
                    self.service.join(host)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard let self, !self.isConnectedToHost else { return }
            self.game?.reconnecting = false
            self.connectionLost = true
            self.game?.connectionLost = true
        }
    }

    private func finishReconnect() {
        reconnectTask?.cancel()
        game?.reconnecting = false
    }

    // MARK: - Сообщения

    private func handle(_ message: NetMessage, from peer: MCPeerID) {
        switch (role, message) {
        case (.host, .hello(let name, let device)):
            if let game {
                // Партия уже идёт: пускаем только тех, кто в ней был.
                guard let seat = deviceSeats[device] else {
                    service.send(.notice("Партия уже идёт"), to: [peer])
                    return
                }
                service.send(.start(you: seat, config: game.config), to: [peer])
                game.reattach(peer, to: seat)
                return
            }
            guard seats.count < Self.maxSeats else {
                service.send(.notice("Комната заполнена"), to: [peer])
                return
            }
            if let index = seats.firstIndex(where: { $0.peer == peer || $0.device == device }) {
                seats[index].name = name
                seats[index].peer = peer
            } else {
                seats.append(Seat(name: name, peer: peer, isBot: false, isHost: false, device: device))
            }
            broadcastLobby()

        case (.host, .action(let action)):
            game?.receive(action, from: peer)

        case (.client, .lobby(let names)):
            seats = names.map { Seat(name: $0, peer: nil, isBot: false, isHost: false) }
            status = "Вы в комнате. Ждём, когда хост начнёт игру"

        case (.client, .start(let you, let config)):
            // После переподключения хост снова присылает start — партия у нас уже есть.
            if game == nil {
                game = GameViewModel(joining: config, me: you, service: service)
            }
            finishReconnect()

        case (.client, .snapshot(let snapshot)):
            game?.apply(snapshot)

        case (_, .notice(let text)):
            if let game { game.showNotice(text) } else { status = text }

        default:
            break
        }
    }

    private func peerChanged(_ peer: MCPeerID, _ state: MCSessionState) {
        switch (role, state) {
        case (.client, .connected) where peer == joinedHost:
            isConnectedToHost = true
            if game == nil { status = "Подключено. Ждём, когда хост начнёт игру" }
            service.send(.hello(name: myName, device: DeviceIdentity.id), to: [peer])

        case (.client, .notConnected) where peer == joinedHost:
            isConnectedToHost = false
            if game != nil {
                startReconnect()
            } else {
                joinedHost = nil
                status = "Не удалось подключиться. Выберите комнату ещё раз"
            }

        case (.host, .notConnected) where game != nil && game?.seat(of: peer) == nil:
            // Телефон, который уже переподключился под новым соединением, — ничего не делаем.
            break

        case (.host, .notConnected):
            if game != nil {
                game?.peerDisconnected(peer)
            } else {
                seats.removeAll { $0.peer == peer }
                broadcastLobby()
            }

        default:
            break
        }
    }
}

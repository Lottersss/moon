import SwiftUI
import MultipeerConnectivity
import TycoonCore

struct LogEntry: Identifiable, Codable {
    let id: Int
    let text: String
    let player: PlayerID?
    let isSeparator: Bool
}

/// Где живёт партия.
enum NetworkRole {
    /// Один телефон на всех (hot-seat) или игра против ботов.
    case local
    /// Этот телефон — хост: держит движок и рассылает состояние.
    case host(PeerService)
    /// Этот телефон — клиент: отправляет действия хосту и показывает присланное состояние.
    case client(PeerService)
}

/// Связывает движок с экраном: хранит партию, водит ботов, считает таймер,
/// ведёт журнал и подсказывает, какие действия сейчас доступны.
@MainActor
@Observable
final class GameViewModel {
    private(set) var state: GameState
    private(set) var log: [LogEntry] = []
    let config: GameConfig

    /// Сообщение об ошибке последнего действия (показывается всплывашкой).
    var errorMessage: String?
    /// Экран «передайте телефон» для живого игрока, чей сейчас ход.
    var handoffTo: PlayerID?
    /// Когда закончится время на текущее действие.
    private(set) var deadline: Date?
    /// Последний выпавший бросок — для анимации кубиков.
    private(set) var rollCounter = 0

    @ObservationIgnored private let bot = SimpleBot()
    @ObservationIgnored private var botTask: Task<Void, Never>?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var nextLogID = 0
    @ObservationIgnored private var lastHuman: PlayerID?
    /// Отладка: `-autoplay` — за живых игроков этого телефона нажимает логика бота
    /// (действия идут обычным путём, в том числе через сеть).
    @ObservationIgnored private let autoplay = ProcessInfo.processInfo.arguments.contains("-autoplay")
    @ObservationIgnored private var autoplayTask: Task<Void, Never>?

    @ObservationIgnored let role: NetworkRole
    /// Хост: какой телефон за какое место играет. Меняется, когда игрок переподключается.
    @ObservationIgnored private var peerSeats: [MCPeerID: PlayerID] = [:]
    /// Клиент: связь с хостом пропала, идёт переподключение.
    var reconnecting = false
    /// Игроки, за которых нажимают на этом телефоне.
    let localPlayers: Set<PlayerID>
    /// Клиент потерял связь с хостом.
    var connectionLost = false

    /// Партия на одном телефоне: все живые игроки — местные.
    init(config: GameConfig) {
        self.config = config
        self.role = .local
        let initial = GameState(players: config.makePlayers(),
                                settings: config.makeSettings(),
                                seed: UInt64.random(in: 1...UInt64.max))
        self.state = initial
        self.localPlayers = Set(initial.players.filter { !$0.isBot }.map(\.id))
        logStart()
        afterChange()
    }

    /// Продолжение сохранённой партии на этом телефоне.
    init(restoring saved: SavedGame) {
        self.config = saved.config
        self.role = .local
        self.state = saved.state
        self.localPlayers = Set(saved.state.players.filter { !$0.isBot }.map(\.id))
        self.log = saved.log
        self.nextLogID = (saved.log.map(\.id).max() ?? 0) + 1
        appendLog("Партия продолжена", player: nil, separator: true)
        afterChange()
    }

    /// Хост сетевой партии: сам играет за `me`, остальные живые игроки — на других телефонах.
    init(hosting config: GameConfig, me: PlayerID, service: PeerService, peers: [MCPeerID: PlayerID]) {
        self.config = config
        self.role = .host(service)
        self.peerSeats = peers
        self.state = GameState(players: config.makePlayers(),
                               settings: config.makeSettings(),
                               seed: UInt64.random(in: 1...UInt64.max))
        self.localPlayers = [me]
        logStart()
        afterChange()
    }

    /// Клиент сетевой партии: настоящее состояние придёт от хоста первым же снимком.
    init(joining config: GameConfig, me: PlayerID, service: PeerService) {
        self.config = config
        self.role = .client(service)
        self.state = GameState(players: config.makePlayers(), settings: config.makeSettings(), seed: 0)
        self.localPlayers = [me]
    }

    private func logStart() {
        appendLog("Партия началась: \(config.mode.title)", player: nil, separator: true)
        let order = state.turnOrder.map { state.players[$0].name }.joined(separator: " → ")
        appendLog("Порядок ходов: \(order)", player: nil, separator: false)
    }

    var isClient: Bool {
        if case .client = role { return true }
        return false
    }

    // MARK: - Кто ходит

    var activePlayer: PlayerID? { state.activePlayer }

    /// Живой игрок на этом телефоне, от которого сейчас ждут действия.
    var activeHuman: PlayerID? {
        guard let id = state.activePlayer, !state.players[id].isBot, localPlayers.contains(id) else { return nil }
        return id
    }

    var humanCount: Int { state.players.filter { !$0.isBot }.count }

    /// Сейчас ходит не этот телефон: бот или игрок на другом телефоне.
    var isBotThinking: Bool {
        guard state.activePlayer != nil, !state.isOver else { return false }
        return activeHuman == nil
    }

    // MARK: - Доступность действий

    /// Пробует действие на копии партии: движок чистый, поэтому проверка честная и бесплатная.
    func canPerform(_ action: Action) -> Bool {
        guard let actor = activeHuman, handoffTo == nil else { return false }
        var copy = state
        return (try? copy.apply(action, by: actor)) != nil
    }

    /// Клетки, которые стоит подсветить на доске.
    var highlightedCells: Set<CellID> {
        guard let me = activeHuman, handoffTo == nil else { return [] }
        switch state.phase {
        case .awaitingTeleport:
            return Set(state.board.cells.indices.filter { $0 != state.players[me].position })
        case .awaitingBuyDecision(let cell):
            return [cell]
        case .auction(let auction):
            return [auction.cell]
        case .awaitingRoll, .awaitingEndTurn:
            guard state.pendingTrade == nil else { return [] }
            return Set(state.cellsOwned(by: me).filter { canPerform(.build($0)) })
        default:
            return []
        }
    }

    // MARK: - Действия живого игрока

    func perform(_ action: Action) {
        guard let actor = activeHuman, handoffTo == nil else { return }
        if case .client(let service) = role {
            // Клиент проверяет действие на своей копии (чтобы сразу показать ошибку) и отправляет хосту.
            var copy = state
            do {
                _ = try copy.apply(action, by: actor)
                errorMessage = nil
                service.send(.action(action))
            } catch let error as GameError {
                errorMessage = error.description
            } catch {
                errorMessage = "\(error)"
            }
            return
        }
        do {
            let events = try state.apply(action, by: actor)
            record(events)
            errorMessage = nil
        } catch let error as GameError {
            errorMessage = error.description
        } catch {
            errorMessage = "\(error)"
        }
        afterChange()
    }

    func tapCell(_ cell: CellID) -> Bool {
        if case .awaitingTeleport = state.phase, activeHuman != nil {
            perform(.teleport(cell))
            return true
        }
        return false
    }

    func confirmHandoff() {
        handoffTo = nil
        restartTimer()
        broadcast()
    }

    // MARK: - Сеть

    /// Хост: действие пришло с телефона другого игрока.
    func receive(_ action: Action, from peer: MCPeerID) {
        guard case .host(let service) = role, let actor = peerSeats[peer] else { return }
        guard state.activePlayer == actor else {
            service.send(.notice("Сейчас не ваш ход"), to: [peer])
            return
        }
        do {
            record(try state.apply(action, by: actor))
        } catch let error as GameError {
            service.send(.notice(error.description), to: [peer])
        } catch {}
        afterChange()
    }

    /// Хост: телефон игрока отключился — дальше за него играет бот.
    func peerDisconnected(_ peer: MCPeerID) {
        guard case .host = role, let id = peerSeats.removeValue(forKey: peer), !state.players[id].isBot else { return }
        state.setBot(id, true)
        appendLog("\(state.players[id].name) отключился — пока за него играет бот", player: id, separator: false)
        afterChange()
    }

    /// Хост: игрок вернулся после потери связи — снова садится на своё место.
    func reattach(_ peer: MCPeerID, to seat: PlayerID) {
        guard case .host = role, state.players.indices.contains(seat) else { return }
        peerSeats = peerSeats.filter { $0.value != seat }
        peerSeats[peer] = seat
        if state.players[seat].isBot && !config.players[seat].isBot {
            state.setBot(seat, false)
            appendLog("\(state.players[seat].name) вернулся в игру", player: seat, separator: false)
        }
        afterChange()
    }

    /// Хост: место, за которое играет этот телефон.
    func seat(of peer: MCPeerID) -> PlayerID? { peerSeats[peer] }

    /// Клиент: пришло новое состояние от хоста.
    func apply(_ snapshot: Snapshot) {
        if snapshot.state.lastRoll != state.lastRoll || snapshot.state.turnNumber != state.turnNumber {
            rollCounter += 1
        }
        state = snapshot.state
        log = snapshot.log
        deadline = snapshot.secondsLeft.map { Date().addingTimeInterval($0) }
        scheduleAutoplay()
    }

    private func scheduleAutoplay() {
        guard autoplay, activeHuman != nil else { return }
        autoplayTask?.cancel()
        autoplayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, let me = self.activeHuman else { return }
            self.handoffTo = nil
            self.perform(self.bot.decide(self.state.publicView, as: me))
        }
    }

    func showNotice(_ text: String) {
        errorMessage = text
    }

    /// Локальная партия сохраняется после каждого изменения; законченная — удаляется.
    private func autosave() {
        guard case .local = role else { return }
        if state.isOver {
            SaveStore.clear()
        } else {
            SaveStore.save(SavedGame(config: config, state: state, log: Array(log.prefix(150)), savedAt: Date()))
        }
    }

    private func broadcast() {
        guard case .host(let service) = role else { return }
        let snapshot = Snapshot(state: state.redactedForClients(),
                                log: Array(log.prefix(120)),
                                secondsLeft: deadline.map { max(0, $0.timeIntervalSinceNow) })
        service.send(.snapshot(snapshot))
    }

    // MARK: - После каждого изменения

    private func afterChange() {
        guard !isClient else { return }
        botTask?.cancel()
        timerTask?.cancel()
        deadline = nil
        defer {
            broadcast()
            autosave()
        }

        guard !state.isOver, let active = state.activePlayer else { return }

        if state.players[active].isBot {
            scheduleBot()
            return
        }

        // Один телефон на всех: ход перешёл к другому живому игроку — просим передать телефон.
        if case .local = role, config.passDevicePrompt, humanCount > 1, lastHuman != nil, lastHuman != active {
            handoffTo = active
            lastHuman = active
            return
        }
        lastHuman = active
        restartTimer()
        scheduleAutoplay()
    }

    private func scheduleBot() {
        // На аукционе боты торгуются быстро, иначе каждый шаг ставки тянется почти секунду.
        var delay = 650
        if case .auction = state.phase { delay = 150 }
        botTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            self?.stepBot()
        }
    }

    private func stepBot() {
        guard let actor = state.activePlayer, state.players[actor].isBot else { return }
        let action = bot.decide(state.publicView, as: actor)
        do {
            record(try state.apply(action, by: actor))
        } catch {
            let fallback = BotRunner.fallbackAction(for: state, actor: actor)
            if let events = try? state.apply(fallback, by: actor) { record(events) }
        }
        afterChange()
    }

    private func restartTimer() {
        timerTask?.cancel()
        // Таймер считает хост (или единственный телефон) — для любого живого игрока, где бы он ни сидел.
        guard !isClient, let seconds = config.turnSeconds, handoffTo == nil,
              let actor = state.activePlayer, !state.players[actor].isBot else {
            deadline = nil
            return
        }
        deadline = Date().addingTimeInterval(TimeInterval(seconds))
        let turn = state.turnNumber
        timerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.timeOut(actor: actor, turn: turn)
        }
    }

    /// Время вышло: движок делает безопасное действие по умолчанию
    /// (бросок, отказ от покупки, пас, завершение хода).
    private func timeOut(actor: PlayerID, turn: Int) {
        guard state.activePlayer == actor, state.turnNumber == turn else { return }
        appendLog("⏱ Время \(state.players[actor].name) вышло", player: actor, separator: false)
        let action = BotRunner.fallbackAction(for: state, actor: actor)
        if let events = try? state.apply(action, by: actor) { record(events) }
        afterChange()
    }

    // MARK: - Журнал

    private func record(_ events: [GameEvent]) {
        for event in events {
            if case .diceRolled = event { rollCounter += 1 }
            guard let text = EventText.text(event, in: state) else { continue }
            var separator = false
            if case .turnStarted = event { separator = true }
            appendLog(text, player: Self.subject(of: event), separator: separator)
        }
    }

    private func appendLog(_ text: String, player: PlayerID?, separator: Bool) {
        log.insert(LogEntry(id: nextLogID, text: text, player: player, isSeparator: separator), at: 0)
        nextLogID += 1
        if log.count > 300 { log.removeLast(log.count - 300) }
    }

    private static func subject(of event: GameEvent) -> PlayerID? {
        switch event {
        case .turnStarted(let p, _), .diceRolled(let p, _), .speedDieRolled(let p, _),
             .moved(let p, _, _, _), .startBonus(let p, _), .bought(let p, _, _),
             .paid(let p, _, _, _), .received(let p, _), .cardDrawn(let p, _, _),
             .sentToJail(let p), .leftJail(let p), .bidPlaced(let p, _), .bidPassed(let p),
             .auctionWon(let p, _, _), .jackpotPlayed(let p, _, _, _), .built(let p, _, _),
             .branchSold(let p, _, _), .mortgaged(let p, _), .unmortgaged(let p, _),
             .mortgageExpired(let p, _), .debtStarted(let p, _), .bankrupt(let p, _):
            return p
        case .tradeProposed(let offer, _), .tradeAccepted(let offer), .tradeRejected(let offer),
             .tradeCancelled(let offer):
            return offer.from
        case .gameOver(let winner, _, _):
            return winner
        case .auctionStarted, .auctionNoBids:
            return nil
        }
    }
}

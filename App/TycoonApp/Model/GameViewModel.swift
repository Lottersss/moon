import SwiftUI
import MultipeerConnectivity
import TycoonCore

struct LogEntry: Identifiable, Codable {
    let id: Int
    let text: String
    let player: PlayerID?
    let isSeparator: Bool
    /// Сообщение чата (`nil` у старых сохранений — значит, не чат).
    var isChat: Bool? = nil
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
    /// Где фишки нарисованы сейчас. Настоящая позиция в `state` меняется сразу,
    /// а фишка догоняет её по клеткам, шаг за шагом.
    private(set) var shownPositions: [CellID] = []

    /// Сколько длится шаг фишки на соседнюю клетку.
    static let stepSeconds = 0.16
    /// Кубики крутятся столько, прежде чем фишка тронется.
    static let diceSpinSeconds = 0.8

    @ObservationIgnored private var walkTargets: [CellID] = []
    @ObservationIgnored private var walkTasks: [PlayerID: Task<Void, Never>] = [:]
    /// До какого момента идёт анимация (кубики и шаги): боты ждут, пока фишка дойдёт.
    @ObservationIgnored private var busyUntil = Date.distantPast
    @ObservationIgnored private var lastRollAt = Date.distantPast
    /// Итог партии уже записан в статистику аккаунтов.
    @ObservationIgnored private var resultRecorded = false
    @ObservationIgnored private var speedDieAnnounced = false
    /// Часы партии: хост (или единственный телефон) отсчитывает время, клиенты берут его из снимка.
    @ObservationIgnored private var clockOrigin = Date()
    @ObservationIgnored private var noStartAnnounced = false
    @ObservationIgnored private var rentTaxAnnounced = false
    /// Для кого и на каком ходу запущен таймер: залог, выкуп и постройка его не перезапускают.
    @ObservationIgnored private var timerActor: PlayerID?
    @ObservationIgnored private var timerTurn = 0
    @ObservationIgnored private var keepTimerOnce = false

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
                                board: config.makeBoard(),
                                seed: UInt64.random(in: 1...UInt64.max))
        self.state = initial
        self.localPlayers = Set(initial.players.filter { !$0.isBot }.map(\.id))
        resetTokens()
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
        self.clockOrigin = Date().addingTimeInterval(-Double(saved.state.clockSeconds ?? 0))
        self.noStartAnnounced = !saved.state.startBonusPaid
        self.rentTaxAnnounced = saved.state.rentTaxPercent > 0
        resetTokens()
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
                               board: config.makeBoard(),
                               seed: UInt64.random(in: 1...UInt64.max))
        self.localPlayers = [me]
        resetTokens()
        logStart()
        afterChange()
    }

    /// Клиент сетевой партии: настоящее состояние придёт от хоста первым же снимком.
    init(joining config: GameConfig, me: PlayerID, service: PeerService) {
        self.config = config
        self.role = .client(service)
        self.state = GameState(players: config.makePlayers(), settings: config.makeSettings(),
                               board: config.makeBoard(), seed: 0)
        self.localPlayers = [me]
        resetTokens()
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
        case .awaitingMoveChoice(let options):
            // «Автобус»: игра сама подсвечивает поля, на которые можно перейти.
            return Set(options.map { busTarget(steps: $0, for: me) })
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
            tick()
            let events = try state.apply(action, by: actor)
            record(events)
            keepTimerOnce = Self.keepsTimer(action)
            errorMessage = nil
        } catch let error as GameError {
            errorMessage = error.description
        } catch {
            errorMessage = "\(error)"
        }
        afterChange()
    }

    func tapCell(_ cell: CellID) -> Bool {
        guard let me = activeHuman else { return false }
        switch state.phase {
        case .awaitingTeleport:
            perform(.teleport(cell))
            return true
        case .awaitingMoveChoice(let options):
            guard let steps = options.first(where: { busTarget(steps: $0, for: me) == cell }) else { return false }
            perform(.chooseMove(steps))
            return true
        default:
            return false
        }
    }

    /// Клетка, на которую приведёт «Автобус» при выбранном числе шагов.
    func busTarget(steps: Int, for player: PlayerID) -> CellID {
        (state.players[player].position + steps) % state.board.count
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
            tick()
            record(try state.apply(action, by: actor))
            keepTimerOnce = Self.keepsTimer(action)
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
        // Был ли бросок, видно по новым строкам журнала: так дубль с теми же числами тоже покажется.
        let newest = log.first?.id ?? -1
        if snapshot.log.contains(where: { $0.id > newest && $0.text.contains(" бросает ") }) {
            noteRoll()
        }
        state = snapshot.state
        clockOrigin = Date().addingTimeInterval(-Double(snapshot.state.clockSeconds ?? 0))
        log = snapshot.log
        deadline = snapshot.secondsLeft.map { Date().addingTimeInterval($0) }
        syncTokens()
        recordResultIfNeeded()
        scheduleAutoplay()
    }

    // MARK: - Чат (только по Bluetooth)

    var canChat: Bool {
        if case .local = role { return false }
        return true
    }

    /// Сообщение от игрока этого телефона. Клиент отправляет хосту, хост добавляет в журнал
    /// и рассылает всем вместе со снимком партии.
    func sendChat(_ raw: String) {
        let text = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.chatLimit))
        guard !text.isEmpty else { return }
        switch role {
        case .local:
            return
        case .client(let service):
            service.send(.chat(text))
        case .host:
            if let me = localPlayers.first { postChat(text, from: me) }
        }
    }

    /// Хост: сообщение пришло с телефона игрока.
    func receiveChat(_ text: String, from peer: MCPeerID) {
        guard case .host = role, let seat = peerSeats[peer] else { return }
        let clean = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.chatLimit))
        guard !clean.isEmpty else { return }
        postChat(clean, from: seat)
    }

    static let chatLimit = 140

    private func postChat(_ text: String, from seat: PlayerID) {
        appendLog("\(state.players[seat].name): \(text)", player: seat, separator: false, chat: true)
        broadcast()
    }

    // MARK: - Статистика аккаунтов

    /// Партия закончилась: аккаунтам этого телефона засчитываются победа или поражение.
    private func recordResultIfNeeded() {
        guard state.isOver, !resultRecorded else { return }
        resultRecorded = true
        guard case .gameOver(let winner) = state.phase else { return }
        var seats: [PlayerID: UUID] = [:]
        if case .local = role {
            seats = config.accounts ?? [:]
        } else if let me = localPlayers.first {
            seats[me] = config.accounts?[me] ?? AccountStore.shared.main.id
        }
        for (seat, account) in seats where state.players.indices.contains(seat) {
            let won: Bool
            if let team = state.players[seat].team {
                won = state.winningTeam == team
            } else {
                won = winner == seat
            }
            AccountStore.shared.record(account, won: won)
        }
    }

    // MARK: - Ход фишек

    private func resetTokens() {
        shownPositions = state.players.map(\.position)
        walkTargets = shownPositions
    }

    private func noteRoll() {
        rollCounter += 1
        lastRollAt = Date()
        busyUntil = max(busyUntil, lastRollAt.addingTimeInterval(Self.diceSpinSeconds + 0.5))
    }

    /// Фишка идёт к новой позиции по клеткам. Тюрьма, телепорт и шаг назад — прыжком.
    private func syncTokens() {
        let count = state.board.count
        for player in state.players {
            let id = player.id
            guard shownPositions.indices.contains(id) else {
                shownPositions.append(player.position)
                walkTargets.append(player.position)
                continue
            }
            let target = player.position
            guard walkTargets[id] != target else { continue }
            walkTargets[id] = target
            walkTasks[id]?.cancel()

            let start = shownPositions[id]
            let steps = (target - start + count) % count
            if steps == 0 { continue }
            guard steps <= 16, !player.inJail else {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { shownPositions[id] = target }
                busyUntil = max(busyUntil, Date().addingTimeInterval(0.5))
                continue
            }
            // Сначала докручиваются кубики, потом фишка трогается.
            let wait = max(0, lastRollAt.addingTimeInterval(Self.diceSpinSeconds).timeIntervalSinceNow)
            busyUntil = max(busyUntil, Date().addingTimeInterval(wait + Double(steps) * Self.stepSeconds + 0.2))
            walkTasks[id] = Task { @MainActor [weak self] in
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                for step in 1...steps {
                    guard !Task.isCancelled, let self else { return }
                    withAnimation(.easeInOut(duration: Self.stepSeconds * 0.9)) {
                        self.shownPositions[id] = (start + step) % count
                    }
                    try? await Task.sleep(for: .seconds(Self.stepSeconds))
                }
            }
        }
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
        syncTokens()
        recordResultIfNeeded()
        guard !isClient else { return }
        tick()
        let keepTimer = keepTimerOnce
        keepTimerOnce = false
        botTask?.cancel()
        defer {
            broadcast()
            autosave()
        }

        guard !state.isOver, let active = state.activePlayer else {
            cancelTimer()
            return
        }

        // Залог, выкуп, постройка и продажа филиала таймер хода не перезапускают.
        if keepTimer, deadline != nil, timerActor == active, timerTurn == state.turnNumber {
            scheduleAutoplay()
            return
        }
        cancelTimer()

        // Бонус «М1» срабатывает сам в конце хода — и у ботов, и у живых игроков.
        if case .awaitingBonusMove = state.phase {
            scheduleBonusMove(for: active)
            return
        }

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

    private func scheduleBonusMove(for player: PlayerID) {
        var delay = 700
        let animation = Int(busyUntil.timeIntervalSinceNow * 1000)
        if animation > 0 { delay = max(delay, animation + 250) }
        botTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled, let self, case .awaitingBonusMove = self.state.phase,
                  self.state.activePlayer == player else { return }
            self.tick()
            if let events = try? self.state.apply(.takeBonusMove, by: player) { self.record(events) }
            self.afterChange()
        }
    }

    private func scheduleBot() {
        // На аукционе боты торгуются быстро, иначе каждый шаг ставки тянется почти секунду.
        var delay = 650
        if case .auction = state.phase { delay = 150 }
        // Бот не ходит дальше, пока его фишка не дошла: иначе ход «убегает» вперёд картинки.
        let animation = Int(busyUntil.timeIntervalSinceNow * 1000)
        if animation > 0 { delay = max(delay, animation + 250) }
        botTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            self?.stepBot()
        }
    }

    private func stepBot() {
        guard let actor = state.activePlayer, state.players[actor].isBot else { return }
        tick()
        let action = bot.decide(state.publicView, as: actor)
        do {
            record(try state.apply(action, by: actor))
        } catch {
            let fallback = BotRunner.fallbackAction(for: state, actor: actor)
            if let events = try? state.apply(fallback, by: actor) { record(events) }
        }
        afterChange()
    }

    private func cancelTimer() {
        timerTask?.cancel()
        deadline = nil
    }

    /// Эти действия не сбрасывают время на ход.
    private static func keepsTimer(_ action: Action) -> Bool {
        switch action {
        case .build, .sellBranch, .mortgage, .unmortgage: return true
        default: return false
        }
    }

    // MARK: - Часы партии

    /// Хост (и единственный телефон) переводит часы движка перед каждым действием:
    /// от них зависят деньги за «Старт» и налог на аренду.
    private func tick() {
        guard !isClient else { return }
        state.advanceClock(to: Int(Date().timeIntervalSince(clockOrigin)))
        if let minutes = state.settings.noStartBonusAfterMinutes, !noStartAnnounced, !state.startBonusPaid {
            noStartAnnounced = true
            appendLog("⏳ Прошло \(minutes) мин: за проход «Старт» деньги больше не выдаются", player: nil, separator: false)
        }
        if let minutes = state.settings.rentTaxAfterMinutes, !rentTaxAnnounced, state.rentTaxPercent > 0 {
            rentTaxAnnounced = true
            appendLog("⏳ Прошло \(minutes) мин: налог на аренду — владелец получает 50%, дальше налог растёт до 99%", player: nil, separator: false)
        }
    }

    /// Время партии и действующие сейчас налоги — для строки под названием режима.
    func clockInfo(at date: Date) -> (time: String, notes: [String]) {
        let seconds = max(0, Int(date.timeIntervalSince(clockOrigin)))
        var copy = state
        copy.advanceClock(to: seconds)
        let time = seconds >= 3_600
            ? String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
        var notes: [String] = []
        if !copy.startBonusPaid { notes.append("«Старт» не платит") }
        if copy.rentTaxPercent > 0 { notes.append("налог на аренду \(copy.rentTaxPercent)%") }
        return (time, notes)
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
        timerActor = actor
        timerTurn = turn
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
        tick()
        let action = BotRunner.fallbackAction(for: state, actor: actor)
        if let events = try? state.apply(action, by: actor) { record(events) }
        afterChange()
    }

    // MARK: - Журнал

    private func record(_ events: [GameEvent]) {
        for event in events {
            if case .diceRolled = event { noteRoll() }
            if case .turnStarted(_, let round) = event, state.settings.speedDie,
               let start = state.settings.speedDieStartRound, start > 1, round == start, !speedDieAnnounced {
                speedDieAnnounced = true
                appendLog("🎲 С этого раунда в игре быстрый кубик!", player: nil, separator: false)
            }
            guard let text = EventText.text(event, in: state) else { continue }
            var separator = false
            if case .turnStarted = event { separator = true }
            appendLog(text, player: Self.subject(of: event), separator: separator)
        }
    }

    private func appendLog(_ text: String, player: PlayerID?, separator: Bool, chat: Bool = false) {
        log.insert(LogEntry(id: nextLogID, text: text, player: player, isSeparator: separator,
                            isChat: chat ? true : nil), at: 0)
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
             .mortgageExpired(let p, _), .debtStarted(let p, _), .bankrupt(let p, _),
             .rentTax(let p, _, _):
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

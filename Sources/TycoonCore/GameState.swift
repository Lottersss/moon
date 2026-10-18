/// Общие запросы к партии — доступны и движку, и ботам (через `PublicView`).
public protocol GameQueries {
    var board: Board { get }
    var settings: GameSettings { get }
    var players: [Player] { get }
    var cells: [Ownership] { get }
    var lastRoll: DiceRoll? { get }
}

extension GameQueries {
    public var activePlayerIDs: [PlayerID] {
        players.filter { !$0.isBankrupt }.map(\.id)
    }

    public var isTeamGame: Bool { players.contains { $0.team != nil } }

    /// Напарники по команде (сам себе игрок напарником не считается).
    public func areTeammates(_ a: PlayerID, _ b: PlayerID) -> Bool {
        a != b && players[a].team != nil && players[a].team == players[b].team
    }

    /// Соперник — любой другой игрок, кроме напарника.
    public func areOpponents(_ a: PlayerID, _ b: PlayerID) -> Bool {
        a != b && !areTeammates(a, b)
    }

    public func ownsFullGroup(_ player: PlayerID, _ group: ColorGroup) -> Bool {
        let groupCells = board.cells(in: group)
        return !groupCells.isEmpty && groupCells.allSatisfy { cells[$0].owner == player }
    }

    public func cellsOwned(by player: PlayerID) -> [CellID] {
        cells.indices.filter { cells[$0].owner == player }
    }

    public func groupHasBranches(_ cell: CellID) -> Bool {
        guard let group = board.cells[cell].group else { return false }
        return board.cells(in: group).contains { cells[$0].branches > 0 }
    }

    /// Номинальная стоимость улицы: заложенная стоит половину.
    public func assetValue(_ cell: CellID) -> Int {
        let price = board.cells[cell].price ?? 0
        return cells[cell].isMortgaged ? price / 2 : price
    }

    /// Ценность сторон договора по номиналу: что отдаёт инициатор и что отдаёт получатель.
    public func tradeSides(_ offer: TradeOffer) -> (fromGives: Int, toGives: Int) {
        let fromGives = offer.giveCells.reduce(offer.giveCash) { $0 + assetValue($1) }
        let toGives = offer.takeCells.reduce(offer.takeCash) { $0 + assetValue($1) }
        return (fromGives, toGives)
    }

    public func isUnfair(_ offer: TradeOffer, ratio: Double) -> Bool {
        let sides = tradeSides(offer)
        let high = max(sides.fromGives, sides.toGives)
        let low = max(min(sides.fromGives, sides.toGives), 1)
        return Double(high) > Double(low) * ratio
    }

    /// Общая ценность игрока: деньги + улицы + постройки.
    public func netWorth(of player: PlayerID) -> Int {
        var total = players[player].cash
        for cell in cellsOwned(by: player) {
            total += assetValue(cell)
            total += cells[cell].branches * (board.cells[cell].branchCost ?? 0)
        }
        return total
    }

    public func teamWorth(_ team: Int) -> Int {
        players.filter { $0.team == team }.reduce(0) { $0 + netWorth(of: $1.id) }
    }

    public func unmortgageCost(_ cell: CellID) -> Int {
        let mortgage = (board.cells[cell].price ?? 0) / 2
        return mortgage + mortgage * settings.unmortgageFeePercent / 100
    }

    public func branchRefund(_ cell: CellID) -> Int {
        (board.cells[cell].branchCost ?? 0) * settings.branchRefundPercent / 100
    }

    /// Сколько заплатит `payer`, попав на клетку. Напарники в 2×2 по умолчанию не платят.
    public func rent(for cell: CellID, payer: PlayerID, modifier: RentModifier = .normal) -> Int {
        guard let owner = cells[cell].owner, owner != payer, !cells[cell].isMortgaged else { return 0 }
        if areTeammates(owner, payer) && !settings.teammatesPayRent { return 0 }
        return rentAmount(for: cell, modifier: modifier)
    }

    /// Базовая рента клетки без учёта того, кто на неё попал.
    public func rentAmount(for cell: CellID, modifier: RentModifier = .normal) -> Int {
        guard let owner = cells[cell].owner, !cells[cell].isMortgaged else { return 0 }
        switch board.cells[cell].kind {
        case .company(let group, _, let rents, _):
            let level = cells[cell].branches
            if level > 0 { return rents[min(level, rents.count - 1)] }
            return ownsFullGroup(owner, group) ? rents[0] * 2 : rents[0]
        case .transport:
            let count = board.transportCells.filter { cells[$0].owner == owner }.count
            let rents = Board.transportRents
            let base = rents[min(max(count, 1), rents.count) - 1]
            return modifier == .doubleTransport ? base * 2 : base
        case .utility:
            let count = board.utilityCells.filter { cells[$0].owner == owner }.count
            let multipliers = Board.utilityMultipliers
            let multiplier = modifier == .maxUtility
                ? multipliers[multipliers.count - 1]
                : multipliers[min(max(count, 1), multipliers.count) - 1]
            return multiplier * (lastRoll?.total ?? 7)
        default:
            return 0
        }
    }
}

/// Полное состояние партии. Менять его можно только через `apply(_:by:)`.
public struct GameState: Codable, Sendable, Equatable, GameQueries {
    public let board: Board
    public let chanceCards: [Card]
    public let chestCards: [Card]
    public internal(set) var settings: GameSettings
    public internal(set) var players: [Player]
    public internal(set) var cells: [Ownership]
    public internal(set) var turnOrder: [PlayerID]
    public internal(set) var turnIndex: Int
    /// Номер круга, начиная с 1. Круг заканчивается, когда сходили все игроки.
    public internal(set) var round: Int
    public internal(set) var turnNumber: Int
    public internal(set) var phase: Phase
    public internal(set) var lastRoll: DiceRoll?
    public internal(set) var lastSpeedDie: SpeedDieFace?
    public internal(set) var doublesInRow: Int
    public internal(set) var extraRollPending: Bool
    /// После хода нужно сделать бонус-ход (выпал бонус на третьем кубике).
    public internal(set) var bonusMovePending: Bool
    public internal(set) var pendingTrade: TradeOffer?
    public internal(set) var tradeOffersThisTurn: Int
    /// Сколько домов построено в каждой группе за текущий ход.
    public internal(set) var buildsThisTurn: [ColorGroup: Int]
    /// Сколько секунд идёт партия. Часы ведёт приложение хоста через `advanceClock(to:)`.
    /// Опционально, чтобы читались старые сохранения.
    public internal(set) var clockSeconds: Int? = nil

    // Скрытая часть: генератор, колоды и мешок кубиков не попадают в PublicView.
    var rng: SplitMix64
    var chanceDeck: DeckState
    var chestDeck: DeckState
    var diceBag: [DiceRoll]
    /// Только для тестов: заранее заданные броски.
    var riggedRolls: [DiceRoll] = []
    var riggedSpeedDie: [SpeedDieFace] = []

    /// - Parameters:
    ///   - players: от 2 до 6 игроков. Для режима 2×2 у всех задан `team`.
    ///   - seed: одинаковый seed — одинаковая партия.
    public init(players setups: [PlayerSetup],
                settings: GameSettings = .monopolyOne,
                board: Board = .standard,
                chanceCards: [Card] = ChanceDeck.standard,
                chestCards: [Card] = CommunityChestDeck.standard,
                seed: UInt64) {
        precondition((2...6).contains(setups.count), "Игроков должно быть от 2 до 6")
        let teams = setups.map(\.team)
        precondition(teams.allSatisfy { $0 == nil } || teams.allSatisfy { $0 != nil },
                     "Команда должна быть задана либо у всех игроков, либо ни у кого")
        precondition(Set(teams.compactMap { $0 }).count != 1, "В командной игре нужно минимум две команды")
        for deck in [chanceCards, chestCards] {
            precondition(deck.enumerated().allSatisfy { $0.offset == $0.element.id },
                         "id карточки должен совпадать с её индексом")
        }

        var rng = SplitMix64(seed: seed)

        // «Перестановка»: доска перемешивается один раз в начале партии.
        var gameBoard = board
        var chance = chanceCards
        var chest = chestCards
        if settings.shuffleBoard {
            let rearranged = board.rearranged(using: &rng)
            gameBoard = rearranged.board
            chance = chance.map { $0.remapped(rearranged.newIDs) }
            chest = chest.map { $0.remapped(rearranged.newIDs) }
        }

        self.board = gameBoard
        self.chanceCards = chance
        self.chestCards = chest
        self.settings = settings
        self.players = setups.enumerated().map { index, setup in
            Player(id: index, name: setup.name, isBot: setup.isBot, team: setup.team,
                   cash: settings.startingCash + setup.bonusCash)
        }
        self.cells = Array(repeating: Ownership(), count: gameBoard.count)
        self.turnOrder = Self.makeTurnOrder(setups, randomize: settings.randomizeTurnOrder, rng: &rng)
        self.turnIndex = 0
        self.round = 1
        self.turnNumber = 1
        self.phase = .awaitingRoll
        self.lastRoll = nil
        self.lastSpeedDie = nil
        self.doublesInRow = 0
        self.extraRollPending = false
        self.bonusMovePending = false
        self.pendingTrade = nil
        self.tradeOffersThisTurn = 0
        self.buildsThisTurn = [:]
        self.chanceDeck = DeckState(drawPile: Array(chance.indices).shuffled(using: &rng), discard: [])
        self.chestDeck = DeckState(drawPile: Array(chest.indices).shuffled(using: &rng), discard: [])
        self.diceBag = []
        self.rng = rng
    }

    /// Порядок ходов. В 2×2 команды чередуются: A1, B1, A2, B2.
    static func makeTurnOrder(_ setups: [PlayerSetup], randomize: Bool, rng: inout SplitMix64) -> [PlayerID] {
        guard setups.contains(where: { $0.team != nil }) else {
            var order = Array(setups.indices)
            if randomize { order.shuffle(using: &rng) }
            return order
        }

        var teamIDs: [Int] = []
        for setup in setups {
            if let team = setup.team, !teamIDs.contains(team) { teamIDs.append(team) }
        }
        if randomize { teamIDs.shuffle(using: &rng) }

        var members: [[PlayerID]] = teamIDs.map { team in
            setups.indices.filter { setups[$0].team == team }
        }
        if randomize {
            for index in members.indices { members[index].shuffle(using: &rng) }
        }

        var order: [PlayerID] = []
        let longest = members.map(\.count).max() ?? 0
        for slot in 0..<longest {
            for team in members where slot < team.count { order.append(team[slot]) }
        }
        return order
    }

    public var currentPlayerID: PlayerID { turnOrder[turnIndex] }

    /// Чьего действия сейчас ждёт игра. `nil` — партия окончена.
    public var activePlayer: PlayerID? {
        if let trade = pendingTrade { return trade.to }
        switch phase {
        case .gameOver: return nil
        case .auction(let auction): return auction.currentBidder
        case .debt(let debt): return debt.debtor
        default: return currentPlayerID
        }
    }

    public var isOver: Bool {
        if case .gameOver = phase { return true }
        return false
    }

    /// Команда-победитель в режиме 2×2.
    public var winningTeam: Int? {
        guard case .gameOver(let winner?) = phase else { return nil }
        return players[winner].team
    }

    /// То, что видно всем за столом. Боты принимают решения только по этому.
    public var publicView: PublicView { PublicView(self) }

    func cards(_ kind: DeckKind) -> [Card] {
        switch kind {
        case .chance: chanceCards
        case .communityChest: chestCards
        }
    }

    // MARK: - Случайность (только через свой генератор)

    mutating func randomInt(in range: ClosedRange<Int>) -> Int {
        var generator = rng
        let value = Int.random(in: range, using: &generator)
        rng = generator
        return value
    }

    mutating func shuffledWithRNG<T>(_ items: [T]) -> [T] {
        var generator = rng
        let result = items.shuffled(using: &generator)
        rng = generator
        return result
    }

    mutating func rollDice() -> DiceRoll {
        if !riggedRolls.isEmpty { return riggedRolls.removeFirst() }
        switch settings.diceMode {
        case .random:
            let d1 = randomInt(in: 1...6)
            let d2 = randomInt(in: 1...6)
            return DiceRoll(d1, d2)
        case .balanced:
            if diceBag.isEmpty {
                let bag = shuffledWithRNG(DiceRoll.allCombinations)
                diceBag = bag
            }
            return diceBag.removeLast()
        }
    }

    mutating func rollSpeedDie() -> SpeedDieFace {
        if !riggedSpeedDie.isEmpty { return riggedSpeedDie.removeFirst() }
        let faces = settings.speedDieFaces
        return faces[randomInt(in: 0...(faces.count - 1))]
    }
}

/// Публичная часть состояния: всё, что видно игрокам за столом.
/// Нет генератора, порядка колод и мешка кубиков — боты не могут «подсмотреть» будущее.
public struct PublicView: Sendable, GameQueries {
    public let board: Board
    public let settings: GameSettings
    public let players: [Player]
    public let cells: [Ownership]
    public let turnOrder: [PlayerID]
    public let currentPlayerID: PlayerID
    public let phase: Phase
    public let pendingTrade: TradeOffer?
    public let tradeOffersThisTurn: Int
    public let buildsThisTurn: [ColorGroup: Int]
    public let round: Int
    public let lastRoll: DiceRoll?

    init(_ state: GameState) {
        board = state.board
        settings = state.settings
        players = state.players
        cells = state.cells
        turnOrder = state.turnOrder
        currentPlayerID = state.currentPlayerID
        phase = state.phase
        pendingTrade = state.pendingTrade
        tradeOffersThisTurn = state.tradeOffersThisTurn
        buildsThisTurn = state.buildsThisTurn
        round = state.round
        lastRoll = state.lastRoll
    }
}

// MARK: - Сетевая игра

extension GameState {
    /// Копия для отправки другим телефонам: без генератора и порядка колод.
    /// Клиент видит всё, что видно за столом, но не может заранее узнать кубики и карточки.
    public func redactedForClients() -> GameState {
        var copy = self
        copy.rng = SplitMix64(seed: 0)
        copy.chanceDeck.drawPile.sort()
        copy.chestDeck.drawPile.sort()
        copy.diceBag = []
        copy.riggedRolls = []
        copy.riggedSpeedDie = []
        return copy
    }

    /// Передать игрока боту (например, телефон отключился) или вернуть живому игроку.
    public mutating func setBot(_ player: PlayerID, _ isBot: Bool) {
        guard players.indices.contains(player) else { return }
        players[player].isBot = isBot
    }
}


// MARK: - Часы партии

extension GameState {
    /// Ведёт часы партии: время только растёт. Вызывает хост перед каждым действием.
    public mutating func advanceClock(to seconds: Int) {
        clockSeconds = max(clockSeconds ?? 0, seconds)
    }

    /// Выдают ли сейчас деньги за проход «Старт»: в Monopoly One с 46-й минуты (в быстрой игре — с 31-й) нет.
    public var startBonusPaid: Bool {
        guard let limit = settings.noStartBonusAfterMinutes else { return true }
        return (clockSeconds ?? 0) < limit * 60
    }

    /// Налог на аренду в процентах: 0 до его начала, затем 50% и +1% в минуту до 99%.
    public var rentTaxPercent: Int {
        guard let start = settings.rentTaxAfterMinutes else { return 0 }
        let seconds = (clockSeconds ?? 0) - start * 60
        guard seconds >= 0 else { return 0 }
        return min(99, 50 + seconds / 60)
    }

    /// Сколько из выплаченной аренды достаётся владельцу.
    func rentIncome(afterTax amount: Int) -> Int {
        amount * (100 - rentTaxPercent) / 100
    }
}

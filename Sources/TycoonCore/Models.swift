public typealias PlayerID = Int

// MARK: - Игроки и владения

public struct PlayerSetup: Codable, Sendable, Equatable {
    public var name: String
    public var isBot: Bool
    /// Гандикап: дополнительные стартовые деньги (например, новичку). По умолчанию 0.
    public var bonusCash: Int
    /// Номер команды для режима 2×2. `nil` — каждый сам за себя.
    public var team: Int?

    public init(name: String, isBot: Bool = false, bonusCash: Int = 0, team: Int? = nil) {
        self.name = name
        self.isBot = isBot
        self.bonusCash = bonusCash
        self.team = team
    }
}

public struct Player: Codable, Sendable, Equatable, Identifiable {
    public let id: PlayerID
    public var name: String
    public var isBot: Bool
    public var team: Int?
    public var cash: Int
    public var position: CellID = 0
    public var inJail = false
    public var jailTurns = 0
    /// Карточки освобождения из тюрьмы и колоды, куда их вернуть после использования.
    public var jailCardDecks: [DeckKind] = []
    public var isBankrupt = false

    public var jailCards: Int { jailCardDecks.count }

    public init(id: PlayerID, name: String, isBot: Bool, team: Int? = nil, cash: Int) {
        self.id = id
        self.name = name
        self.isBot = isBot
        self.team = team
        self.cash = cash
    }
}

public struct Ownership: Codable, Sendable, Equatable {
    public var owner: PlayerID?
    /// 0 — без построек, 1–4 — дома, 5 — отель.
    public var branches = 0
    public var isMortgaged = false
    /// Сколько ходов владельца осталось, чтобы выкупить залог. `nil` — без срока.
    public var mortgageTurnsLeft: Int?

    public init() {}
}

// MARK: - Настройки партии

public enum DiceMode: String, Codable, Sendable, CaseIterable {
    /// Обычные независимые броски.
    case random
    /// «Ровные кубики»: мешок из 36 комбинаций без возврата. Распределение то же, полос невезения меньше.
    case balanced
}

/// Грань третьего кубика (режим «Перестановка» / быстрая игра).
public enum SpeedDieFace: Codable, Sendable, Equatable, Hashable {
    /// Прибавить к ходу 1, 2 или 3. Если совпало с дублем — тройка, телепорт на любую клетку.
    case number(Int)
    /// Автобус: игрок выбирает, идти на первый кубик, на второй или на сумму.
    case bus
    /// Бонус-ход: после обычного хода — к ближайшей свободной улице
    /// (если свободных нет — к ближайшей чужой).
    case bonus
}

public enum TradePolicy: Codable, Sendable, Equatable {
    /// Любые договоры (как в Monopoly One).
    case free
    /// Договор с перекосом больше `ratio` раз помечается для всех игроков.
    case warnIfUnfair(ratio: Double)
    /// Договор с перекосом больше `ratio` раз запрещён (защита от «подарков»).
    case forbidIfUnfair(ratio: Double)
}

public struct GameSettings: Codable, Sendable, Equatable {
    public var startingCash = 15_000
    public var passStartBonus = 2_000
    public var jailFine = 500
    /// Сколько попыток выбросить дубль в тюрьме; после последней — штраф и ход.
    public var maxJailRolls = 3
    /// Доля стоимости дома, которую возвращает продажа. В Monopoly One — 100%.
    public var branchRefundPercent = 100
    /// Через сколько ходов владельца невыкупленный залог уходит банку. `nil` — без срока.
    public var mortgageTurnLimit: Int? = 15
    /// Наценка при выкупе залога, в процентах от залоговой суммы.
    public var unmortgageFeePercent = 10
    public var auctionStep = 100
    /// Аукцион начинается с цены улицы, как в Monopoly One. Если никто не согласен — улица остаётся свободной.
    /// `false` — торги с нуля, как в классической настольной Монополии.
    public var auctionStartsAtPrice = true
    public var jackpotEnabled = true
    public var jackpotBet = 1_000
    /// Ограничение «один дом на монополию за ход». `nil` — без ограничения.
    public var maxBuildsPerGroupPerTurn: Int? = nil
    /// Лимит кругов. После него побеждает самый богатый (в 2×2 — самая богатая команда).
    /// `nil` — до последнего игрока или команды.
    public var maxRounds: Int? = nil
    public var diceMode: DiceMode = .random
    public var tradePolicy: TradePolicy = .warnIfUnfair(ratio: 2.0)
    public var maxTradeOffersPerTurn = 3
    public var randomizeTurnOrder = true

    /// Третий кубик.
    public var speedDie = false
    public var speedDieFaces: [SpeedDieFace] = [.number(1), .number(2), .number(3), .bus, .bonus, .bonus]
    /// Перемешать клетки доски (углы остаются на месте).
    public var shuffleBoard = false
    /// Платят ли напарники ренту друг другу в режиме 2×2.
    public var teammatesPayRent = false

    public init() {}

    /// Обычный режим: правила Monopoly One на классической доске.
    /// Сверь значения с игрой и поправь при необходимости.
    public static var monopolyOne: GameSettings { GameSettings() }

    /// «Перестановка»: перемешанная доска и третий кубик.
    public static var reshuffle: GameSettings {
        var settings = GameSettings()
        settings.shuffleBoard = true
        settings.speedDie = true
        return settings
    }
}

// MARK: - Фазы хода

public struct Auction: Codable, Sendable, Equatable {
    public var cell: CellID
    public var highestBid: Int
    public var highestBidder: PlayerID?
    /// Кто ещё торгуется, в порядке ходов.
    public var bidders: [PlayerID]
    public var turnIndex: Int
    /// Стартовая цена: первая ставка должна быть не меньше неё.
    public var startPrice: Int

    public var currentBidder: PlayerID { bidders[turnIndex] }

    /// Минимальная допустимая ставка прямо сейчас.
    public func minimumBid(step: Int) -> Int {
        highestBidder == nil ? startPrice : highestBid + step
    }
}

public enum Creditor: Codable, Sendable, Equatable, Hashable {
    case bank
    case player(PlayerID)
}

public struct Payment: Codable, Sendable, Equatable {
    public var to: Creditor
    public var amount: Int

    public init(to: Creditor, amount: Int) {
        self.to = to
        self.amount = amount
    }
}

public enum PaymentReason: Codable, Sendable, Equatable {
    case rent(CellID)
    case tax(CellID)
    case jailFine
    case card(deck: DeckKind, id: Int)
    case jackpotBet
}

/// Что делать после того, как платёж прошёл.
public enum Continuation: Codable, Sendable, Equatable {
    case finishLanding
    case moveBy(Int)
}

public struct Debt: Codable, Sendable, Equatable {
    public var debtor: PlayerID
    public var payments: [Payment]
    public var reason: PaymentReason
    public var then: Continuation

    public var total: Int { payments.reduce(0) { $0 + $1.amount } }
}

public enum Phase: Codable, Sendable, Equatable {
    case awaitingRoll
    /// Выпал автобус: выбрать, на сколько идти.
    case awaitingMoveChoice(options: [Int])
    /// Выпала тройка: выбрать любую клетку.
    case awaitingTeleport
    /// Выпал бонус-ход: после обычного хода переход к ближайшей свободной улице.
    case awaitingBonusMove
    case awaitingBuyDecision(cell: CellID)
    case auction(Auction)
    case awaitingJackpot(cell: CellID)
    case awaitingEndTurn
    /// Игрок должен собрать деньги (продать дома, заложить) и заплатить, либо объявить банкротство.
    case debt(Debt)
    /// `winner` — победитель; в 2×2 — самый богатый игрок победившей команды. `nil` — ничья.
    case gameOver(winner: PlayerID?)
}

public enum RentModifier: Codable, Sendable, Equatable {
    case normal
    case doubleTransport
    case maxUtility
}

// MARK: - Договоры

public struct TradeOffer: Codable, Sendable, Equatable {
    public var from: PlayerID
    public var to: PlayerID
    /// Что отдаёт инициатор.
    public var giveCells: [CellID]
    public var giveCash: Int
    /// Что инициатор просит взамен.
    public var takeCells: [CellID]
    public var takeCash: Int

    public init(from: PlayerID, to: PlayerID,
                giveCells: [CellID] = [], giveCash: Int = 0,
                takeCells: [CellID] = [], takeCash: Int = 0) {
        self.from = from
        self.to = to
        self.giveCells = giveCells
        self.giveCash = giveCash
        self.takeCells = takeCells
        self.takeCash = takeCash
    }
}

// MARK: - Действия и события

public enum Action: Codable, Sendable, Equatable {
    case roll
    case payJailFine
    case useJailCard
    /// Ответ на автобус: число шагов из предложенных вариантов.
    case chooseMove(Int)
    /// Ответ на тройку: клетка назначения.
    case teleport(CellID)
    case takeBonusMove
    case buy
    case declineBuy
    case bid(Int)
    case passBid
    /// Ставка в джекпоте на 1–3 числа одного кубика. Выигрыш = ставка × 6 / количество чисел,
    /// так что ожидание у всех вариантов одинаковое (ноль).
    case playJackpot(numbers: [Int])
    case skipJackpot
    case build(CellID)
    case sellBranch(CellID)
    case mortgage(CellID)
    case unmortgage(CellID)
    case proposeTrade(TradeOffer)
    case acceptTrade
    case rejectTrade
    case cancelTrade
    case payDebt
    case declareBankruptcy
    case endTurn
}

public enum GameEvent: Codable, Sendable, Equatable {
    case turnStarted(player: PlayerID, round: Int)
    case diceRolled(player: PlayerID, roll: DiceRoll)
    case speedDieRolled(player: PlayerID, face: SpeedDieFace)
    case moved(player: PlayerID, from: CellID, to: CellID, passedStart: Bool)
    case startBonus(player: PlayerID, amount: Int)
    case bought(player: PlayerID, cell: CellID, price: Int)
    case paid(from: PlayerID, to: Creditor, amount: Int, reason: PaymentReason)
    case received(player: PlayerID, amount: Int)
    case cardDrawn(player: PlayerID, deck: DeckKind, card: Card)
    case sentToJail(player: PlayerID)
    case leftJail(player: PlayerID)
    case auctionStarted(cell: CellID)
    case bidPlaced(player: PlayerID, amount: Int)
    case bidPassed(player: PlayerID)
    case auctionWon(player: PlayerID, cell: CellID, price: Int)
    case auctionNoBids(cell: CellID)
    case jackpotPlayed(player: PlayerID, numbers: [Int], rolled: Int, payout: Int)
    case built(player: PlayerID, cell: CellID, level: Int)
    case branchSold(player: PlayerID, cell: CellID, level: Int)
    case mortgaged(player: PlayerID, cell: CellID)
    case unmortgaged(player: PlayerID, cell: CellID)
    case mortgageExpired(player: PlayerID, cell: CellID)
    case tradeProposed(offer: TradeOffer, flaggedUnfair: Bool)
    case tradeAccepted(offer: TradeOffer)
    case tradeRejected(offer: TradeOffer)
    case tradeCancelled(offer: TradeOffer)
    case debtStarted(player: PlayerID, amount: Int)
    case bankrupt(player: PlayerID, heir: PlayerID?)
    case gameOver(winner: PlayerID?, team: Int?, byRoundLimit: Bool)
}

public enum GameError: Error, Equatable, Sendable, CustomStringConvertible {
    case gameOver
    case notYourTurn
    case invalidAction
    case notEnoughCash
    case notOwner
    case notPurchasable
    case needFullGroup
    case groupHasMortgage
    case unevenBuild
    case maxLevel
    case buildLimitThisTurn
    case noBranches
    case hasBranchesInGroup
    case alreadyMortgaged
    case notMortgaged
    case tradePending
    case invalidTrade(String)
    case unfairTrade
    case tooManyOffers
    case bidTooLow
    case notInJail
    case noJailCard
    case invalidJackpotNumbers
    case invalidMoveChoice
    case invalidTeleportTarget

    public var description: String {
        switch self {
        case .gameOver: "Игра окончена"
        case .notYourTurn: "Сейчас не ваш ход"
        case .invalidAction: "Это действие сейчас недоступно"
        case .notEnoughCash: "Недостаточно денег"
        case .notOwner: "Это не ваша улица"
        case .notPurchasable: "Эту клетку нельзя купить"
        case .needFullGroup: "Нужна вся монополия"
        case .groupHasMortgage: "В монополии есть заложенная улица"
        case .unevenBuild: "Дома строятся и продаются равномерно"
        case .maxLevel: "Уже построен отель"
        case .buildLimitThisTurn: "В этой монополии уже строили в этот ход"
        case .noBranches: "Здесь нет построек"
        case .hasBranchesInGroup: "Сначала продайте дома в этой монополии"
        case .alreadyMortgaged: "Улица уже заложена"
        case .notMortgaged: "Улица не заложена"
        case .tradePending: "Сначала ответьте на договор"
        case .invalidTrade(let reason): "Некорректный договор: \(reason)"
        case .unfairTrade: "Договор слишком неравный"
        case .tooManyOffers: "Слишком много предложений за ход"
        case .bidTooLow: "Ставка слишком мала"
        case .notInJail: "Вы не в тюрьме"
        case .noJailCard: "Нет карточки освобождения"
        case .invalidJackpotNumbers: "Выберите от 1 до 3 разных чисел от 1 до 6"
        case .invalidMoveChoice: "Такого варианта хода нет"
        case .invalidTeleportTarget: "На эту клетку нельзя телепортироваться"
        }
    }
}

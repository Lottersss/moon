import Testing
@testable import TycoonCore

/// Партия с фиксированным порядком ходов: игрок 0 ходит первым.
func makeGame(players: Int = 2, board: Board = .standard,
              configure: (inout GameSettings) -> Void = { _ in }) -> GameState {
    var settings = GameSettings.monopolyOne
    settings.randomizeTurnOrder = false
    configure(&settings)
    return GameState(players: (0..<players).map { PlayerSetup(name: "Игрок \($0)") },
                     settings: settings, board: board, seed: 42)
}

/// 2×2: игроки 0 и 1 — команда 0, игроки 2 и 3 — команда 1.
func makeTeamGame(configure: (inout GameSettings) -> Void = { _ in }) -> GameState {
    var settings = GameSettings.monopolyOne
    settings.randomizeTurnOrder = false
    configure(&settings)
    let setups = (0..<4).map { PlayerSetup(name: "Игрок \($0)", team: $0 / 2) }
    return GameState(players: setups, settings: settings, seed: 42)
}

func botGame(seed: UInt64, settings base: GameSettings = .monopolyOne, teams: Bool = false) -> GameState {
    var settings = base
    settings.maxRounds = 150
    let setups = (0..<4).map { PlayerSetup(name: "Бот \($0)", isBot: true, team: teams ? $0 / 2 : nil) }
    return GameState(players: setups, settings: settings, seed: seed)
}

// MARK: - Доска

@Test func classicBoardLayout() {
    let board = Board.standard
    #expect(board.count == 40)
    #expect(board.cells.filter { $0.group != nil }.count == 22)
    #expect(board.transportCells == [5, 15, 25, 35])
    #expect(board.utilityCells == [12, 28])
    #expect(board.cells.filter { $0.kind == .chance }.map(\.id) == [7, 22, 36])
    #expect(board.cells.filter { $0.kind == .communityChest }.map(\.id) == [2, 17, 33])
    #expect(board.cells[20].kind == .parking)
    #expect(ColorGroup.allCases.map { board.cells(in: $0).count } == [2, 3, 3, 3, 3, 3, 3, 2])
}

// MARK: - Случайность

@Test func sameSeedGivesSameGame() {
    var first = botGame(seed: 7)
    var second = botGame(seed: 7)
    BotRunner.runBots(&first)
    BotRunner.runBots(&second)
    #expect(first == second)
}

@Test func balancedDiceUseEveryCombinationOnce() {
    var game = makeGame { $0.diceMode = .balanced }
    var counts: [DiceRoll: Int] = [:]
    for _ in 0..<36 { counts[game.rollDice(), default: 0] += 1 }
    #expect(counts.count == 36)
    #expect(counts.values.allSatisfy { $0 == 1 })
}

@Test func failedActionLeavesStateUnchanged() {
    var game = makeGame()
    let before = game
    #expect(throws: GameError.invalidAction) { try game.apply(.buy, by: 0) }
    #expect(throws: GameError.notYourTurn) { try game.apply(.roll, by: 1) }
    #expect(game == before)
}

// MARK: - Покупка, рента, аукцион

@Test func buyingDeductsPrice() throws {
    var game = makeGame()
    game.riggedRolls = [DiceRoll(1, 2)]
    try game.apply(.roll, by: 0)
    #expect(game.phase == .awaitingBuyDecision(cell: 3))
    try game.apply(.buy, by: 0)
    #expect(game.cells[3].owner == 0)
    #expect(game.players[0].cash == 15_000 - 600)
    #expect(game.phase == .awaitingEndTurn)
}

@Test func fullGroupDoublesBaseRent() throws {
    var game = makeGame()
    game.cells[1].owner = 1
    game.cells[3].owner = 1
    game.riggedRolls = [DiceRoll(1, 2)]
    try game.apply(.roll, by: 0)
    #expect(game.players[0].cash == 15_000 - 80)
    #expect(game.players[1].cash == 15_000 + 80)
}

@Test func stationRentGrowsWithCount() {
    var game = makeGame()
    game.cells[5].owner = 1
    #expect(game.rent(for: 5, payer: 0) == 250)
    game.cells[15].owner = 1
    game.cells[25].owner = 1
    #expect(game.rent(for: 5, payer: 0) == 1_000)
}

@Test func auctionStartsAtStreetPrice() throws {
    var game = makeGame()
    game.riggedRolls = [DiceRoll(1, 2)]
    try game.apply(.roll, by: 0)
    try game.apply(.declineBuy, by: 0)
    #expect(throws: GameError.bidTooLow) { try game.apply(.bid(500), by: 1) }
    try game.apply(.bid(600), by: 1)
    try game.apply(.passBid, by: 0)
    #expect(game.cells[3].owner == 1)
    #expect(game.players[1].cash == 15_000 - 600)
}

@Test func nobodyBidsStreetStaysFree() throws {
    var game = makeGame()
    game.riggedRolls = [DiceRoll(1, 2)]
    try game.apply(.roll, by: 0)
    try game.apply(.declineBuy, by: 0)
    let events1 = try game.apply(.passBid, by: 1)
    let events2 = try game.apply(.passBid, by: 0)
    #expect((events1 + events2).contains(.auctionNoBids(cell: 3)))
    #expect(game.cells[3].owner == nil)
}

@Test func declinedStreetGoesToAuction() throws {
    var game = makeGame { $0.auctionStartsAtPrice = false }
    game.riggedRolls = [DiceRoll(1, 2)]
    try game.apply(.roll, by: 0)
    try game.apply(.declineBuy, by: 0)
    #expect(game.activePlayer == 1)
    #expect(throws: GameError.bidTooLow) { try game.apply(.bid(50), by: 1) }
    try game.apply(.bid(100), by: 1)
    try game.apply(.bid(200), by: 0)
    try game.apply(.passBid, by: 1)
    #expect(game.cells[3].owner == 0)
    #expect(game.players[0].cash == 15_000 - 200)
    #expect(game.phase == .awaitingEndTurn)
}

@Test func passingStartPaysBonus() throws {
    var game = makeGame()
    game.players[0].position = 38
    game.riggedRolls = [DiceRoll(1, 2)]
    try game.apply(.roll, by: 0)
    #expect(game.players[0].position == 1)
    #expect(game.players[0].cash == 15_000 + 2_000)
}

@Test func freeParkingDoesNothing() throws {
    var game = makeGame()
    game.players[0].position = 10
    game.riggedRolls = [DiceRoll(4, 6)]
    try game.apply(.roll, by: 0)
    #expect(game.players[0].position == 20)
    #expect(game.players[0].cash == 15_000)
    #expect(game.phase == .awaitingEndTurn)
}

@Test func communityChestDrawsFromItsOwnDeck() throws {
    var game = makeGame()
    game.riggedRolls = [DiceRoll(1, 1)]
    let events = try game.apply(.roll, by: 0)
    let decks = events.compactMap { event -> DeckKind? in
        if case .cardDrawn(_, let deck, _) = event { return deck }
        return nil
    }
    #expect(decks == [.communityChest])
}

// MARK: - Дома и залог

@Test func housesAreBuiltEvenly() throws {
    var game = makeGame()
    game.cells[1].owner = 0
    game.cells[3].owner = 0
    try game.apply(.build(1), by: 0)
    #expect(throws: GameError.unevenBuild) { try game.apply(.build(1), by: 0) }
    try game.apply(.build(3), by: 0)
    #expect(game.cells[1].branches == 1 && game.cells[3].branches == 1)
    #expect(game.players[0].cash == 15_000 - 1_000)
}

@Test func housesSellForFullPrice() throws {
    var game = makeGame()
    game.cells[1].owner = 0
    game.cells[3].owner = 0
    try game.apply(.build(1), by: 0)
    try game.apply(.sellBranch(1), by: 0)
    #expect(game.players[0].cash == 15_000)
}

@Test func buildLimitPerTurn() throws {
    var game = makeGame { $0.maxBuildsPerGroupPerTurn = 1 }
    game.cells[1].owner = 0
    game.cells[3].owner = 0
    try game.apply(.build(1), by: 0)
    #expect(throws: GameError.buildLimitThisTurn) { try game.apply(.build(3), by: 0) }
}

@Test func cannotBuildWithoutFullGroup() {
    var game = makeGame()
    game.cells[1].owner = 0
    #expect(throws: GameError.needFullGroup) { try game.apply(.build(1), by: 0) }
}

@Test func mortgageExpiresAfterLimit() throws {
    var game = makeGame { $0.mortgageTurnLimit = 2 }
    game.cells[1].owner = 0
    try game.apply(.mortgage(1), by: 0)
    #expect(game.players[0].cash == 15_000 + 300)
    var events: [GameEvent] = []
    game.tickMortgages(for: 0, &events)
    #expect(game.cells[1].owner == 0)
    game.tickMortgages(for: 0, &events)
    #expect(game.cells[1].owner == nil)
    #expect(events.contains(.mortgageExpired(player: 0, cell: 1)))
}

@Test func unmortgageCostsTenPercentMore() throws {
    var game = makeGame()
    game.cells[1].owner = 0
    try game.apply(.mortgage(1), by: 0)
    try game.apply(.unmortgage(1), by: 0)
    #expect(game.players[0].cash == 15_000 + 300 - 330)
}

// MARK: - Тюрьма

@Test func threeDoublesSendToJail() throws {
    var game = makeGame()
    game.riggedRolls = [DiceRoll(5, 5), DiceRoll(5, 5), DiceRoll(5, 5)]
    try game.apply(.roll, by: 0)   // → 10, просто посещение
    try game.apply(.roll, by: 0)   // → 20, парковка
    try game.apply(.roll, by: 0)   // третий дубль
    #expect(game.players[0].inJail)
    #expect(game.players[0].position == game.board.jailCell)
    #expect(game.phase == .awaitingEndTurn)
}

@Test func goToJailCell() throws {
    var game = makeGame()
    game.players[0].position = 25
    game.riggedRolls = [DiceRoll(2, 3)]
    try game.apply(.roll, by: 0)
    #expect(game.players[0].inJail)
    #expect(game.players[0].position == 10)
}

@Test func thirdFailedJailRollForcesFine() throws {
    var game = makeGame()
    game.players[0].inJail = true
    game.players[0].position = 10
    game.riggedRolls = [
        DiceRoll(1, 2), DiceRoll(4, 6),   // игрок 0 не выбросил дубль, игрок 1 → 10
        DiceRoll(1, 2), DiceRoll(4, 6),   // снова мимо, игрок 1 → 20
        DiceRoll(1, 2),                   // третья попытка: штраф и ход на 3
    ]
    for _ in 0..<2 {
        try game.apply(.roll, by: 0)
        try game.apply(.endTurn, by: 0)
        try game.apply(.roll, by: 1)
        try game.apply(.endTurn, by: 1)
    }
    try game.apply(.roll, by: 0)
    #expect(!game.players[0].inJail)
    #expect(game.players[0].position == 13)
    #expect(game.players[0].cash == 15_000 - 500)
}

@Test func jailCardReturnsToItsDeck() throws {
    var game = makeGame()
    game.players[0].inJail = true
    game.players[0].position = 10
    game.players[0].jailCardDecks = [.communityChest]
    try game.apply(.useJailCard, by: 0)
    #expect(!game.players[0].inJail)
    #expect(game.chestDeck.discard == [4])
    #expect(game.chanceDeck.discard.isEmpty)
}

// MARK: - Долги и банкротство

@Test func bankruptcyTransfersEverythingToCreditor() throws {
    var game = makeGame()
    game.cells[37].owner = 1
    game.cells[39].owner = 1
    game.cells[37].branches = 5
    game.cells[39].branches = 5
    game.cells[1].owner = 0
    game.players[0].cash = 100
    game.players[0].position = 35
    game.riggedRolls = [DiceRoll(1, 3)]
    try game.apply(.roll, by: 0)
    guard case .debt(let debt) = game.phase else {
        Issue.record("ожидалась фаза долга")
        return
    }
    #expect(debt.total == 20_000)
    #expect(throws: GameError.notEnoughCash) { try game.apply(.payDebt, by: 0) }
    try game.apply(.mortgage(1), by: 0)
    try game.apply(.declareBankruptcy, by: 0)
    #expect(game.players[0].isBankrupt)
    #expect(game.cells[1].owner == 1)
    #expect(game.cells[1].isMortgaged)
    #expect(game.phase == .gameOver(winner: 1))
}

// MARK: - Договоры

@Test func unfairTradeCanBeForbidden() {
    var game = makeGame { $0.tradePolicy = .forbidIfUnfair(ratio: 1.5) }
    game.cells[39].owner = 0
    let offer = TradeOffer(from: 0, to: 1, giveCells: [39], takeCash: 100)
    #expect(throws: GameError.unfairTrade) { try game.apply(.proposeTrade(offer), by: 0) }
}

@Test func unfairTradeIsFlaggedAndCanBeAccepted() throws {
    var game = makeGame { $0.tradePolicy = .warnIfUnfair(ratio: 2.0) }
    game.cells[39].owner = 0
    let offer = TradeOffer(from: 0, to: 1, giveCells: [39], takeCash: 100)
    let events = try game.apply(.proposeTrade(offer), by: 0)
    #expect(events.contains(.tradeProposed(offer: offer, flaggedUnfair: true)))
    #expect(game.activePlayer == 1)
    #expect(throws: GameError.tradePending) { try game.apply(.roll, by: 0) }
    try game.apply(.acceptTrade, by: 1)
    #expect(game.cells[39].owner == 1)
    #expect(game.players[0].cash == 15_100)
    #expect(game.players[1].cash == 14_900)
}

@Test func cannotTradeGroupWithHouses() {
    var game = makeGame()
    game.cells[1].owner = 0
    game.cells[3].owner = 0
    game.cells[3].branches = 1
    let offer = TradeOffer(from: 0, to: 1, giveCells: [1], takeCash: 500)
    #expect(throws: GameError.hasBranchesInGroup) { try game.apply(.proposeTrade(offer), by: 0) }
}

// MARK: - Джекпот (опциональная клетка)

@Test func jackpotPaysFairOdds() throws {
    var cells = Board.standard.cells
    cells[20] = CellInfo(id: 20, name: "Джекпот", kind: .jackpot)
    var game = makeGame(board: Board(cells: cells))
    game.players[0].position = 10
    game.riggedRolls = [DiceRoll(4, 6)]
    try game.apply(.roll, by: 0)
    #expect(game.phase == .awaitingJackpot(cell: 20))
    #expect(throws: GameError.invalidJackpotNumbers) { try game.apply(.playJackpot(numbers: [1, 1]), by: 0) }
    try game.apply(.playJackpot(numbers: [1, 2, 3]), by: 0)
    // Ставка 1 000, при попадании выплата 1 000 × 6 / 3 = 2 000.
    #expect([14_000, 16_000].contains(game.players[0].cash))
    #expect(game.phase == .awaitingEndTurn)
}

// MARK: - Режим 2×2

@Test func teamTurnOrderAlternates() {
    let game = makeTeamGame()
    #expect(game.turnOrder == [0, 2, 1, 3])
    #expect(game.areTeammates(0, 1))
    #expect(!game.areTeammates(0, 2))
}

@Test func teammatesDoNotPayRent() throws {
    var game = makeTeamGame()
    game.cells[3].owner = 1
    game.riggedRolls = [DiceRoll(1, 2)]
    try game.apply(.roll, by: 0)
    #expect(game.players[0].cash == 15_000)
    #expect(game.players[1].cash == 15_000)
    #expect(game.phase == .awaitingEndTurn)
}

@Test func teammatesPayRentIfEnabled() throws {
    var game = makeTeamGame { $0.teammatesPayRent = true }
    game.cells[3].owner = 1
    game.riggedRolls = [DiceRoll(1, 2)]
    try game.apply(.roll, by: 0)
    #expect(game.players[0].cash == 15_000 - 40)
}

@Test func teamWinsWhenBothOpponentsAreBankrupt() throws {
    var game = makeTeamGame()
    game.players[3].isBankrupt = true
    #expect(game.finalResult() == nil)
    game.players[2].isBankrupt = true
    let result = game.finalResult()
    #expect(result != nil)
    #expect(result.flatMap { $0 }.map { game.players[$0].team } == 0)
}

@Test func teamRoundLimitComparesTeamWorth() {
    var game = makeTeamGame()
    // Самый богатый игрок — в команде 1, но команда 0 богаче в сумме: 41 000 против 40 000.
    game.players[2].cash = 25_000
    game.players[0].cash = 20_000
    game.players[1].cash = 21_000
    let leader = game.leaderByNetWorth()
    #expect(leader.map { game.players[$0].team } == 0)
}

// MARK: - «Перестановка»

@Test func reshuffleKeepsCornersAndCells() {
    let game = GameState(players: [PlayerSetup(name: "A"), PlayerSetup(name: "B")],
                         settings: .reshuffle, seed: 3)
    let original = Board.standard
    for corner in original.cornerCells {
        #expect(game.board.cells[corner].kind == original.cells[corner].kind)
    }
    #expect(game.board.cells.map(\.name).sorted() == original.cells.map(\.name).sorted())
    #expect(game.board != original)
}

@Test func reshuffleCardsStillLeadToTheSameStreet() {
    let game = GameState(players: [PlayerSetup(name: "A"), PlayerSetup(name: "B")],
                         settings: .reshuffle, seed: 3)
    for card in game.chanceCards {
        guard case .moveTo(let target) = card.effect,
              let original = ChanceDeck.standard.first(where: { $0.id == card.id }),
              case .moveTo(let originalTarget) = original.effect else { continue }
        #expect(game.board.cells[target].name == Board.standard.cells[originalTarget].name)
    }
}

@Test func speedDieNumberAddsSteps() throws {
    var game = makeGame { $0.speedDie = true }
    game.riggedRolls = [DiceRoll(1, 2)]
    game.riggedSpeedDie = [.number(3)]
    try game.apply(.roll, by: 0)
    #expect(game.players[0].position == 6)
}

@Test func speedDieBusLetsPlayerChoose() throws {
    var game = makeGame { $0.speedDie = true }
    game.riggedRolls = [DiceRoll(1, 2)]
    game.riggedSpeedDie = [.bus]
    try game.apply(.roll, by: 0)
    #expect(game.phase == .awaitingMoveChoice(options: [1, 2, 3]))
    #expect(throws: GameError.invalidMoveChoice) { try game.apply(.chooseMove(5), by: 0) }
    try game.apply(.chooseMove(1), by: 0)
    #expect(game.players[0].position == 1)
}

@Test func speedDieTripleTeleports() throws {
    var game = makeGame { $0.speedDie = true }
    game.riggedRolls = [DiceRoll(2, 2)]
    game.riggedSpeedDie = [.number(2)]
    try game.apply(.roll, by: 0)
    #expect(game.phase == .awaitingTeleport)
    try game.apply(.teleport(39), by: 0)
    #expect(game.players[0].position == 39)
    #expect(game.phase == .awaitingBuyDecision(cell: 39))
    // Трипл не считается дублем: ни дополнительного хода, ни счёта к тюрьме.
    #expect(!game.extraRollPending)
    #expect(game.doublesInRow == 0)
}

@Test func speedDieStartsAfterSeventhRound() throws {
    var game = makeGame { $0.speedDie = true; $0.speedDieStartRound = 8 }
    game.riggedRolls = [DiceRoll(1, 2)]
    game.riggedSpeedDie = [.number(3)]
    try game.apply(.roll, by: 0)
    #expect(game.lastSpeedDie == nil)
    #expect(game.players[0].position == 3)
    #expect(GameSettings.reshuffle.speedDieActive(round: 7) == false)
    #expect(GameSettings.reshuffle.speedDieActive(round: 8))
}

@Test func quickGamePresetMatchesMonopolyOne() {
    let settings = GameSettings.reshuffle
    #expect(settings.startingCash == 17_500)
    #expect(settings.mortgageTurnLimit == 7)
    #expect(settings.unevenBuilding == true)
    #expect(settings.speedDieFaces.filter { $0 == .bus }.count == 2)
    #expect(settings.speedDieFaces.filter { $0 == .bonus }.count == 1)
}

@Test func bonusSkipsMortgagedAndAllowsTeammateFields() throws {
    var game = makeTeamGame { $0.speedDie = true }
    // Все поля куплены: ближайшее (1) заложено у соперника, следующее (3) — у напарника.
    for cell in game.board.cells.indices where game.board.cells[cell].isPurchasable {
        game.cells[cell].owner = 2
    }
    game.cells[1].isMortgaged = true
    game.cells[3].owner = 1
    game.players[0].position = 0
    game.phase = .awaitingBonusMove
    try game.apply(.takeBonusMove, by: 0)
    #expect(game.players[0].position == 3)
}

@Test func unevenBuildingInQuickGame() throws {
    var game = makeGame { $0.unevenBuilding = true }
    game.cells[1].owner = 0
    game.cells[3].owner = 0
    game.players[0].cash = 100_000
    for _ in 0..<4 { try game.apply(.build(1), by: 0) }
    #expect(game.cells[1].branches == 4 && game.cells[3].branches == 0)
    // Большая звезда — только когда на соседнем поле тоже 4 филиала.
    #expect(throws: GameError.unevenBuild) { try game.apply(.build(1), by: 0) }
    for _ in 0..<4 { try game.apply(.build(3), by: 0) }
    try game.apply(.build(1), by: 0)
    #expect(game.cells[1].branches == 5)
}

@Test func speedDieBonusMovesToNextFreeStreet() throws {
    var game = makeGame { $0.speedDie = true }
    game.riggedRolls = [DiceRoll(1, 2)]
    game.riggedSpeedDie = [.bonus]
    try game.apply(.roll, by: 0)
    try game.apply(.buy, by: 0)
    #expect(game.phase == .awaitingBonusMove)
    try game.apply(.takeBonusMove, by: 0)
    #expect(game.players[0].position == 5)
    #expect(game.phase == .awaitingBuyDecision(cell: 5))
}

// MARK: - Конец партии

@Test func roundLimitEndsAfterFullRound() throws {
    var game = makeGame { $0.maxRounds = 1 }
    game.riggedRolls = [DiceRoll(4, 6), DiceRoll(4, 6)]
    try game.apply(.roll, by: 0)
    try game.apply(.endTurn, by: 0)
    #expect(!game.isOver)
    try game.apply(.roll, by: 1)
    let events = try game.apply(.endTurn, by: 1)
    #expect(events.contains(.gameOver(winner: nil, team: nil, byRoundLimit: true)))
}

// MARK: - Полные партии ботов во всех режимах

func runWithoutErrors(_ game: inout GameState) -> [String] {
    var errors: [String] = []
    BotRunner.runBots(&game) { action, error in errors.append("\(action): \(error)") }
    return errors
}

@Test(arguments: 1...20)
func classicBotGames(seed: Int) {
    var game = botGame(seed: UInt64(seed))
    let errors = runWithoutErrors(&game)
    #expect(errors.isEmpty, "\(errors.prefix(3))")
    #expect(game.isOver)
}

@Test(arguments: 1...20)
func reshuffleBotGames(seed: Int) {
    var game = botGame(seed: UInt64(seed), settings: .reshuffle)
    let errors = runWithoutErrors(&game)
    #expect(errors.isEmpty, "\(errors.prefix(3))")
    #expect(game.isOver)
}

@Test(arguments: 1...20)
func teamBotGames(seed: Int) {
    var game = botGame(seed: UInt64(seed), teams: true)
    let errors = runWithoutErrors(&game)
    #expect(errors.isEmpty, "\(errors.prefix(3))")
    #expect(game.isOver)
}

// MARK: - Сеть

@Test func redactedCopyHidesFuture() throws {
    var game = makeGame()
    let copy = game.redactedForClients()
    #expect(copy.chanceDeck.drawPile == copy.chanceDeck.drawPile.sorted())
    #expect(copy.rng != game.rng)
    #expect(copy.players == game.players)
    #expect(copy.cells == game.cells)
    // Два броска на исходной партии и на копии дают разные кубики — будущее не утекло.
    var original = game
    var leaked = copy
    var differs = false
    for _ in 0..<5 where !differs {
        differs = original.rollDice() != leaked.rollDice()
    }
    #expect(differs)
    game.setBot(1, true)
    #expect(game.players[1].isBot)
}

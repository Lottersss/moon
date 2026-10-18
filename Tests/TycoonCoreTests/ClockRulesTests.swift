import Foundation
import Testing
@testable import TycoonCore

// Правила Monopoly One, которые зависят от времени партии, и лимит сделок.

@Test func presetsFollowMonopolyOneClock() {
    #expect(GameSettings.monopolyOne.noStartBonusAfterMinutes == 45)
    #expect(GameSettings.monopolyOne.rentTaxAfterMinutes == 60)
    // Быстрая игра: на 15 минут раньше.
    #expect(GameSettings.reshuffle.noStartBonusAfterMinutes == 30)
    #expect(GameSettings.reshuffle.rentTaxAfterMinutes == 40)
}

@Test func startBonusStopsAfterFortyFiveMinutes() throws {
    func cashAfterPassingStart(atSeconds seconds: Int) throws -> Int {
        var game = makeGame()
        game.players[0].position = 38
        game.advanceClock(to: seconds)
        game.riggedRolls = [DiceRoll(1, 2)]
        try game.apply(.roll, by: 0)
        return game.players[0].cash
    }
    #expect(try cashAfterPassingStart(atSeconds: 0) == 17_000)
    #expect(try cashAfterPassingStart(atSeconds: 45 * 60 - 1) == 17_000)
    #expect(try cashAfterPassingStart(atSeconds: 45 * 60) == 15_000)
}

@Test func quickGameStartBonusStopsEarlier() throws {
    var game = makeGame { $0 = .reshuffle; $0.shuffleBoard = false; $0.speedDie = false; $0.randomizeTurnOrder = false }
    let before = game.players[0].cash
    game.players[0].position = 38
    game.advanceClock(to: 30 * 60)
    game.riggedRolls = [DiceRoll(1, 2)]
    try game.apply(.roll, by: 0)
    #expect(game.players[0].cash == before)
}

@Test func rentTaxStartsAfterAnHourAndGrows() throws {
    // Игрок 0 попадает на «Кремний» (350k), которым владеет игрок 1.
    func ownerIncome(atSeconds seconds: Int) throws -> Int {
        var game = makeGame()
        game.cells[37].owner = 1
        game.players[0].position = 34
        game.advanceClock(to: seconds)
        game.riggedRolls = [DiceRoll(1, 2)]
        try game.apply(.roll, by: 0)
        #expect(game.players[0].cash == 15_000 - 350)
        return game.players[1].cash - 15_000
    }
    #expect(try ownerIncome(atSeconds: 59 * 60) == 350)
    #expect(try ownerIncome(atSeconds: 60 * 60) == 175)   // 50%
    #expect(try ownerIncome(atSeconds: 80 * 60) == 105)   // 70%
    #expect(try ownerIncome(atSeconds: 300 * 60) == 3)    // не больше 99%
}

@Test func rentTaxIsReportedInEvents() throws {
    var game = makeGame()
    game.cells[37].owner = 1
    game.players[0].position = 34
    game.advanceClock(to: 60 * 60)
    game.riggedRolls = [DiceRoll(1, 2)]
    let events = try game.apply(.roll, by: 0)
    #expect(events.contains(.rentTax(owner: 1, withheld: 175, percent: 50)))
}

@Test func quickGameRentTaxStartsAfterFortyMinutes() {
    var game = makeGame { $0 = .reshuffle; $0.shuffleBoard = false; $0.randomizeTurnOrder = false }
    game.advanceClock(to: 40 * 60 - 1)
    #expect(game.rentTaxPercent == 0)
    game.advanceClock(to: 40 * 60)
    #expect(game.rentTaxPercent == 50)
}

@Test func taxesDoNotApplyToTaxCellsOrCards() throws {
    // Налог на аренду касается только ренты: обычный налог «Подоходный» платится целиком.
    var game = makeGame()
    game.players[0].position = 1
    game.advanceClock(to: 120 * 60)
    game.riggedRolls = [DiceRoll(1, 2)]   // 1 + 3 = клетка 4, «Подоходный налог» 2 000k
    try game.apply(.roll, by: 0)
    #expect(game.players[0].cash == 15_000 - 2_000)
}

@Test func clockOnlyMovesForward() {
    var game = makeGame()
    game.advanceClock(to: 100)
    game.advanceClock(to: 50)
    #expect(game.clockSeconds == 100)
}

@Test func clockSurvivesSnapshotAndOldSavesStillLoad() throws {
    var game = makeGame()
    game.advanceClock(to: 1_234)
    let data = try JSONEncoder().encode(game.redactedForClients())
    #expect(try JSONDecoder().decode(GameState.self, from: data).clockSeconds == 1_234)

    // Сохранение без новых полей (до этой версии) читается, часы и правила выключены.
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["clockSeconds"] = nil
    var settings = try #require(object["settings"] as? [String: Any])
    settings["noStartBonusAfterMinutes"] = nil
    settings["rentTaxAfterMinutes"] = nil
    object["settings"] = settings
    let old = try JSONSerialization.data(withJSONObject: object)
    let restored = try JSONDecoder().decode(GameState.self, from: old)
    #expect(restored.clockSeconds == nil)
    #expect(restored.settings.rentTaxAfterMinutes == nil)
    #expect(restored.rentTaxPercent == 0)
    #expect(restored.startBonusPaid)
}

// MARK: - Лимит договоров: разница не больше 50%

@Test func tradeValuesMayDifferByHalfAtMost() throws {
    // «Нейрон» стоит 4 000k.
    func propose(cash: Int) throws {
        var game = makeGame()
        game.cells[39].owner = 0
        let offer = TradeOffer(from: 0, to: 1, giveCells: [39], takeCash: cash)
        try game.apply(.proposeTrade(offer), by: 0)
    }
    try propose(cash: 4_000)
    try propose(cash: 2_700)   // 4 000 ≤ 2 700 × 1,5
    #expect(throws: GameError.unfairTrade) { try propose(cash: 2_600) }
    #expect(throws: GameError.unfairTrade) { try propose(cash: 0) }   // «подарок» запрещён
    // В обратную сторону то же самое: просить больше, чем отдаёшь, нельзя.
    var game = makeGame()
    game.cells[39].owner = 1
    let greedy = TradeOffer(from: 0, to: 1, giveCash: 2_000, takeCells: [39])
    #expect(throws: GameError.unfairTrade) { try game.apply(.proposeTrade(greedy), by: 0) }
}

@Test func botsOfferFairTradesUnderTheLimit() throws {
    // Бот не предлагает договор, который движок отклонит.
    var game = makeGame()
    game.cells[37].owner = 1
    game.cells[39].owner = 0
    let bot = SimpleBot()
    if let offer = bot.tradeIdea(game.publicView, 0) {
        #expect(!game.isUnfair(offer, ratio: 1.5))
        try game.apply(.proposeTrade(offer), by: 0)
    }
}

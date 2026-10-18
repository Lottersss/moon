import TycoonCore

/// Превращает события движка в строки журнала партии.
enum EventText {
    static func text(_ event: GameEvent, in state: GameState) -> String? {
        func name(_ id: PlayerID) -> String { state.players[id].name }
        func cell(_ id: CellID) -> String { state.board.cells[id].name }
        func money(_ value: Int) -> String { Format.money(value) }
        func creditor(_ creditor: Creditor) -> String {
            switch creditor {
            case .bank: "банку"
            case .player(let id): name(id)
            }
        }

        switch event {
        case .turnStarted(let player, let round):
            return "— Круг \(round), ходит \(name(player)) —"
        case .diceRolled(let player, let roll):
            return "\(name(player)) бросает \(roll.d1) и \(roll.d2)" + (roll.isDouble ? " — дубль!" : "")
        case .speedDieRolled(let player, let face):
            switch face {
            case .number(let n): return "\(name(player)): быстрый кубик +\(n)"
            case .bus: return "\(name(player)): быстрый кубик — автобус"
            case .bonus: return "\(name(player)): быстрый кубик — бонус, в конце хода переход к свободному полю"
            }
        case .moved:
            return nil
        case .startBonus(let player, let amount):
            return "\(name(player)) проходит Старт: +\(money(amount))"
        case .bought(let player, let id, let price):
            return "\(name(player)) покупает «\(cell(id))» за \(money(price))"
        case .paid(let from, let to, let amount, let reason):
            switch reason {
            case .rent(let id): return "\(name(from)) платит \(creditor(to)) ренту \(money(amount)) за «\(cell(id))»"
            case .tax: return "\(name(from)) платит налог \(money(amount))"
            case .jailFine: return "\(name(from)) платит штраф \(money(amount)) и выходит из тюрьмы"
            case .card: return "\(name(from)) платит \(creditor(to)) \(money(amount))"
            case .jackpotBet: return "\(name(from)) ставит \(money(amount)) в джекпот"
            }
        case .rentTax(let owner, let withheld, let percent):
            return "Налог на аренду \(percent)%: \(name(owner)) недополучает \(money(withheld))"
        case .received(let player, let amount):
            return "\(name(player)) получает \(money(amount))"
        case .cardDrawn(let player, let deck, let card):
            return "\(name(player)) · \(deck.title): «\(card.text)»"
        case .sentToJail(let player):
            return "\(name(player)) отправляется в тюрьму"
        case .leftJail(let player):
            return "\(name(player)) выходит из тюрьмы"
        case .auctionStarted(let id):
            if case .auction(let auction) = state.phase, auction.cell == id {
                return "Аукцион: «\(cell(id))», стартовая цена \(money(auction.startPrice))"
            }
            return "Аукцион: «\(cell(id))»"
        case .bidPlaced, .bidPassed:
            // Каждый шаг торгов не пишем: текущая ставка видна в центре доски, итог — в журнале.
            return nil
        case .auctionWon(let player, let id, let price):
            return "\(name(player)) выигрывает аукцион: «\(cell(id))» за \(money(price))"
        case .auctionNoBids(let id):
            return "Все отказались от аукциона — «\(cell(id))» остаётся свободной"
        case .jackpotPlayed(let player, let numbers, let rolled, let payout):
            let picked = numbers.map(String.init).joined(separator: ", ")
            return payout > 0
                ? "\(name(player)) угадывает \(rolled) (ставка на \(picked)): +\(money(payout))"
                : "\(name(player)) ставил на \(picked), выпало \(rolled)"
        case .built(let player, let id, let level):
            return "\(name(player)) строит " + (level == Board.maxBranches ? "отель" : "дом №\(level)") + " на «\(cell(id))»"
        case .branchSold(let player, let id, _):
            return "\(name(player)) продаёт постройку на «\(cell(id))»"
        case .mortgaged(let player, let id):
            return "\(name(player)) закладывает «\(cell(id))»"
        case .unmortgaged(let player, let id):
            return "\(name(player)) выкупает «\(cell(id))» из залога"
        case .mortgageExpired(let player, let id):
            return "У \(name(player)) истёк срок залога: «\(cell(id))» уходит банку"
        case .tradeProposed(let offer, let flagged):
            return "\(name(offer.from)) предлагает договор игроку \(name(offer.to))" + (flagged ? " ⚠︎ неравный" : "")
        case .tradeAccepted(let offer):
            return "\(name(offer.to)) принимает договор от \(name(offer.from))"
        case .tradeRejected(let offer):
            return "\(name(offer.to)) отклоняет договор"
        case .tradeCancelled(let offer):
            return "\(name(offer.from)) отзывает договор"
        case .debtStarted(let player, let amount):
            return "\(name(player)) должен \(money(amount)) — не хватает денег"
        case .bankrupt(let player, let heir):
            return heir.map { "\(name(player)) банкрот, имущество переходит к \(name($0))" } ?? "\(name(player)) банкрот"
        case .gameOver(let winner, let team, let byLimit):
            let reason = byLimit ? " (лимит кругов)" : ""
            if let team, let teamName = Format.teamName(team) { return "🏆 Победила \(teamName)\(reason)" }
            return winner.map { "🏆 Победитель: \(name($0))\(reason)" } ?? "Ничья\(reason)"
        }
    }

    /// Короткая подсказка «что сейчас происходит» для центра доски.
    static func phaseHint(_ state: GameState) -> String {
        func name(_ id: PlayerID) -> String { state.players[id].name }
        if let trade = state.pendingTrade { return "\(name(trade.to)) решает по договору" }
        switch state.phase {
        case .awaitingRoll:
            return state.players[state.currentPlayerID].inJail ? "В тюрьме: дубль, штраф или карточка" : "Бросьте кубики"
        case .awaitingMoveChoice: return "Автобус: выберите ход"
        case .awaitingTeleport: return "Трипл! Нажмите на любую клетку"
        case .awaitingBonusMove: return "Бонус: к ближайшему свободному полю"
        case .awaitingBuyDecision(let cell): return "Купить «\(state.board.cells[cell].name)»?"
        case .auction(let auction):
            if let leader = auction.highestBidder {
                return "Аукцион: \(Format.money(auction.highestBid)) · \(name(leader))"
            }
            return "Аукцион: старт \(Format.money(auction.startPrice))"
        case .awaitingJackpot: return "Джекпот: сыграть?"
        case .awaitingEndTurn: return "Стройте, торгуйтесь или завершите ход"
        case .debt(let debt): return "\(name(debt.debtor)) должен \(Format.money(debt.total))"
        case .gameOver: return "Игра окончена"
        }
    }
}

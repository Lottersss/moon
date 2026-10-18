// Игровой движок: единственная точка изменения состояния.
// (состояние, действие) → новое состояние + список событий для UI.
// Если действие недопустимо, бросается GameError и состояние не меняется.

extension GameState {

    @discardableResult
    public mutating func apply(_ action: Action, by actor: PlayerID) throws -> [GameEvent] {
        var next = self
        var events: [GameEvent] = []
        try next.dispatch(action, by: actor, events: &events)
        self = next
        return events
    }

    // MARK: - Маршрутизация действий по фазе

    mutating func dispatch(_ action: Action, by actor: PlayerID, events ev: inout [GameEvent]) throws {
        if isOver { throw GameError.gameOver }
        guard players.indices.contains(actor), !players[actor].isBankrupt else { throw GameError.notYourTurn }

        if let trade = pendingTrade {
            switch action {
            case .acceptTrade:
                guard actor == trade.to else { throw GameError.notYourTurn }
                try validateTrade(trade)
                executeTrade(trade)
                pendingTrade = nil
                ev.append(.tradeAccepted(offer: trade))
            case .rejectTrade:
                guard actor == trade.to else { throw GameError.notYourTurn }
                pendingTrade = nil
                ev.append(.tradeRejected(offer: trade))
            case .cancelTrade:
                guard actor == trade.from else { throw GameError.notYourTurn }
                pendingTrade = nil
                ev.append(.tradeCancelled(offer: trade))
            default:
                throw GameError.tradePending
            }
            return
        }

        switch phase {
        case .gameOver:
            throw GameError.gameOver

        case .awaitingRoll:
            guard actor == currentPlayerID else { throw GameError.notYourTurn }
            switch action {
            case .roll: rollTurn(&ev)
            case .payJailFine: try payJailFine(&ev)
            case .useJailCard: try useJailCard(&ev)
            case .proposeTrade(let offer): try proposeTrade(offer, by: actor, &ev)
            case .build, .sellBranch, .mortgage, .unmortgage:
                try manage(action, by: actor, raiseOnly: false, &ev)
            default: throw GameError.invalidAction
            }

        case .awaitingMoveChoice(let options):
            guard actor == currentPlayerID else { throw GameError.notYourTurn }
            guard case .chooseMove(let steps) = action else { throw GameError.invalidAction }
            guard options.contains(steps) else { throw GameError.invalidMoveChoice }
            move(actor, by: steps, &ev)

        case .awaitingTeleport:
            guard actor == currentPlayerID else { throw GameError.notYourTurn }
            guard case .teleport(let target) = action else { throw GameError.invalidAction }
            guard board.cells.indices.contains(target), target != players[actor].position else {
                throw GameError.invalidTeleportTarget
            }
            moveForward(actor, to: target, &ev)

        case .awaitingBonusMove:
            guard actor == currentPlayerID else { throw GameError.notYourTurn }
            guard case .takeBonusMove = action else { throw GameError.invalidAction }
            takeBonusMove(&ev)

        case .awaitingBuyDecision(let cell):
            guard actor == currentPlayerID else { throw GameError.notYourTurn }
            switch action {
            case .buy: try buy(cell, &ev)
            case .declineBuy: startAuction(cell, &ev)
            // Можно продать дома или заложить, чтобы хватило на покупку.
            case .sellBranch, .mortgage: try manage(action, by: actor, raiseOnly: true, &ev)
            default: throw GameError.invalidAction
            }

        case .auction(let auction):
            guard actor == auction.currentBidder else { throw GameError.notYourTurn }
            switch action {
            case .bid(let amount): try placeBid(amount, by: actor, in: auction, &ev)
            case .passBid: passBid(in: auction, &ev)
            default: throw GameError.invalidAction
            }

        case .awaitingJackpot:
            guard actor == currentPlayerID else { throw GameError.notYourTurn }
            switch action {
            case .playJackpot(let numbers): try playJackpot(numbers, &ev)
            case .skipJackpot: finishLanding()
            default: throw GameError.invalidAction
            }

        case .awaitingEndTurn:
            guard actor == currentPlayerID else { throw GameError.notYourTurn }
            switch action {
            case .endTurn: advanceTurn(&ev)
            case .proposeTrade(let offer): try proposeTrade(offer, by: actor, &ev)
            case .build, .sellBranch, .mortgage, .unmortgage:
                try manage(action, by: actor, raiseOnly: false, &ev)
            default: throw GameError.invalidAction
            }

        case .debt(let debt):
            guard actor == debt.debtor else { throw GameError.notYourTurn }
            switch action {
            case .payDebt: try payDebt(debt, &ev)
            case .declareBankruptcy: declareBankruptcy(debt, &ev)
            case .sellBranch, .mortgage: try manage(action, by: actor, raiseOnly: true, &ev)
            default: throw GameError.invalidAction
            }
        }
    }

    // MARK: - Бросок и движение

    mutating func rollTurn(_ ev: inout [GameEvent]) {
        let id = currentPlayerID
        let roll = rollDice()
        lastRoll = roll
        lastSpeedDie = nil
        ev.append(.diceRolled(player: id, roll: roll))

        if players[id].inJail {
            extraRollPending = false
            if roll.isDouble {
                releaseFromJail(id, &ev)
                move(id, by: roll.total, &ev)
            } else {
                players[id].jailTurns += 1
                if players[id].jailTurns >= settings.maxJailRolls {
                    // Попытки кончились: штраф обязателен, затем ход на выпавшее число.
                    releaseFromJail(id, &ev)
                    charge(id, [Payment(to: .bank, amount: settings.jailFine)],
                           reason: .jailFine, then: .moveBy(roll.total), &ev)
                } else {
                    phase = .awaitingEndTurn
                }
            }
            return
        }

        // Третий кубик бросается вместе с двумя обычными (из тюрьмы — без него),
        // в быстрой игре — только после седьмого раунда.
        var speedFace: SpeedDieFace?
        if settings.speedDieActive(round: round) {
            let face = rollSpeedDie()
            speedFace = face
            lastSpeedDie = face
            ev.append(.speedDieRolled(player: id, face: face))
        }

        // Трипл (1:1:1, 2:2:2, 3:3:3) — переход на любое поле. Он не считается дублем:
        // не даёт дополнительный ход и не ведёт в тюрьму за три дубля подряд.
        if case .number(let extra)? = speedFace, roll.isDouble, extra == roll.d1 {
            extraRollPending = false
            phase = .awaitingTeleport
            return
        }

        if roll.isDouble {
            doublesInRow += 1
            if doublesInRow >= 3 {
                sendToJail(id, &ev)
                phase = .awaitingEndTurn
                return
            }
            extraRollPending = true
        } else {
            extraRollPending = false
        }

        switch speedFace {
        case nil:
            move(id, by: roll.total, &ev)
        case .number(let extra)?:
            move(id, by: roll.total + extra, &ev)
        case .bus?:
            let options = Array(Set([roll.d1, roll.d2, roll.total])).sorted()
            phase = .awaitingMoveChoice(options: options)
        case .bonus?:
            bonusMovePending = true
            move(id, by: roll.total, &ev)
        }
    }

    mutating func move(_ id: PlayerID, by steps: Int, rent modifier: RentModifier = .normal,
                       _ ev: inout [GameEvent]) {
        let count = board.count
        let from = players[id].position
        let raw = from + steps
        let to = ((raw % count) + count) % count
        let passedStart = steps > 0 && raw >= count
        players[id].position = to
        ev.append(.moved(player: id, from: from, to: to, passedStart: passedStart))
        if passedStart && startBonusPaid {
            players[id].cash += settings.passStartBonus
            ev.append(.startBonus(player: id, amount: settings.passStartBonus))
        }
        land(id, on: to, rent: modifier, &ev)
    }

    mutating func moveForward(_ id: PlayerID, to target: CellID, rent modifier: RentModifier = .normal,
                              _ ev: inout [GameEvent]) {
        let count = board.count
        let steps = ((target - players[id].position) % count + count) % count
        move(id, by: steps, rent: modifier, &ev)
    }

    mutating func land(_ id: PlayerID, on cell: CellID, rent modifier: RentModifier, _ ev: inout [GameEvent]) {
        switch board.cells[cell].kind {
        case .start, .jail, .parking:
            finishLanding()
        case .jackpot:
            if settings.jackpotEnabled && players[id].cash >= settings.jackpotBet {
                phase = .awaitingJackpot(cell: cell)
            } else {
                finishLanding()
            }
        case .goToJail:
            sendToJail(id, &ev)
            finishLanding()
        case .tax(let amount):
            charge(id, [Payment(to: .bank, amount: amount)], reason: .tax(cell), then: .finishLanding, &ev)
        case .chance:
            resolveCard(from: .chance, for: id, &ev)
        case .communityChest:
            resolveCard(from: .communityChest, for: id, &ev)
        case .company, .transport, .utility:
            guard let owner = cells[cell].owner else {
                phase = .awaitingBuyDecision(cell: cell)
                return
            }
            let amount = rent(for: cell, payer: id, modifier: modifier)
            guard amount > 0 else {
                finishLanding()
                return
            }
            charge(id, [Payment(to: .player(owner), amount: amount)], reason: .rent(cell),
                   then: .finishLanding, &ev)
        }
    }

    /// Ход завершён: бонус-ход (если выпал), потом повторный бросок после дубля или конец хода.
    mutating func finishLanding() {
        if bonusMovePending {
            bonusMovePending = false
            phase = .awaitingBonusMove
            return
        }
        phase = extraRollPending ? .awaitingRoll : .awaitingEndTurn
    }

    /// Бонус «М1»: в конце хода — к ближайшему свободному полю; если свободных нет —
    /// к ближайшему незаложенному полю другого игрока (соперника или напарника в 2×2);
    /// если нет и таких — ничего не происходит.
    mutating func takeBonusMove(_ ev: inout [GameEvent]) {
        let id = currentPlayerID
        let position = players[id].position
        let target = nearest(from: position) { cell in
            board.cells[cell].isPurchasable && cells[cell].owner == nil
        } ?? nearest(from: position) { cell in
            guard let owner = cells[cell].owner else { return false }
            return owner != id && !cells[cell].isMortgaged
        }
        guard let target else {
            finishLanding()
            return
        }
        moveForward(id, to: target, &ev)
    }

    func nearest(from position: CellID, where matches: (CellID) -> Bool) -> CellID? {
        for step in 1..<board.count {
            let cell = (position + step) % board.count
            if matches(cell) { return cell }
        }
        return nil
    }

    // MARK: - Тюрьма

    mutating func sendToJail(_ id: PlayerID, _ ev: inout [GameEvent]) {
        players[id].position = board.jailCell
        players[id].inJail = true
        players[id].jailTurns = 0
        doublesInRow = 0
        extraRollPending = false
        bonusMovePending = false
        ev.append(.sentToJail(player: id))
    }

    mutating func releaseFromJail(_ id: PlayerID, _ ev: inout [GameEvent]) {
        players[id].inJail = false
        players[id].jailTurns = 0
        ev.append(.leftJail(player: id))
    }

    mutating func payJailFine(_ ev: inout [GameEvent]) throws {
        let id = currentPlayerID
        guard players[id].inJail else { throw GameError.notInJail }
        guard players[id].cash >= settings.jailFine else { throw GameError.notEnoughCash }
        players[id].cash -= settings.jailFine
        ev.append(.paid(from: id, to: .bank, amount: settings.jailFine, reason: .jailFine))
        releaseFromJail(id, &ev)
        // Фаза остаётся awaitingRoll: игрок бросает кубики как обычно.
    }

    mutating func useJailCard(_ ev: inout [GameEvent]) throws {
        let id = currentPlayerID
        guard players[id].inJail else { throw GameError.notInJail }
        guard let deck = players[id].jailCardDecks.popLast() else { throw GameError.noJailCard }
        returnJailCard(to: deck)
        releaseFromJail(id, &ev)
    }

    mutating func returnJailCard(to kind: DeckKind) {
        guard let cardID = cards(kind).first(where: { $0.effect == .getOutOfJail })?.id else { return }
        switch kind {
        case .chance: chanceDeck.discard.append(cardID)
        case .communityChest: chestDeck.discard.append(cardID)
        }
    }

    // MARK: - «Шанс» и «Общественная казна»

    mutating func drawCard(from kind: DeckKind) -> Card? {
        var deck: DeckState
        switch kind {
        case .chance: deck = chanceDeck
        case .communityChest: deck = chestDeck
        }

        if deck.drawPile.isEmpty {
            let reshuffled = shuffledWithRNG(deck.discard)
            deck.drawPile = reshuffled
            deck.discard.removeAll()
        }
        var card: Card?
        if !deck.drawPile.isEmpty {
            let drawn = cards(kind)[deck.drawPile.removeFirst()]
            // Карточка освобождения остаётся у игрока и вернётся в колоду после использования.
            if drawn.effect != .getOutOfJail { deck.discard.append(drawn.id) }
            card = drawn
        }

        switch kind {
        case .chance: chanceDeck = deck
        case .communityChest: chestDeck = deck
        }
        return card
    }

    mutating func resolveCard(from kind: DeckKind, for id: PlayerID, _ ev: inout [GameEvent]) {
        guard let card = drawCard(from: kind) else {
            finishLanding()
            return
        }
        ev.append(.cardDrawn(player: id, deck: kind, card: card))
        let reason = PaymentReason.card(deck: kind, id: card.id)
        let position = players[id].position

        switch card.effect {
        case .moveTo(let target):
            moveForward(id, to: target, &ev)
        case .moveBy(let steps):
            move(id, by: steps, &ev)
        case .moveToNearestTransport:
            let target = nearest(from: position) { board.cells[$0].kind.isTransport } ?? position
            moveForward(id, to: target, rent: .doubleTransport, &ev)
        case .moveToNearestUtility:
            let target = nearest(from: position) { board.cells[$0].kind.isUtility } ?? position
            moveForward(id, to: target, rent: .maxUtility, &ev)
        case .receive(let amount):
            players[id].cash += amount
            ev.append(.received(player: id, amount: amount))
            finishLanding()
        case .pay(let amount):
            charge(id, [Payment(to: .bank, amount: amount)], reason: reason, then: .finishLanding, &ev)
        case .payEachPlayer(let amount):
            let payments = activePlayerIDs
                .filter { $0 != id }
                .map { Payment(to: .player($0), amount: amount) }
            charge(id, payments, reason: reason, then: .finishLanding, &ev)
        case .repairs(let perBranch, let perHotel):
            var total = 0
            for cell in cellsOwned(by: id) {
                let level = cells[cell].branches
                total += level == Board.maxBranches ? perHotel : level * perBranch
            }
            charge(id, [Payment(to: .bank, amount: total)], reason: reason, then: .finishLanding, &ev)
        case .goToJail:
            sendToJail(id, &ev)
            finishLanding()
        case .getOutOfJail:
            players[id].jailCardDecks.append(kind)
            finishLanding()
        }
    }

    // MARK: - Платежи и долги

    /// Списывает деньги. Если их не хватает — игрок попадает в фазу долга.
    mutating func charge(_ id: PlayerID, _ payments: [Payment], reason: PaymentReason,
                         then continuation: Continuation, _ ev: inout [GameEvent]) {
        let payments = payments.filter { $0.amount > 0 }
        let total = payments.reduce(0) { $0 + $1.amount }
        if players[id].cash >= total {
            settle(id, payments, reason: reason, &ev)
            proceed(after: continuation, for: id, &ev)
        } else {
            phase = .debt(Debt(debtor: id, payments: payments, reason: reason, then: continuation))
            ev.append(.debtStarted(player: id, amount: total))
        }
    }

    mutating func settle(_ id: PlayerID, _ payments: [Payment], reason: PaymentReason, _ ev: inout [GameEvent]) {
        for payment in payments {
            players[id].cash -= payment.amount
            ev.append(.paid(from: id, to: payment.to, amount: payment.amount, reason: reason))
            guard case .player(let creditor) = payment.to else { continue }
            // Налог на аренду: часть выплаты владельцу уходит банку (при банкротстве он не применяется).
            var income = payment.amount
            if case .rent = reason { income = rentIncome(afterTax: payment.amount) }
            players[creditor].cash += income
            if income < payment.amount {
                ev.append(.rentTax(owner: creditor, withheld: payment.amount - income, percent: rentTaxPercent))
            }
        }
    }

    mutating func proceed(after continuation: Continuation, for id: PlayerID, _ ev: inout [GameEvent]) {
        switch continuation {
        case .finishLanding: finishLanding()
        case .moveBy(let steps): move(id, by: steps, &ev)
        }
    }

    mutating func payDebt(_ debt: Debt, _ ev: inout [GameEvent]) throws {
        guard players[debt.debtor].cash >= debt.total else { throw GameError.notEnoughCash }
        settle(debt.debtor, debt.payments, reason: debt.reason, &ev)
        proceed(after: debt.then, for: debt.debtor, &ev)
    }

    mutating func declareBankruptcy(_ debt: Debt, _ ev: inout [GameEvent]) {
        let id = debt.debtor

        // 1. Постройки продаются банку.
        for cell in cellsOwned(by: id) where cells[cell].branches > 0 {
            players[id].cash += cells[cell].branches * branchRefund(cell)
            cells[cell].branches = 0
        }

        // 2. Кредиторы получают столько, сколько есть.
        var remaining = players[id].cash
        for payment in debt.payments {
            let paid = min(remaining, payment.amount)
            remaining -= paid
            if case .player(let creditor) = payment.to { players[creditor].cash += paid }
        }

        // 3. Если кредитор один и это игрок — он наследует улицы (вместе с залогами).
        //    Иначе улицы возвращаются банку и снова свободны.
        var heir: PlayerID?
        if debt.payments.count == 1, case .player(let creditor) = debt.payments[0].to {
            heir = creditor
        }
        for cell in cellsOwned(by: id) {
            if let heir {
                cells[cell].owner = heir
            } else {
                cells[cell] = Ownership()
            }
        }
        if let heir {
            players[heir].cash += remaining
            players[heir].jailCardDecks += players[id].jailCardDecks
        } else {
            for deck in players[id].jailCardDecks { returnJailCard(to: deck) }
        }

        players[id].cash = 0
        players[id].jailCardDecks = []
        players[id].inJail = false
        players[id].isBankrupt = true
        ev.append(.bankrupt(player: id, heir: heir))

        if let result = finalResult() {
            endGame(winner: result, byRoundLimit: false, &ev)
            return
        }
        advanceTurn(&ev)
    }

    // MARK: - Покупка и аукцион

    mutating func buy(_ cell: CellID, _ ev: inout [GameEvent]) throws {
        let id = currentPlayerID
        guard let price = board.cells[cell].price else { throw GameError.notPurchasable }
        guard players[id].cash >= price else { throw GameError.notEnoughCash }
        players[id].cash -= price
        cells[cell].owner = id
        ev.append(.bought(player: id, cell: cell, price: price))
        finishLanding()
    }

    /// Если игрок отказался покупать, улица уходит с торгов.
    /// Торгуются все, кто в игре, начиная со следующего игрока; отказавшийся — последним.
    mutating func startAuction(_ cell: CellID, _ ev: inout [GameEvent]) {
        var bidders: [PlayerID] = []
        for offset in 1...turnOrder.count {
            let player = turnOrder[(turnIndex + offset) % turnOrder.count]
            if !players[player].isBankrupt { bidders.append(player) }
        }
        let start = settings.auctionStartsAtPrice ? (board.cells[cell].price ?? 0) : settings.auctionStep
        phase = .auction(Auction(cell: cell, highestBid: 0, highestBidder: nil,
                                 bidders: bidders, turnIndex: 0, startPrice: start))
        ev.append(.auctionStarted(cell: cell))
    }

    mutating func placeBid(_ amount: Int, by actor: PlayerID, in auction: Auction, _ ev: inout [GameEvent]) throws {
        var auction = auction
        guard amount >= auction.minimumBid(step: settings.auctionStep) else { throw GameError.bidTooLow }
        guard amount <= players[actor].cash else { throw GameError.notEnoughCash }
        auction.highestBid = amount
        auction.highestBidder = actor
        auction.turnIndex = (auction.turnIndex + 1) % auction.bidders.count
        ev.append(.bidPlaced(player: actor, amount: amount))
        resolveAuction(auction, &ev)
    }

    mutating func passBid(in auction: Auction, _ ev: inout [GameEvent]) {
        var auction = auction
        let player = auction.bidders.remove(at: auction.turnIndex)
        if auction.turnIndex >= auction.bidders.count { auction.turnIndex = 0 }
        ev.append(.bidPassed(player: player))
        resolveAuction(auction, &ev)
    }

    mutating func resolveAuction(_ auction: Auction, _ ev: inout [GameEvent]) {
        if let winner = auction.highestBidder,
           auction.bidders == [winner] || !auction.bidders.contains(winner) {
            players[winner].cash -= auction.highestBid
            cells[auction.cell].owner = winner
            ev.append(.auctionWon(player: winner, cell: auction.cell, price: auction.highestBid))
            finishLanding()
        } else if auction.bidders.isEmpty {
            ev.append(.auctionNoBids(cell: auction.cell))
            finishLanding()
        } else {
            phase = .auction(auction)
        }
    }

    // MARK: - Джекпот

    mutating func playJackpot(_ numbers: [Int], _ ev: inout [GameEvent]) throws {
        let id = currentPlayerID
        let unique = Set(numbers)
        guard (1...3).contains(numbers.count), unique.count == numbers.count,
              unique.allSatisfy({ (1...6).contains($0) }) else { throw GameError.invalidJackpotNumbers }
        let bet = settings.jackpotBet
        guard players[id].cash >= bet else { throw GameError.notEnoughCash }

        players[id].cash -= bet
        ev.append(.paid(from: id, to: .bank, amount: bet, reason: .jackpotBet))
        let rolled = randomInt(in: 1...6)
        let payout = unique.contains(rolled) ? bet * 6 / numbers.count : 0
        players[id].cash += payout
        ev.append(.jackpotPlayed(player: id, numbers: numbers.sorted(), rolled: rolled, payout: payout))
        finishLanding()
    }

    // MARK: - Дома и залог

    mutating func manage(_ action: Action, by id: PlayerID, raiseOnly: Bool, _ ev: inout [GameEvent]) throws {
        switch action {
        case .build(let cell):
            guard !raiseOnly else { throw GameError.invalidAction }
            try build(cell, by: id, &ev)
        case .unmortgage(let cell):
            guard !raiseOnly else { throw GameError.invalidAction }
            try unmortgage(cell, by: id, &ev)
        case .sellBranch(let cell):
            try sellBranch(cell, by: id, &ev)
        case .mortgage(let cell):
            try mortgage(cell, by: id, &ev)
        default:
            throw GameError.invalidAction
        }
    }

    mutating func build(_ cell: CellID, by id: PlayerID, _ ev: inout [GameEvent]) throws {
        guard board.cells.indices.contains(cell),
              case .company(let group, _, _, let cost) = board.cells[cell].kind else { throw GameError.notPurchasable }
        guard cells[cell].owner == id else { throw GameError.notOwner }
        guard ownsFullGroup(id, group) else { throw GameError.needFullGroup }
        let groupCells = board.cells(in: group)
        guard !groupCells.contains(where: { cells[$0].isMortgaged }) else { throw GameError.groupHasMortgage }
        guard cells[cell].branches < Board.maxBranches else { throw GameError.maxLevel }
        if settings.unevenBuilding == true {
            // Быстрая игра: филиалы на любом поле, но большая звезда — только когда
            // на остальных полях группы уже по 4 филиала.
            if cells[cell].branches == Board.maxBranches - 1 {
                let others = groupCells.filter { $0 != cell }
                guard others.allSatisfy({ cells[$0].branches >= Board.maxBranches - 1 }) else {
                    throw GameError.unevenBuild
                }
            }
        } else {
            let lowest = groupCells.map { cells[$0].branches }.min() ?? 0
            guard cells[cell].branches == lowest else { throw GameError.unevenBuild }
        }
        if let limit = settings.maxBuildsPerGroupPerTurn, buildsThisTurn[group, default: 0] >= limit {
            throw GameError.buildLimitThisTurn
        }
        guard players[id].cash >= cost else { throw GameError.notEnoughCash }

        players[id].cash -= cost
        cells[cell].branches += 1
        buildsThisTurn[group, default: 0] += 1
        ev.append(.built(player: id, cell: cell, level: cells[cell].branches))
    }

    mutating func sellBranch(_ cell: CellID, by id: PlayerID, _ ev: inout [GameEvent]) throws {
        guard board.cells.indices.contains(cell), let group = board.cells[cell].group else { throw GameError.noBranches }
        guard cells[cell].owner == id else { throw GameError.notOwner }
        guard cells[cell].branches > 0 else { throw GameError.noBranches }
        let groupLevels = board.cells(in: group).map { cells[$0].branches }
        if settings.unevenBuilding == true {
            // Пока в группе стоит большая звезда, у остальных полей нельзя опускаться ниже 4 филиалов.
            let hasHotel = groupLevels.contains(Board.maxBranches)
            guard !hasHotel || cells[cell].branches == Board.maxBranches else { throw GameError.unevenBuild }
        } else {
            let highest = groupLevels.max() ?? 0
            guard cells[cell].branches == highest else { throw GameError.unevenBuild }
        }

        cells[cell].branches -= 1
        players[id].cash += branchRefund(cell)
        ev.append(.branchSold(player: id, cell: cell, level: cells[cell].branches))
    }

    mutating func mortgage(_ cell: CellID, by id: PlayerID, _ ev: inout [GameEvent]) throws {
        guard board.cells.indices.contains(cell), let price = board.cells[cell].price else { throw GameError.notPurchasable }
        guard cells[cell].owner == id else { throw GameError.notOwner }
        guard !cells[cell].isMortgaged else { throw GameError.alreadyMortgaged }
        guard !groupHasBranches(cell) else { throw GameError.hasBranchesInGroup }

        cells[cell].isMortgaged = true
        cells[cell].mortgageTurnsLeft = settings.mortgageTurnLimit
        players[id].cash += price / 2
        ev.append(.mortgaged(player: id, cell: cell))
    }

    mutating func unmortgage(_ cell: CellID, by id: PlayerID, _ ev: inout [GameEvent]) throws {
        guard board.cells.indices.contains(cell), board.cells[cell].isPurchasable else { throw GameError.notPurchasable }
        guard cells[cell].owner == id else { throw GameError.notOwner }
        guard cells[cell].isMortgaged else { throw GameError.notMortgaged }
        let cost = unmortgageCost(cell)
        guard players[id].cash >= cost else { throw GameError.notEnoughCash }

        players[id].cash -= cost
        cells[cell].isMortgaged = false
        cells[cell].mortgageTurnsLeft = nil
        ev.append(.unmortgaged(player: id, cell: cell))
    }

    /// В начале хода владельца срок залога уменьшается; истёк — улица уходит банку.
    mutating func tickMortgages(for id: PlayerID, _ ev: inout [GameEvent]) {
        for cell in cellsOwned(by: id) where cells[cell].isMortgaged {
            guard let left = cells[cell].mortgageTurnsLeft else { continue }
            if left <= 1 {
                cells[cell] = Ownership()
                ev.append(.mortgageExpired(player: id, cell: cell))
            } else {
                cells[cell].mortgageTurnsLeft = left - 1
            }
        }
    }

    // MARK: - Договоры

    func validateTrade(_ offer: TradeOffer) throws {
        guard offer.from != offer.to, players.indices.contains(offer.to), !players[offer.to].isBankrupt else {
            throw GameError.invalidTrade("неверный получатель")
        }
        guard offer.giveCash >= 0, offer.takeCash >= 0 else { throw GameError.invalidTrade("отрицательная сумма") }
        guard !(offer.giveCells.isEmpty && offer.takeCells.isEmpty) || offer.giveCash > 0 || offer.takeCash > 0 else {
            throw GameError.invalidTrade("пустой договор")
        }
        guard Set(offer.giveCells).count == offer.giveCells.count,
              Set(offer.takeCells).count == offer.takeCells.count else {
            throw GameError.invalidTrade("улица указана дважды")
        }
        for cell in offer.giveCells {
            guard cells.indices.contains(cell), cells[cell].owner == offer.from else { throw GameError.notOwner }
            guard !groupHasBranches(cell) else { throw GameError.hasBranchesInGroup }
        }
        for cell in offer.takeCells {
            guard cells.indices.contains(cell), cells[cell].owner == offer.to else { throw GameError.notOwner }
            guard !groupHasBranches(cell) else { throw GameError.hasBranchesInGroup }
        }
        guard players[offer.from].cash >= offer.giveCash, players[offer.to].cash >= offer.takeCash else {
            throw GameError.notEnoughCash
        }
    }

    mutating func proposeTrade(_ offer: TradeOffer, by actor: PlayerID, _ ev: inout [GameEvent]) throws {
        guard offer.from == actor else { throw GameError.notYourTurn }
        guard tradeOffersThisTurn < settings.maxTradeOffersPerTurn else { throw GameError.tooManyOffers }
        try validateTrade(offer)

        var flagged = false
        switch settings.tradePolicy {
        case .free:
            break
        case .warnIfUnfair(let ratio):
            flagged = isUnfair(offer, ratio: ratio)
        case .forbidIfUnfair(let ratio):
            if isUnfair(offer, ratio: ratio) { throw GameError.unfairTrade }
        }

        tradeOffersThisTurn += 1
        pendingTrade = offer
        ev.append(.tradeProposed(offer: offer, flaggedUnfair: flagged))
    }

    mutating func executeTrade(_ offer: TradeOffer) {
        for cell in offer.giveCells { cells[cell].owner = offer.to }
        for cell in offer.takeCells { cells[cell].owner = offer.from }
        players[offer.from].cash += offer.takeCash - offer.giveCash
        players[offer.to].cash += offer.giveCash - offer.takeCash
    }

    // MARK: - Смена хода и конец игры

    mutating func advanceTurn(_ ev: inout [GameEvent]) {
        doublesInRow = 0
        extraRollPending = false
        bonusMovePending = false
        tradeOffersThisTurn = 0
        buildsThisTurn = [:]

        var index = turnIndex
        repeat {
            index += 1
            if index >= turnOrder.count {
                index = 0
                round += 1
            }
        } while players[turnOrder[index]].isBankrupt
        turnIndex = index
        turnNumber += 1

        // Лимит проверяется только на границе круга: у всех одинаковое число ходов.
        if let limit = settings.maxRounds, round > limit {
            endGame(winner: leaderByNetWorth(), byRoundLimit: true, &ev)
            return
        }

        phase = .awaitingRoll
        ev.append(.turnStarted(player: currentPlayerID, round: round))
        tickMortgages(for: currentPlayerID, &ev)
    }

    /// Закончена ли партия: остался один игрок или (в 2×2) игроки одной команды.
    /// Возвращает `.some(победитель)`; внутри `nil` — ничья.
    func finalResult() -> PlayerID?? {
        let active = activePlayerIDs
        if active.count <= 1 { return .some(active.first) }
        if isTeamGame {
            let teams = Set(active.compactMap { players[$0].team })
            if teams.count == 1 {
                return .some(active.max { netWorth(of: $0) < netWorth(of: $1) })
            }
        }
        return nil
    }

    mutating func endGame(winner: PlayerID?, byRoundLimit: Bool, _ ev: inout [GameEvent]) {
        phase = .gameOver(winner: winner)
        ev.append(.gameOver(winner: winner, team: winner.flatMap { players[$0].team }, byRoundLimit: byRoundLimit))
    }

    /// Самый богатый игрок (в 2×2 — самая богатая команда); при равенстве — ничья (`nil`).
    func leaderByNetWorth() -> PlayerID? {
        let active = activePlayerIDs
        if isTeamGame {
            let teams = Array(Set(active.compactMap { players[$0].team }))
            let ranked = teams.map { (team: $0, worth: teamWorth($0)) }.sorted { $0.worth > $1.worth }
            guard let best = ranked.first else { return nil }
            if ranked.count > 1 && ranked[1].worth == best.worth { return nil }
            return active
                .filter { players[$0].team == best.team }
                .max { netWorth(of: $0) < netWorth(of: $1) }
        }

        let ranked = active
            .map { (id: $0, worth: netWorth(of: $0)) }
            .sorted { $0.worth > $1.worth }
        guard let first = ranked.first else { return nil }
        if ranked.count > 1 && ranked[1].worth == first.worth { return nil }
        return first.id
    }
}

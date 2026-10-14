/// Простой бот. Видит только публичную информацию (`PublicView`):
/// деньги, владения и позиции игроков. Порядок колоды и кубики ему недоступны,
/// поэтому сила бота зависит только от того, как он оценивает ситуацию.
public struct SimpleBot: Sendable {
    /// Сколько денег бот старается держать в запасе.
    public var reserve: Int
    /// Во сколько раз дороже номинала бот предлагает выкупить недостающую компанию.
    public var tradeOfferFactor: Double

    public init(reserve: Int = 1_500, tradeOfferFactor: Double = 2.0) {
        self.reserve = reserve
        self.tradeOfferFactor = tradeOfferFactor
    }

    public func decide(_ view: PublicView, as me: PlayerID) -> Action {
        if let trade = view.pendingTrade {
            if trade.to == me { return shouldAccept(trade, view, me) ? .acceptTrade : .rejectTrade }
            return .cancelTrade
        }

        let player = view.players[me]
        switch view.phase {
        case .awaitingRoll:
            if let action = improve(view, me) { return action }
            if view.tradeOffersThisTurn == 0, let offer = tradeIdea(view, me) { return .proposeTrade(offer) }
            if player.inJail {
                if player.jailCards > 0 { return .useJailCard }
                // В начале игры из тюрьмы выгодно выйти и скупать компании; позже — отсидеться.
                if freeCompanies(view) > 6 && player.cash >= view.settings.jailFine + reserve {
                    return .payJailFine
                }
            }
            return .roll

        case .awaitingMoveChoice(let options):
            let position = player.position
            let best = options.max { lhs, rhs in
                moveScore(from: position, steps: lhs, view, me) < moveScore(from: position, steps: rhs, view, me)
            }
            return .chooseMove(best ?? options[0])

        case .awaitingTeleport:
            let position = player.position
            let targets = view.board.cells.indices.filter { $0 != position }
            let best = targets.max { lhs, rhs in
                let lhsSteps = (lhs - position + view.board.count) % view.board.count
                let rhsSteps = (rhs - position + view.board.count) % view.board.count
                return moveScore(from: position, steps: lhsSteps, view, me)
                    < moveScore(from: position, steps: rhsSteps, view, me)
            }
            return .teleport(best ?? (position + 1) % view.board.count)

        case .awaitingBonusMove:
            return .takeBonusMove

        case .awaitingBuyDecision(let cell):
            let price = view.board.cells[cell].price ?? Int.max
            let status = groupStatus(cell, view, me)
            let wantsBadly = status.completesMine || status.blocksOther
            if player.cash >= price && (player.cash - price >= reserve || wantsBadly) { return .buy }
            return .declineBuy

        case .auction(let auction):
            // Не перебиваем напарника.
            if let leader = auction.highestBidder, view.areTeammates(leader, me) { return .passBid }
            let next = auction.minimumBid(step: view.settings.auctionStep)
            return next <= maxBid(auction.cell, view, me) ? .bid(next) : .passBid

        case .awaitingJackpot:
            return .skipJackpot

        case .awaitingEndTurn:
            if let action = improve(view, me) { return action }
            if view.tradeOffersThisTurn == 0, let offer = tradeIdea(view, me) { return .proposeTrade(offer) }
            return .endTurn

        case .debt(let debt):
            if player.cash >= debt.total { return .payDebt }
            if let action = raiseMoney(view, me) { return action }
            return .declareBankruptcy

        case .gameOver:
            return .endTurn
        }
    }

    // MARK: - Оценка

    func freeCompanies(_ view: PublicView) -> Int {
        view.cells.indices.filter { view.board.cells[$0].isPurchasable && view.cells[$0].owner == nil }.count
    }

    /// Завершает ли клетка мою монополию и мешает ли монополии соперника.
    func groupStatus(_ cell: CellID, _ view: PublicView, _ me: PlayerID) -> (completesMine: Bool, blocksOther: Bool) {
        guard let group = view.board.cells[cell].group else { return (false, false) }
        let others = view.board.cells(in: group).filter { $0 != cell }
        let completes = others.allSatisfy { view.cells[$0].owner == me }
        let owners = Set(others.compactMap { view.cells[$0].owner })
        let blocks = owners.count == 1
            && owners.allSatisfy { view.areOpponents($0, me) }
            && others.allSatisfy { view.cells[$0].owner != nil }
        return (completes, blocks)
    }

    /// Насколько выгодно сделать `steps` шагов: свободная нужная улица — хорошо, чужая рента — плохо.
    func moveScore(from position: CellID, steps: Int, _ view: PublicView, _ me: PlayerID) -> Int {
        let count = view.board.count
        let target = (position + steps) % count
        var score = position + steps >= count ? view.settings.passStartBonus : 0
        let info = view.board.cells[target]

        if info.isPurchasable {
            if view.cells[target].owner == nil {
                let affordable = view.players[me].cash >= (info.price ?? Int.max)
                let status = groupStatus(target, view, me)
                score += !affordable ? 0 : (status.completesMine ? 3_000 : (status.blocksOther ? 2_000 : 1_000))
            } else {
                score -= view.rent(for: target, payer: me)
            }
            return score
        }

        switch info.kind {
        case .goToJail: score -= 1_500
        case .tax(let amount): score -= amount
        default: break
        }
        return score
    }

    func maxBid(_ cell: CellID, _ view: PublicView, _ me: PlayerID) -> Int {
        let price = Double(view.board.cells[cell].price ?? 0)
        let status = groupStatus(cell, view, me)
        let value = status.completesMine ? price * 1.6 : (status.blocksOther ? price * 1.3 : price)
        let cash = view.players[me].cash
        return max(0, min(Int(value), cash - reserve / 2))
    }

    // MARK: - Развитие: выкуп залогов и филиалы

    func improve(_ view: PublicView, _ me: PlayerID) -> Action? {
        let cash = view.players[me].cash

        for group in ColorGroup.allCases.reversed() where view.ownsFullGroup(me, group) {
            let groupCells = view.board.cells(in: group)
            let mortgaged = groupCells.filter { view.cells[$0].isMortgaged }
            if !mortgaged.isEmpty {
                if let cell = mortgaged.first, cash - view.unmortgageCost(cell) >= reserve {
                    return .unmortgage(cell)
                }
                continue
            }
            if let limit = view.settings.maxBuildsPerGroupPerTurn,
               view.buildsThisTurn[group, default: 0] >= limit { continue }
            let lowest = groupCells.map { view.cells[$0].branches }.min() ?? Board.maxBranches
            guard lowest < Board.maxBranches,
                  let target = groupCells.first(where: { view.cells[$0].branches == lowest }),
                  let cost = view.board.cells[target].branchCost,
                  cash - cost >= reserve else { continue }
            return .build(target)
        }

        // Остальные залоги выкупаем, только если денег много.
        for cell in view.cellsOwned(by: me) where view.cells[cell].isMortgaged {
            if cash - view.unmortgageCost(cell) >= reserve * 3 { return .unmortgage(cell) }
        }
        return nil
    }

    // MARK: - Долги

    func raiseMoney(_ view: PublicView, _ me: PlayerID) -> Action? {
        let owned = view.cellsOwned(by: me)

        // Сначала продаём филиалы (с самого застроенного участка группы).
        for cell in owned where view.cells[cell].branches > 0 {
            guard let group = view.board.cells[cell].group else { continue }
            let highest = view.board.cells(in: group).map { view.cells[$0].branches }.max() ?? 0
            if view.cells[cell].branches == highest { return .sellBranch(cell) }
        }

        // Потом закладываем: сначала одиночные и дешёвые компании, монополии — в последнюю очередь.
        let candidates = owned
            .filter { !view.cells[$0].isMortgaged && !view.groupHasBranches($0) }
            .sorted { lhs, rhs in
                let lhsMonopoly = view.board.cells[lhs].group.map { view.ownsFullGroup(me, $0) } ?? false
                let rhsMonopoly = view.board.cells[rhs].group.map { view.ownsFullGroup(me, $0) } ?? false
                if lhsMonopoly != rhsMonopoly { return !lhsMonopoly }
                return (view.board.cells[lhs].price ?? 0) < (view.board.cells[rhs].price ?? 0)
            }
        return candidates.first.map { .mortgage($0) }
    }

    // MARK: - Договоры

    /// Пытается выкупить последнюю недостающую компанию группы.
    func tradeIdea(_ view: PublicView, _ me: PlayerID) -> TradeOffer? {
        guard view.currentPlayerID == me else { return nil }
        let cash = view.players[me].cash

        for group in ColorGroup.allCases {
            let groupCells = view.board.cells(in: group)
            let missing = groupCells.filter { view.cells[$0].owner != me }
            guard missing.count == 1, groupCells.count > 1,
                  let target = missing.first,
                  let other = view.cells[target].owner,
                  !view.players[other].isBankrupt,
                  !view.groupHasBranches(target) else { continue }

            // Напарнику платим номинал, сопернику — с наценкой.
            let factor = view.areTeammates(other, me) ? 1.0 : tradeOfferFactor
            let offerCash = Int(Double(view.assetValue(target)) * factor)
            guard cash - offerCash >= reserve else { continue }
            let offer = TradeOffer(from: me, to: other, giveCash: offerCash, takeCells: [target])
            if case .forbidIfUnfair(let ratio) = view.settings.tradePolicy,
               view.isUnfair(offer, ratio: ratio) { continue }
            return offer
        }
        return nil
    }

    func shouldAccept(_ offer: TradeOffer, _ view: PublicView, _ me: PlayerID) -> Bool {
        guard view.players[me].cash >= offer.takeCash else { return false }

        // Свою готовую монополию не разбиваем.
        let breaksMine = offer.takeCells.contains { cell in
            guard let group = view.board.cells[cell].group else { return false }
            return view.ownsFullGroup(me, group)
        }
        if breaksMine { return false }

        // Отдаём ли мы сопернику последнюю компанию его монополии?
        let completesTheirs = offer.takeCells.contains { cell in
            guard let group = view.board.cells[cell].group else { return false }
            return view.board.cells(in: group).allSatisfy { other in
                other == cell || view.cells[other].owner == offer.from || offer.takeCells.contains(other)
            }
        }

        let sides = view.tradeSides(offer)
        let gain = Double(sides.fromGives)
        let loss = Double(sides.toGives)
        // Напарнику помогаем собрать монополию — это общая победа.
        if view.areTeammates(offer.from, me) { return gain >= loss * 0.9 }
        return gain >= loss * (completesTheirs ? 1.8 : 1.1)
    }
}

/// Ходит за ботов, пока очередь не дойдёт до живого игрока или партия не закончится.
public enum BotRunner {
    /// Безопасное действие на случай, если движок отклонил ход бота.
    public static func fallbackAction(for state: GameState, actor: PlayerID) -> Action {
        if let trade = state.pendingTrade { return actor == trade.to ? .rejectTrade : .cancelTrade }
        switch state.phase {
        case .awaitingRoll: return .roll
        case .awaitingMoveChoice(let options): return .chooseMove(options[0])
        case .awaitingTeleport:
            return .teleport((state.players[actor].position + 1) % state.board.count)
        case .awaitingBonusMove: return .takeBonusMove
        case .awaitingBuyDecision: return .declineBuy
        case .auction: return .passBid
        case .awaitingJackpot: return .skipJackpot
        case .awaitingEndTurn: return .endTurn
        case .debt(let debt): return state.players[actor].cash >= debt.total ? .payDebt : .declareBankruptcy
        case .gameOver: return .endTurn
        }
    }

    /// - Parameter onError: вызывается, если движок отклонил действие бота (полезно для отладки).
    @discardableResult
    public static func runBots(_ state: inout GameState,
                               bot: SimpleBot = SimpleBot(),
                               maxSteps: Int = 200_000,
                               onError: ((Action, Error) -> Void)? = nil) -> [GameEvent] {
        var events: [GameEvent] = []
        var steps = 0
        while let actor = state.activePlayer, state.players[actor].isBot, steps < maxSteps {
            steps += 1
            let action = bot.decide(state.publicView, as: actor)
            do {
                events += try state.apply(action, by: actor)
            } catch {
                onError?(action, error)
                let fallback = fallbackAction(for: state, actor: actor)
                guard let fallbackEvents = try? state.apply(fallback, by: actor) else { break }
                events += fallbackEvents
            }
        }
        return events
    }
}

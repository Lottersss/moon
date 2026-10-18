import SwiftUI
import TycoonCore

/// Кнопки действий для текущей фазы. Недоступные приглушены, главное действие «дышит».
struct ActionPanel: View {
    @Environment(\.skin) private var skin
    let model: GameViewModel
    var onTrade: () -> Void
    var onManage: () -> Void
    var onNewGame: () -> Void

    @State private var jackpotNumbers: Set<Int> = []
    @State private var confirmBankruptcy = false

    var body: some View {
        VStack(spacing: 8) {
            if let error = model.errorMessage {
                Text(error)
                    .font(skin.font(12, .medium))
                    .foregroundStyle(skin.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            content
        }
        .panel()
        .confirmationDialog("Объявить банкротство?", isPresented: $confirmBankruptcy, titleVisibility: .visible) {
            Button("Да, я банкрот", role: .destructive) { model.perform(.declareBankruptcy) }
        } message: {
            Text("Вы выбываете из игры. Имущество уйдёт кредитору или банку.")
        }
    }

    @ViewBuilder private var content: some View {
        let state = model.state
        if case .gameOver(let winner) = state.phase {
            gameOver(winner: winner, state: state)
        } else if model.isBotThinking, let bot = state.activePlayer {
            HStack(spacing: 8) {
                ProgressView()
                Text("Ходит \(state.players[bot].name)…")
                    .font(skin.font(14, .medium))
                    .foregroundStyle(skin.uiSecondaryText)
                Spacer()
            }
            .frame(minHeight: 44)
        } else if let trade = state.pendingTrade {
            tradeResponse(trade, state: state)
        } else {
            phaseButtons(state)
        }
    }

    // MARK: - Фазы

    @ViewBuilder private func phaseButtons(_ state: GameState) -> some View {
        let me = state.currentPlayerID
        switch state.phase {
        case .awaitingRoll:
            if state.players[me].inJail {
                HStack(spacing: 8) {
                    action("Заплатить \(Format.money(state.settings.jailFine))", "banknote", .payJailFine)
                    action("Карточка", "key.fill", .useJailCard)
                }
            }
            action("Бросить кубики", "dice.fill", .roll, style: .primary)
            manageRow

        case .awaitingMoveChoice(let options):
            Text("Автобус: на сколько клеток идти? Можно нажать на подсвеченное поле")
                .font(skin.font(13)).foregroundStyle(skin.uiSecondaryText)
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { steps in
                    action("\(steps)", "bus.fill", .chooseMove(steps), style: .primary)
                }
            }

        case .awaitingTeleport:
            Label("Трипл! Нажмите на любую клетку доски", systemImage: "sparkles")
                .font(skin.font(14, .semibold))
                .foregroundStyle(skin.highlight)
                .frame(minHeight: 44)

        case .awaitingBonusMove:
            // Бонус срабатывает сам — как в Monopoly One.
            Label("Бонус: переход к ближайшему свободному полю…", systemImage: "star.fill")
                .font(skin.font(14, .semibold))
                .foregroundStyle(skin.highlight)
                .frame(minHeight: 44)

        case .awaitingBuyDecision(let cell):
            let price = state.board.cells[cell].price ?? 0
            HStack(spacing: 8) {
                action("Купить за \(Format.money(price))", "cart.fill", .buy, style: .primary)
                action("На аукцион", "hammer.fill", .declineBuy)
            }
            if state.players[me].cash < price {
                Button("Не хватает денег — заложить или продать", action: onManage)
                    .font(skin.font(12))
                    .foregroundStyle(skin.accent)
            }

        case .auction(let auction):
            auctionButtons(auction, state: state)

        case .awaitingJackpot:
            jackpot(state)

        case .awaitingEndTurn:
            action("Завершить ход", "checkmark.circle.fill", .endTurn, style: .primary)
            manageRow

        case .debt(let debt):
            let cash = state.players[debt.debtor].cash
            Text("Долг \(Format.money(debt.total)), у вас \(Format.money(cash)). Продайте филиалы или заложите фирмы.")
                .font(skin.font(13))
                .foregroundStyle(skin.uiText)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                action("Оплатить", "creditcard.fill", .payDebt, style: .primary)
                ActionButton(title: "Имущество", systemImage: "building.2.fill", action: onManage)
            }
            ActionButton(title: "Банкротство", systemImage: "flag.fill", style: .destructive,
                         enabled: model.canPerform(.declareBankruptcy)) { confirmBankruptcy = true }

        case .gameOver:
            EmptyView()
        }
    }

    private var manageRow: some View {
        HStack(spacing: 8) {
            ActionButton(title: "Договор", systemImage: "arrow.left.arrow.right",
                         enabled: model.activeHuman != nil, action: onTrade)
            ActionButton(title: "Имущество", systemImage: "building.2.fill",
                         enabled: model.activeHuman != nil, action: onManage)
        }
    }

    @ViewBuilder private func auctionButtons(_ auction: Auction, state: GameState) -> some View {
        let info = state.board.cells[auction.cell]
        let bidder = auction.currentBidder
        let leader = auction.highestBidder.map { state.players[$0].name } ?? "нет ставок"
        VStack(alignment: .leading, spacing: 2) {
            Text("Аукцион: «\(info.name)» (цена \(Format.money(info.price ?? 0)))")
                .font(skin.font(13, .semibold))
            Text(auction.highestBidder == nil
                 ? "Стартовая цена \(Format.money(auction.startPrice)) · решает \(state.players[bidder].name)"
                 : "Ставка \(Format.money(auction.highestBid)) · \(leader) · решает \(state.players[bidder].name)")
                .font(skin.font(12))
                .foregroundStyle(skin.uiSecondaryText)
        }
        .foregroundStyle(skin.uiText)
        .frame(maxWidth: .infinity, alignment: .leading)
        let minimum = auction.minimumBid(step: state.settings.auctionStep)
        HStack(spacing: 6) {
            ForEach([0, 4, 9], id: \.self) { extra in
                let amount = minimum + state.settings.auctionStep * extra
                action(Format.money(amount), extra == 0 ? "hammer.fill" : nil, .bid(amount),
                       style: extra == 0 ? .primary : .secondary)
            }
            action("Отказаться", "xmark", .passBid)
        }
    }

    @ViewBuilder private func jackpot(_ state: GameState) -> some View {
        let bet = state.settings.jackpotBet
        Text("Джекпот: ставка \(Format.money(bet)). Выберите 1–3 числа кубика.")
            .font(skin.font(13)).foregroundStyle(skin.uiText)
        HStack(spacing: 6) {
            ForEach(1...6, id: \.self) { n in
                let selected = jackpotNumbers.contains(n)
                Button("\(n)") {
                    if selected { jackpotNumbers.remove(n) } else if jackpotNumbers.count < 3 { jackpotNumbers.insert(n) }
                }
                .font(skin.font(16, .bold))
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(selected ? skin.accent : skin.cellFill.opacity(0.4),
                            in: RoundedRectangle(cornerRadius: skin.cornerRadius))
                .foregroundStyle(selected ? .white : skin.uiText)
            }
        }
        HStack(spacing: 8) {
            let numbers = jackpotNumbers.sorted()
            let payout = numbers.isEmpty ? 0 : bet * 6 / numbers.count
            ActionButton(title: numbers.isEmpty ? "Играть" : "Играть (×\(6 / max(numbers.count, 1)) = \(Format.money(payout)))",
                         systemImage: "dice.fill", style: .primary,
                         enabled: model.canPerform(.playJackpot(numbers: numbers))) {
                model.perform(.playJackpot(numbers: numbers))
                jackpotNumbers = []
            }
            action("Пропустить", nil, .skipJackpot)
        }
    }

    @ViewBuilder private func tradeResponse(_ offer: TradeOffer, state: GameState) -> some View {
        let from = state.players[offer.from].name
        VStack(alignment: .leading, spacing: 6) {
            Text("\(from) предлагает договор игроку \(state.players[offer.to].name)")
                .font(skin.font(14, .semibold))
            TradeSummary(offer: offer, state: state)
        }
        .foregroundStyle(skin.uiText)
        .frame(maxWidth: .infinity, alignment: .leading)
        HStack(spacing: 8) {
            action("Принять", "checkmark", .acceptTrade, style: .primary)
            action("Отклонить", "xmark", .rejectTrade)
        }
    }

    @ViewBuilder private func gameOver(winner: PlayerID?, state: GameState) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "trophy.fill")
                .font(.system(size: 34))
                .foregroundStyle(skin.highlight)
            if let winner {
                let team = Format.teamName(state.players[winner].team)
                Text(team.map { "Победила \($0)" } ?? "Победитель: \(state.players[winner].name)")
                    .font(skin.font(18, .bold))
                    .foregroundStyle(skin.uiText)
            } else {
                Text("Ничья").font(skin.font(18, .bold)).foregroundStyle(skin.uiText)
            }
        }
        .frame(maxWidth: .infinity)
        ActionButton(title: "Новая игра", systemImage: "arrow.clockwise", style: .primary, action: onNewGame)
    }

    /// Кнопка, доступность которой проверяет сам движок.
    private func action(_ title: String, _ icon: String?, _ action: Action, style: ActionStyle = .secondary) -> some View {
        ActionButton(title: title, systemImage: icon, style: style, enabled: model.canPerform(action)) {
            model.perform(action)
        }
    }
}

/// Краткое содержание договора: кто что отдаёт.
struct TradeSummary: View {
    @Environment(\.skin) private var skin
    let offer: TradeOffer
    let state: GameState

    var body: some View {
        let sides = state.tradeSides(offer)
        HStack(alignment: .top, spacing: 12) {
            column(title: "\(state.players[offer.from].name) отдаёт", cells: offer.giveCells,
                   cash: offer.giveCash, total: sides.fromGives)
            column(title: "\(state.players[offer.to].name) отдаёт", cells: offer.takeCells,
                   cash: offer.takeCash, total: sides.toGives)
        }
    }

    private func column(title: String, cells: [CellID], cash: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(skin.font(11, .semibold)).foregroundStyle(skin.uiSecondaryText)
            ForEach(cells, id: \.self) { cell in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(state.board.cells[cell].group.map { skin.groupColor($0) } ?? skin.uiSecondaryText)
                        .frame(width: 8, height: 12)
                    Text(state.board.cells[cell].name).font(skin.font(12)).lineLimit(1)
                }
            }
            if cash > 0 { Text("+ \(Format.money(cash))").font(skin.font(12, .semibold)) }
            if cells.isEmpty && cash == 0 { Text("ничего").font(skin.font(12)).foregroundStyle(skin.uiSecondaryText) }
            Text("≈ \(Format.money(total))").font(skin.font(11)).foregroundStyle(skin.uiSecondaryText)
        }
        .foregroundStyle(skin.uiText)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

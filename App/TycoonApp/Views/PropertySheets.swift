import SwiftUI
import TycoonCore

/// Карточка клетки: цены, рента, владелец и кнопки управления.
struct CellDetailSheet: View {
    @Environment(\.skin) private var skin
    let model: GameViewModel
    let cell: CellID

    var body: some View {
        let state = model.state
        let info = state.board.cells[cell]
        let own = state.cells[cell]

        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header(info)

                if let owner = own.owner {
                    HStack(spacing: 6) {
                        TokenView(player: owner, size: 20)
                        Text("Владелец: \(state.players[owner].name)").font(skin.font(14, .semibold))
                    }
                }
                if own.isMortgaged {
                    Label("В залоге" + (own.mortgageTurnsLeft.map { " · осталось ходов: \($0)" } ?? ""),
                          systemImage: "lock.fill")
                        .font(skin.font(13))
                        .foregroundStyle(skin.danger)
                }

                rentTable(info, state: state)

                if let owner = own.owner, owner == model.activeHuman {
                    PropertyActions(model: model, cell: cell)
                }
            }
            .foregroundStyle(skin.uiText)
            .padding()
        }
        .background(skin.background.ignoresSafeArea())
        .presentationDetents([.medium, .large])
    }

    private func header(_ info: CellInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let group = info.group {
                RoundedRectangle(cornerRadius: skin.cornerRadius)
                    .fill(skin.groupColor(group))
                    .frame(height: 34)
                    .overlay(Text(group.title).font(skin.font(13, .bold)).foregroundStyle(.white))
            }
            Text(info.name).font(skin.font(22, .bold))
            if let price = info.price {
                Text("Цена \(Format.money(price)) · залог \(Format.money(price / 2))")
                    .font(skin.font(13))
                    .foregroundStyle(skin.uiSecondaryText)
            }
        }
    }

    @ViewBuilder private func rentTable(_ info: CellInfo, state: GameState) -> some View {
        switch info.kind {
        case .company(_, _, let rents, let houseCost):
            let labels = ["Без домов", "1 дом", "2 дома", "3 дома", "4 дома", "Отель"]
            VStack(spacing: 4) {
                ForEach(rents.indices, id: \.self) { level in
                    row(labels[min(level, labels.count - 1)], Format.money(rents[level]),
                        current: state.cells[cell].branches == level && state.cells[cell].owner != nil)
                }
                row("Монополия без домов", Format.money(rents[0] * 2), current: false)
                row("Дом / отель стоит", Format.money(houseCost), current: false)
            }
            .panel()
        case .transport:
            VStack(spacing: 4) {
                ForEach(Board.transportRents.indices, id: \.self) { i in
                    row("Вокзалов у владельца: \(i + 1)", Format.money(Board.transportRents[i]), current: false)
                }
            }
            .panel()
        case .utility:
            VStack(spacing: 4) {
                row("Одно предприятие", "кубики × \(Board.utilityMultipliers[0])", current: false)
                row("Оба предприятия", "кубики × \(Board.utilityMultipliers[1])", current: false)
            }
            .panel()
        case .tax(let amount):
            Text("Налог \(Format.money(amount))").font(skin.font(15))
        case .chance, .communityChest:
            Text("Возьмите карточку из колоды").font(skin.font(15))
        default:
            EmptyView()
        }
    }

    private func row(_ title: String, _ value: String, current: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
        .font(skin.font(13))
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(current ? skin.accent.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Кнопки «построить / продать / заложить / выкупить» — доступность проверяет движок.
struct PropertyActions: View {
    @Environment(\.skin) private var skin
    let model: GameViewModel
    let cell: CellID

    var body: some View {
        let state = model.state
        let info = state.board.cells[cell]
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                if let cost = info.branchCost {
                    button("Дом −\(Format.money(cost))", "house.fill", .build(cell))
                    button("Продать +\(Format.money(state.branchRefund(cell)))", "house", .sellBranch(cell))
                }
            }
            HStack(spacing: 8) {
                if let price = info.price {
                    button("Заложить +\(Format.money(price / 2))", "lock.fill", .mortgage(cell))
                    button("Выкупить −\(Format.money(state.unmortgageCost(cell)))", "lock.open.fill", .unmortgage(cell))
                }
            }
        }
    }

    private func button(_ title: String, _ icon: String, _ action: Action) -> some View {
        ActionButton(title: title, systemImage: icon, enabled: model.canPerform(action)) {
            model.perform(action)
        }
    }
}

/// Всё имущество игрока по группам — быстрое управление без поиска на доске.
struct ManageSheet: View {
    @Environment(\.skin) private var skin
    @Environment(\.dismiss) private var dismiss
    let model: GameViewModel

    var body: some View {
        let state = model.state
        let me = model.activeHuman ?? state.currentPlayerID
        let owned = state.cellsOwned(by: me)

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Наличные: \(Format.money(state.players[me].cash))")
                        .font(skin.font(16, .bold))
                    if case .debt(let debt) = state.phase, debt.debtor == me {
                        Text("Нужно собрать \(Format.money(debt.total))")
                            .font(skin.font(13))
                            .foregroundStyle(skin.danger)
                    }
                    if owned.isEmpty {
                        Text("У вас пока нет улиц").foregroundStyle(skin.uiSecondaryText)
                    }
                    ForEach(owned, id: \.self) { cell in
                        let info = state.board.cells[cell]
                        let own = state.cells[cell]
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(info.group.map { skin.groupColor($0) } ?? skin.uiSecondaryText)
                                    .frame(width: 8, height: 26)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(info.name).font(skin.font(14, .semibold))
                                    Text(status(own)).font(skin.font(11)).foregroundStyle(skin.uiSecondaryText)
                                }
                                Spacer()
                                Text("рента \(Format.money(state.rentAmount(for: cell)))")
                                    .font(skin.font(11))
                                    .foregroundStyle(skin.uiSecondaryText)
                            }
                            PropertyActions(model: model, cell: cell)
                        }
                        .panel()
                    }
                }
                .foregroundStyle(skin.uiText)
                .padding()
            }
            .background(skin.background.ignoresSafeArea())
            .navigationTitle("Имущество")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
        }
    }

    private func status(_ own: Ownership) -> String {
        if own.isMortgaged { return "в залоге" }
        switch own.branches {
        case 0: return "без построек"
        case Board.maxBranches: return "отель"
        default: return "домов: \(own.branches)"
        }
    }
}

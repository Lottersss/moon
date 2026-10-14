import SwiftUI
import TycoonCore

/// Окно договора: слева «Отдаю», справа «Получаю».
struct TradeSheet: View {
    @Environment(\.skin) private var skin
    @Environment(\.dismiss) private var dismiss
    let model: GameViewModel

    @State var partner: PlayerID?
    @State private var give: Set<CellID> = []
    @State private var take: Set<CellID> = []
    @State private var giveCash = 0
    @State private var takeCash = 0

    var body: some View {
        let state = model.state
        let me = model.activeHuman ?? state.currentPlayerID
        let partners = state.activePlayerIDs.filter { $0 != me }

        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    partnerPicker(partners, state: state)

                    if let partner {
                        HStack(alignment: .top, spacing: 10) {
                            side(title: "Отдаю", owner: me, selection: $give, cash: $giveCash, state: state)
                            side(title: "Получаю", owner: partner, selection: $take, cash: $takeCash, state: state)
                        }
                        fairness(offer(me: me, partner: partner), state: state)
                    } else {
                        Text("Выберите игрока для договора")
                            .font(skin.font(14))
                            .foregroundStyle(skin.uiSecondaryText)
                            .padding(.top, 30)
                    }
                }
                .padding()
            }
            .background(skin.background.ignoresSafeArea())
            .navigationTitle("Договор")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    let canPropose = partner.map { model.canPerform(.proposeTrade(offer(me: me, partner: $0))) } ?? false
                    Button("Предложить") {
                        guard let partner else { return }
                        model.perform(.proposeTrade(offer(me: me, partner: partner)))
                        dismiss()
                    }
                    .disabled(!canPropose)
                    .fontWeight(.bold)
                }
            }
        }
        .onChange(of: partner) {
            take = []
            takeCash = 0
        }
    }

    private func offer(me: PlayerID, partner: PlayerID) -> TradeOffer {
        TradeOffer(from: me, to: partner,
                   giveCells: give.sorted(), giveCash: giveCash,
                   takeCells: take.sorted(), takeCash: takeCash)
    }

    private func partnerPicker(_ partners: [PlayerID], state: GameState) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(partners, id: \.self) { id in
                    let selected = partner == id
                    HStack(spacing: 6) {
                        TokenView(player: id, size: 22)
                        Text(state.players[id].name).font(skin.font(14, .semibold))
                        if state.areTeammates(id, model.activeHuman ?? state.currentPlayerID) {
                            Image(systemName: "person.2.fill").font(.system(size: 11))
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(selected ? skin.accent.opacity(0.25) : Color.clear, in: Capsule())
                    .overlay(Capsule().stroke(selected ? skin.accent : skin.uiSecondaryText.opacity(0.4)))
                    .foregroundStyle(skin.uiText)
                    .onTapGesture { partner = id }
                }
            }
        }
    }

    /// Колонка одного участника: улицы (без домов в группе) и деньги.
    private func side(title: String, owner: PlayerID, selection: Binding<Set<CellID>>,
                      cash: Binding<Int>, state: GameState) -> some View {
        let tradeable = state.cellsOwned(by: owner).filter { !state.groupHasBranches($0) }
        let maxCash = state.players[owner].cash
        let step = 100

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                TokenView(player: owner, size: 18)
                Text(title).font(skin.font(15, .bold))
            }
            if tradeable.isEmpty {
                Text("Нет улиц для обмена").font(skin.font(12)).foregroundStyle(skin.uiSecondaryText)
            }
            ForEach(tradeable, id: \.self) { cell in
                let info = state.board.cells[cell]
                let on = selection.wrappedValue.contains(cell)
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(info.group.map { skin.groupColor($0) } ?? skin.uiSecondaryText)
                        .frame(width: 6)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(info.name).font(skin.font(12, .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                        Text(state.cells[cell].isMortgaged ? "в залоге" : Format.money(info.price ?? 0))
                            .font(skin.font(10)).foregroundStyle(skin.uiSecondaryText)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(on ? skin.accent : skin.uiSecondaryText)
                }
                .padding(6)
                .frame(height: 40)
                .background(on ? skin.accent.opacity(0.15) : Color.clear,
                            in: RoundedRectangle(cornerRadius: skin.cornerRadius))
                .contentShape(Rectangle())
                .onTapGesture {
                    if on { selection.wrappedValue.remove(cell) } else { selection.wrappedValue.insert(cell) }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Деньги: \(Format.money(cash.wrappedValue))").font(skin.font(13, .semibold))
                Stepper("", value: cash, in: 0...max(0, maxCash), step: step)
                    .labelsHidden()
                Text("доступно \(Format.money(maxCash))").font(skin.font(10)).foregroundStyle(skin.uiSecondaryText)
            }
            .padding(.top, 4)
        }
        .foregroundStyle(skin.uiText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    /// Индикатор честности: сравнение сторон по номиналу и предупреждение о перекосе.
    private func fairness(_ offer: TradeOffer, state: GameState) -> some View {
        let sides = state.tradeSides(offer)
        let total = max(sides.fromGives + sides.toGives, 1)
        let share = Double(sides.fromGives) / Double(total)
        var unfair = false
        var forbidden = false
        switch state.settings.tradePolicy {
        case .free: break
        case .warnIfUnfair(let ratio): unfair = state.isUnfair(offer, ratio: ratio)
        case .forbidIfUnfair(let ratio):
            unfair = state.isUnfair(offer, ratio: ratio)
            forbidden = unfair
        }

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Вы отдаёте ≈ \(Format.money(sides.fromGives))")
                Spacer()
                Text("Получаете ≈ \(Format.money(sides.toGives))")
            }
            .font(skin.font(12, .semibold))
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    Rectangle().fill(skin.playerColor(offer.from)).frame(width: proxy.size.width * share)
                    Rectangle().fill(skin.playerColor(offer.to))
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())
            if unfair {
                Label(forbidden ? "Слишком неравный договор — такие запрещены"
                                : "Неравный договор: все игроки увидят пометку",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(skin.font(12))
                    .foregroundStyle(forbidden ? skin.danger : skin.highlight)
            }
            Text("Улицы из монополий с домами обменивать нельзя — сначала продайте дома.")
                .font(skin.font(10))
                .foregroundStyle(skin.uiSecondaryText)
        }
        .foregroundStyle(skin.uiText)
        .panel()
    }
}

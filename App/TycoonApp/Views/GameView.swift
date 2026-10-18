import SwiftUI
import TycoonCore

/// Экран партии. На iPhone — доска сверху, ниже игроки, кнопки и журнал.
/// На iPad и в альбомной ориентации — доска слева, панель справа.
struct GameView: View {
    @Environment(\.skin) private var skin
    @Bindable var model: GameViewModel
    var onExit: () -> Void
    var onChangeSkin: () -> Void

    @State private var selectedCell: CellID?
    @State private var tradePartner: PlayerID?
    @State private var showTrade = false
    @State private var showManage = false
    @State private var confirmExit = false

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width > proxy.size.height
            Group {
                if wide {
                    // Альбомная ориентация и iPad: игроки колонкой слева, как в Monopoly One.
                    HStack(alignment: .top, spacing: 10) {
                        PlayersPanel(model: model, vertical: true) { id in openTrade(with: id) }
                            .frame(width: min(170, proxy.size.width * 0.18))
                        board
                            .frame(width: min(proxy.size.height - 16, proxy.size.width * 0.58))
                        VStack(spacing: 8) {
                            topBar
                            actionPanel
                            Spacer(minLength: 0)
                        }
                    }
                } else {
                    // Доска сверху, игроки и кнопки прижаты к низу — под большой палец.
                    VStack(spacing: 8) {
                        topBar
                        board
                        PlayersPanel(model: model) { id in openTrade(with: id) }
                        Spacer(minLength: 0)
                        actionPanel
                    }
                }
            }
            .padding(8)
        }
        .background(skin.background.ignoresSafeArea())
        .overlay { handoffOverlay }
        .overlay(alignment: .top) {
            if model.reconnecting {
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("Связь с хостом потеряна. Переподключаемся…")
                        .font(skin.font(13, .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(skin.danger, in: Capsule())
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: model.reconnecting)
        .sheet(item: Binding(get: { selectedCell.map(SelectedCell.init) },
                             set: { selectedCell = $0?.id })) { selected in
            CellDetailSheet(model: model, cell: selected.id)
                .environment(\.skin, skin)
        }
        .sheet(isPresented: $showTrade) {
            TradeSheet(model: model, partner: tradePartner)
                .environment(\.skin, skin)
        }
        .sheet(isPresented: $showManage) {
            ManageSheet(model: model)
                .environment(\.skin, skin)
        }
        .confirmationDialog("Выйти из партии?", isPresented: $confirmExit, titleVisibility: .visible) {
            Button("Выйти", role: .destructive, action: onExit)
        }
        // Аватары аккаунтов вместо фишек скина — на доске, в карточках и окнах.
        .environment(\.avatars, model.config.avatars ?? [:])
    }

    private var board: some View {
        BoardView(model: model) { cell in
            if !model.tapCell(cell) { selectedCell = cell }
        }
    }

    private var actionPanel: some View {
        ActionPanel(model: model,
                    onTrade: { openTrade(with: nil) },
                    onManage: { showManage = true },
                    onNewGame: onExit)
    }

    private var topBar: some View {
        HStack {
            Button { confirmExit = true } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 22))
            }
            Spacer()
            VStack(spacing: 0) {
                Text(model.config.mode.title).font(skin.font(15, .bold))
                Text(model.config.mode.subtitle).font(skin.font(10)).foregroundStyle(skin.uiSecondaryText)
                GameClockLabel(model: model)
            }
            Spacer()
            Button(action: onChangeSkin) {
                Image(systemName: "paintpalette.fill").font(.system(size: 20))
            }
        }
        .foregroundStyle(skin.uiText)
    }

    private func openTrade(with partner: PlayerID?) {
        guard let me = model.activeHuman, model.state.pendingTrade == nil else { return }
        if let partner, partner == me || model.state.players[partner].isBankrupt { return }
        tradePartner = partner
        showTrade = true
    }

    /// «Передайте телефон»: в hot-seat игрок не нажмёт за другого случайно.
    @ViewBuilder private var handoffOverlay: some View {
        if let next = model.handoffTo {
            ZStack {
                Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                VStack(spacing: 16) {
                    TokenView(player: next, size: 64)
                    Text("Передайте телефон")
                        .font(skin.font(16))
                        .foregroundStyle(skin.uiSecondaryText)
                    Text(model.state.players[next].name)
                        .font(skin.font(30, .bold))
                        .foregroundStyle(skin.uiText)
                    ActionButton(title: "Я \(model.state.players[next].name), продолжить",
                                 systemImage: "hand.tap.fill", style: .primary) {
                        model.confirmHandoff()
                    }
                    .frame(maxWidth: 320)
                }
                .padding(30)
            }
            .transition(.opacity)
        }
    }
}

private struct SelectedCell: Identifiable {
    let id: CellID
}

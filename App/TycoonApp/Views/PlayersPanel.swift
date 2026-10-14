import SwiftUI
import TycoonCore

/// Игроки в духе Monopoly One: аватар в кольце цвета игрока, имя, деньги.
/// Карточка текущего игрока залита его цветом и показывает секунды таймера.
/// Нажатие на карточку — предложить договор.
struct PlayersPanel: View {
    @Environment(\.skin) private var skin
    let model: GameViewModel
    /// Колонка (альбомная ориентация, iPad) или строка (iPhone вертикально).
    var vertical = false
    var onTrade: (PlayerID) -> Void

    var body: some View {
        let state = model.state
        let order = state.turnOrder
        if vertical {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(order, id: \.self) { id in
                        PlayerCard(model: model, player: state.players[id], compact: false)
                            .onTapGesture { onTrade(id) }
                    }
                }
            }
            .scrollIndicators(.hidden)
        } else if order.count <= 4 {
            HStack(spacing: 6) {
                ForEach(order, id: \.self) { id in
                    PlayerCard(model: model, player: state.players[id], compact: true)
                        .onTapGesture { onTrade(id) }
                }
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(order, id: \.self) { id in
                            PlayerCard(model: model, player: state.players[id], compact: true)
                                .frame(width: 92)
                                .id(id)
                                .onTapGesture { onTrade(id) }
                        }
                    }
                }
                .onChange(of: state.activePlayer) { _, active in
                    guard let active else { return }
                    withAnimation { proxy.scrollTo(active, anchor: .center) }
                }
            }
        }
    }
}

struct PlayerCard: View {
    @Environment(\.skin) private var skin
    let model: GameViewModel
    let player: Player
    let compact: Bool

    var body: some View {
        let state = model.state
        let isCurrent = state.activePlayer == player.id && !state.isOver
        let color = skin.playerColor(player.id)
        let textColor: Color = isCurrent ? .white : skin.uiText
        let avatar: CGFloat = compact ? 30 : 46

        VStack(spacing: compact ? 3 : 6) {
            ZStack(alignment: .topLeading) {
                TokenView(player: player.id, size: avatar, dimmed: player.isBankrupt)
                    .padding(3)
                    .overlay(Circle().stroke(color, lineWidth: compact ? 2 : 3))
                    .frame(maxWidth: .infinity)
                if isCurrent && !player.isBot {
                    TimerBubble(deadline: model.deadline, size: compact ? 20 : 30)
                }
            }

            HStack(spacing: 3) {
                if let team = player.team {
                    Text(team == 0 ? "A" : "B")
                        .font(skin.font(compact ? 8 : 10, .heavy))
                        .padding(.horizontal, 3)
                        .background(Capsule().fill(isCurrent ? Color.white.opacity(0.3) : skin.accent.opacity(0.25)))
                }
                if player.isBot { Image(systemName: "cpu").font(.system(size: compact ? 8 : 10)) }
                if player.inJail { Image(systemName: "lock.fill").font(.system(size: compact ? 8 : 10)) }
                Text(player.name)
                    .font(skin.font(compact ? 11 : 14, .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .strikethrough(player.isBankrupt)
            }
            .foregroundStyle(textColor)

            Text(player.isBankrupt ? "Банкрот" : Format.money(player.cash))
                .font(skin.font(compact ? 14 : 22, .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(player.isBankrupt ? skin.danger : textColor)
                .contentTransition(.numericText())
                .animation(.easeOut, value: player.cash)
        }
        .padding(.vertical, compact ? 6 : 12)
        .padding(.horizontal, compact ? 4 : 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: skin.cornerRadius + 4)
                .fill(isCurrent ? color : (skin.isDark ? Color.white.opacity(0.07) : Color.white.opacity(0.65)))
        )
        .shadow(color: isCurrent ? color.opacity(0.5) : .clear, radius: 8)
        .opacity(player.isBankrupt ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.25), value: isCurrent)
    }
}

/// Журнал партии отдельной панелью (используется, если журнал не помещается в центр доски).
struct EventLogView: View {
    @Environment(\.skin) private var skin
    let entries: [LogEntry]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(entries) { entry in
                    if entry.isSeparator {
                        Text(entry.text)
                            .font(skin.font(11, .semibold))
                            .foregroundStyle(skin.uiSecondaryText)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 4)
                    } else {
                        HStack(alignment: .top, spacing: 6) {
                            Circle()
                                .fill(entry.player.map { skin.playerColor($0) } ?? skin.uiSecondaryText)
                                .frame(width: 7, height: 7)
                                .padding(.top, 5)
                            Text(entry.text)
                                .font(skin.font(13))
                                .foregroundStyle(skin.uiText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
            .animation(.default, value: entries.first?.id)
        }
    }
}

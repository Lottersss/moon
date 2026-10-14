import SwiftUI
import TycoonCore

/// Центр доски: сверху чей ход, кубики и подсказка, ниже — журнал партии (как в Monopoly One).
struct BoardCenterView: View {
    @Environment(\.skin) private var skin
    let model: GameViewModel

    var body: some View {
        let state = model.state
        let current = state.currentPlayerID

        VStack(spacing: 6) {
            HStack(spacing: 8) {
                TokenView(player: current, size: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(state.players[current].name)
                        .font(skin.font(14, .bold))
                        .foregroundStyle(skin.boardText)
                        .lineLimit(1)
                    Text(EventText.phaseHint(state))
                        .font(skin.font(10, .medium))
                        .foregroundStyle(skin.boardSecondaryText)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 4)
                dice
            }

            Rectangle()
                .fill(skin.boardSecondaryText.opacity(0.25))
                .frame(height: 1)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(model.log) { entry in
                        logLine(entry)
                    }
                }
                // Без анимации вставки: новые строки приходят пачками и при анимации наезжают друг на друга.
            }
            .scrollIndicators(.hidden)
        }
        .padding(8)
    }

    private func logLine(_ entry: LogEntry) -> some View {
        Group {
            if entry.isSeparator {
                Text(entry.text)
                    .font(skin.font(9, .semibold))
                    .foregroundStyle(skin.boardSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                // Имя игрока в начале строки окрашивается в его цвет — как в журнале Monopoly One.
                coloredText(entry)
                    .font(skin.font(11))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func coloredText(_ entry: LogEntry) -> Text {
        let state = model.state
        guard let player = entry.player else {
            return Text(entry.text).foregroundColor(skin.boardText)
        }
        let name = state.players[player].name
        guard entry.text.hasPrefix(name) else {
            return Text(entry.text).foregroundColor(skin.boardText)
        }
        let rest = String(entry.text.dropFirst(name.count))
        return Text(name).foregroundColor(skin.playerColor(player)).bold()
            + Text(rest).foregroundColor(skin.boardText)
    }

    @ViewBuilder private var dice: some View {
        if let roll = model.state.lastRoll {
            HStack(spacing: 4) {
                DieView(value: roll.d1, size: 24)
                DieView(value: roll.d2, size: 24)
                if let speed = model.state.lastSpeedDie {
                    SpeedDieView(face: speed, size: 24)
                }
            }
            .id(model.rollCounter)
            .transition(.scale(scale: 0.4).combined(with: .opacity))
            .animation(.spring(response: 0.35, dampingFraction: 0.55), value: model.rollCounter)
        }
    }
}

/// Секунды до конца хода — пузырь на карточке текущего игрока.
struct TimerBubble: View {
    @Environment(\.skin) private var skin
    let deadline: Date?
    var size: CGFloat = 30

    var body: some View {
        if let deadline {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let left = max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
                Text("\(left)")
                    .font(skin.font(size * 0.45, .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Circle().fill(left <= 10 ? skin.danger : Color.black.opacity(0.35)))
            }
        }
    }
}

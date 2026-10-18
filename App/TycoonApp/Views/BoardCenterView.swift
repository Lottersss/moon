import SwiftUI
import TycoonCore

/// Центр доски: сверху чей ход, кубики и подсказка, ниже — журнал партии (как в Monopoly One).
struct BoardCenterView: View {
    @Environment(\.skin) private var skin
    let model: GameViewModel

    @State private var draft = ""
    @FocusState private var chatFocused: Bool

    /// Быстрые фразы — не печатать на маленькой клавиатуре посреди хода.
    private static let quickPhrases = ["Привет! 👋", "Удачи!", "Договоримся? 🤝", "Везунчик 🍀", "Ха-ха 😂", "Хорошая игра!"]

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

            if model.canChat {
                chatBar
            }
        }
        .padding(8)
    }

    /// Чат как в Monopoly One — строка ввода под журналом. Сообщения идут в тот же журнал.
    private var chatBar: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(Self.quickPhrases, id: \.self) { phrase in
                    Button(phrase) { model.sendChat(phrase) }
                }
            } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: 15))
            }
            TextField("Сообщение", text: $draft)
                .font(skin.font(11))
                .submitLabel(.send)
                .focused($chatFocused)
                .onSubmit(sendDraft)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Capsule().fill(skin.boardSecondaryText.opacity(0.18)))
            Button(action: sendDraft) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 14))
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .foregroundStyle(skin.boardText)
        .tint(skin.accent)
    }

    private func sendDraft() {
        model.sendChat(draft)
        draft = ""
    }

    private func logLine(_ entry: LogEntry) -> some View {
        Group {
            if entry.isSeparator {
                Text(entry.text)
                    .font(skin.font(9, .semibold))
                    .foregroundStyle(skin.boardSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if entry.isChat == true {
                // Сообщение чата: значок и подложка, чтобы не путать с ходами.
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(entry.player.map { skin.playerColor($0) } ?? skin.boardSecondaryText)
                        .padding(.top, 2)
                    coloredText(entry)
                        .font(skin.font(11, .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(skin.boardSecondaryText.opacity(0.12)))
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

/// Время партии и налоги: «⏱ 52:10 · «Старт» не платит · налог на аренду 50%».
struct GameClockLabel: View {
    @Environment(\.skin) private var skin
    let model: GameViewModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let info = model.clockInfo(at: context.date)
            Text((["⏱ " + info.time] + info.notes).joined(separator: " · "))
                .font(skin.font(10, .medium))
                .monospacedDigit()
                .foregroundStyle(info.notes.isEmpty ? skin.uiSecondaryText : skin.danger)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
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

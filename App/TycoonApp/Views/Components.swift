import SwiftUI
import TycoonCore

/// Фишка игрока: кружок цвета игрока с символом из скина.
struct TokenView: View {
    @Environment(\.skin) private var skin
    @Environment(\.avatars) private var avatars
    let player: PlayerID
    var size: CGFloat = 22
    var dimmed = false

    var body: some View {
        ZStack {
            Circle().fill(skin.playerColor(player))
            Image(systemName: avatars[player] ?? skin.tokenSymbol(player))
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(.white, lineWidth: max(1, size * 0.08)))
        .shadow(color: .black.opacity(0.35), radius: size * 0.12, y: size * 0.05)
        .opacity(dimmed ? 0.35 : 1)
    }
}

/// Обычный кубик с точками.
struct DieView: View {
    @Environment(\.skin) private var skin
    let value: Int
    var size: CGFloat = 34

    private static let pips: [Int: [(CGFloat, CGFloat)]] = [
        1: [(0.5, 0.5)],
        2: [(0.27, 0.27), (0.73, 0.73)],
        3: [(0.27, 0.27), (0.5, 0.5), (0.73, 0.73)],
        4: [(0.27, 0.27), (0.73, 0.27), (0.27, 0.73), (0.73, 0.73)],
        5: [(0.27, 0.27), (0.73, 0.27), (0.5, 0.5), (0.27, 0.73), (0.73, 0.73)],
        6: [(0.27, 0.25), (0.73, 0.25), (0.27, 0.5), (0.73, 0.5), (0.27, 0.75), (0.73, 0.75)],
    ]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.2)
                .fill(skin.diceFill)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
            ForEach(Array((Self.pips[value] ?? []).enumerated()), id: \.offset) { _, pip in
                Circle()
                    .fill(skin.dicePip)
                    .frame(width: size * 0.17, height: size * 0.17)
                    .position(x: pip.0 * size, y: pip.1 * size)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Крупные кубики посреди доски при каждом броске. Вылетают снизу, плавно кувыркаются
/// и замедляются, грани мелькают всё реже, кубики с отскоком встают на выпавшие числа
/// (третий кубик «Перестановки» появляется рядом) и через секунду исчезают.
struct DiceRollOverlay: View {
    let model: GameViewModel
    var size: CGFloat

    @State private var visible = false
    @State private var rolling = false
    @State private var landed = false
    /// Ход броска от 0 до 1: из него считаются поворот, полёт и масштаб.
    @State private var progress = 0.0
    @State private var face1 = 1
    @State private var face2 = 1
    @State private var task: Task<Void, Never>?

    var body: some View {
        ZStack {
            if visible, let roll = model.state.lastRoll {
                HStack(spacing: size * 0.3) {
                    die(rolling ? face1 : roll.d1, direction: 1)
                    die(rolling ? face2 : roll.d2, direction: -1)
                    if !rolling, let speed = model.state.lastSpeedDie {
                        SpeedDieView(face: speed, size: size)
                            .transition(.scale(scale: 0.2).combined(with: .opacity))
                    }
                }
                .padding(size * 0.3)
                .background(RoundedRectangle(cornerRadius: size * 0.35).fill(.black.opacity(0.45)))
                .scaleEffect(landed ? 1 : 0.94)
                .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
        }
        .onChange(of: model.rollCounter) { _, _ in roll() }
    }

    /// Кубик в полёте: два оборота в плоскости и один «через ребро», летит снизу и растёт.
    /// При `progress == 1` все углы кратны 360°, поэтому кубик встаёт ровно.
    private func die(_ value: Int, direction: Double) -> some View {
        DieView(value: value, size: size)
            .rotation3DEffect(.degrees(progress * 360), axis: (x: 1, y: direction, z: 0), perspective: 0.4)
            .rotationEffect(.degrees(progress * 720 * direction))
            .scaleEffect(0.45 + 0.55 * progress)
            .offset(x: (1 - progress) * size * 0.4 * direction, y: (1 - progress) * size * 1.4)
    }

    private func roll() {
        task?.cancel()
        task = Task { @MainActor in
            let spin = GameViewModel.diceSpinSeconds
            // Начальное положение — без анимации.
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) {
                progress = 0
                landed = false
                rolling = true
                face1 = Int.random(in: 1...6)
                face2 = Int.random(in: 1...6)
            }
            withAnimation(.easeOut(duration: 0.15)) { visible = true }
            // Полёт: быстро в начале, плавно в конце.
            withAnimation(.timingCurve(0.2, 0.7, 0.3, 1, duration: spin)) { progress = 1 }

            // Грани мелькают всё реже, как у настоящего замедляющегося кубика.
            var elapsed = 0.0
            var interval = 0.045
            while elapsed + interval < spin - 0.05 {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { return }
                face1 = Int.random(in: 1...6)
                face2 = Int.random(in: 1...6)
                elapsed += interval
                interval *= 1.25
            }
            try? await Task.sleep(for: .seconds(max(0, spin - elapsed)))
            if Task.isCancelled { return }

            // Приземление с небольшим отскоком.
            withAnimation(.spring(response: 0.28, dampingFraction: 0.45)) {
                rolling = false
                landed = true
            }
            try? await Task.sleep(for: .seconds(1.0))
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: 0.35)) { visible = false }
        }
    }
}

/// Третий кубик «Перестановки».
struct SpeedDieView: View {
    @Environment(\.skin) private var skin
    let face: SpeedDieFace
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.2)
                .fill(skin.highlight)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
            switch face {
            case .number(let n):
                Text("+\(n)").font(skin.font(size * 0.42, .heavy)).foregroundStyle(.white)
            case .bus:
                Image(systemName: "bus.fill").font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(.white)
            case .bonus:
                Image(systemName: "star.fill").font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
}

enum ActionStyle {
    case primary, secondary, destructive
}

/// Кнопка действия. Доступная основная кнопка мягко «дышит» — так видно, что нажать.
struct ActionButton: View {
    @Environment(\.skin) private var skin
    let title: String
    var systemImage: String? = nil
    var style: ActionStyle = .secondary
    var enabled = true
    let action: () -> Void

    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).lineLimit(1).minimumScaleFactor(0.7)
            }
            .font(skin.font(15, .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: skin.cornerRadius + 4))
            .overlay(
                RoundedRectangle(cornerRadius: skin.cornerRadius + 4)
                    .stroke(style == .secondary ? skin.uiSecondaryText.opacity(0.4) : .clear, lineWidth: 1)
            )
            .shadow(color: glow.opacity(pulse ? 0.7 : 0.15), radius: pulse ? 10 : 3)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onAppear {
            guard style == .primary else { return }
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private var glow: Color { style == .primary && enabled ? skin.accent : .clear }

    private var foreground: Color {
        switch style {
        case .primary: skin.isDark && skin.id == "neon" ? .black : .white
        case .secondary: skin.uiText
        case .destructive: .white
        }
    }

    private var background: Color {
        switch style {
        case .primary: skin.accent
        case .secondary: skin.cellFill.opacity(skin.isDark ? 0.25 : 1)
        case .destructive: skin.danger
        }
    }
}

/// Подложка для панелей.
struct PanelBackground: ViewModifier {
    @Environment(\.skin) private var skin

    func body(content: Content) -> some View {
        content
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: skin.cornerRadius + 6)
                    .fill(skin.isDark ? Color.white.opacity(0.06) : Color.white.opacity(0.7))
            )
    }
}

extension View {
    func panel() -> some View { modifier(PanelBackground()) }
}

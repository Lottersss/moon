import SwiftUI
import TycoonCore

/// Фишка игрока: кружок цвета игрока с символом из скина.
struct TokenView: View {
    @Environment(\.skin) private var skin
    let player: PlayerID
    var size: CGFloat = 22
    var dimmed = false

    var body: some View {
        ZStack {
            Circle().fill(skin.playerColor(player))
            Image(systemName: skin.tokenSymbol(player))
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

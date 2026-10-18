import SwiftUI
import TycoonCore

/// Скин — полный набор оформления: цвета, фишки, кубики, шрифт.
/// Новый скин = новый экземпляр структуры; логика игры о скинах ничего не знает.
struct Skin: Identifiable, Sendable {
    let id: String
    let name: String
    let isDark: Bool

    let background: Color
    let boardFill: Color
    let cellFill: Color
    let cornerFill: Color
    let cellStroke: Color
    /// Текст на клетках доски.
    let text: Color
    let secondaryText: Color
    /// Текст на фоне приложения (панели, журнал) — у тёмных скинов светлый.
    let uiText: Color
    let uiSecondaryText: Color
    let accent: Color
    let highlight: Color
    let danger: Color

    let groupColors: [ColorGroup: Color]
    let playerColors: [Color]
    /// SF Symbols для фишек игроков.
    let tokenSymbols: [String]

    let diceFill: Color
    let dicePip: Color
    let fontDesign: Font.Design
    let cornerRadius: CGFloat
    /// Насколько клетка улицы закрашена цветом группы (0 — белая клетка).
    var groupTint: Double = 0.3
    /// Ценник свободной улицы в цвете группы (как в Monopoly One), иначе серый.
    var groupTags: Bool = false
    /// Купленная клетка закрашивается цветом владельца (0 — нет).
    var ownerTint: Double = 0

    func groupColor(_ group: ColorGroup) -> Color { groupColors[group] ?? accent }

    /// Текст в центре доски: у «Казани» доска тёмная, а клетки светлые.
    var boardText: Color { darkBoard ? uiText : text }
    var boardSecondaryText: Color { darkBoard ? uiSecondaryText : secondaryText }
    /// Тёмный стол при светлых клетках: текст в центре доски должен быть светлым.
    private var darkBoard: Bool { ["kazan", "night", "arena"].contains(id) }

    func playerColor(_ id: PlayerID) -> Color { playerColors[id % playerColors.count] }

    func tokenSymbol(_ id: PlayerID) -> String { tokenSymbols[id % tokenSymbols.count] }

    func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: fontDesign)
    }
}

extension Skin {
    static let all: [Skin] = [.arena, .night, .paper, .neon, .minimal, .kazan]

    static func named(_ id: String) -> Skin { all.first { $0.id == id } ?? .arena }

    /// «Арена» — в духе Monopoly One: тёмный стол, белые клетки с зазорами,
    /// купленная клетка в цвете владельца, ценник всегда в цвете группы, белые звёзды-филиалы.
    static let arena = Skin(
        id: "arena", name: "Арена", isDark: true,
        background: Color(hex: 0x222428),
        boardFill: Color(hex: 0x222428),
        cellFill: .white,
        cornerFill: .white,
        cellStroke: Color(hex: 0x222428),
        text: Color(hex: 0x23262D),
        secondaryText: Color(hex: 0x8A8F99),
        uiText: .white,
        uiSecondaryText: Color(hex: 0xA9AEB8),
        accent: Color(hex: 0x8CCB5E),
        highlight: Color(hex: 0xFFD43B),
        danger: Color(hex: 0xE35D5D),
        groupColors: [
            .brown: Color(hex: 0xC98B5E), .lightBlue: Color(hex: 0x74C6EE),
            .pink: Color(hex: 0xB48AE8), .orange: Color(hex: 0xF2A94E),
            .red: Color(hex: 0xE46D6D), .yellow: Color(hex: 0xE9C14E),
            .green: Color(hex: 0x93CF6E), .darkBlue: Color(hex: 0x5B8DEF),
        ],
        playerColors: [0xE35D5D, 0x4FB3EA, 0x8CCB5E, 0xA07BE0, 0xF0A04B, 0x2EC4B6].map { Color(hex: $0) },
        tokenSymbols: ["crown.fill", "star.fill", "heart.fill", "bolt.fill", "flame.fill", "leaf.fill"],
        diceFill: .white, dicePip: Color(hex: 0x23262D),
        fontDesign: .default, cornerRadius: 6,
        groupTint: 0, groupTags: true, ownerTint: 0.6
    )

    /// «Ночь»: тёмный стол, белые клетки с цветом групп, светлый журнал в центре.
    static let night = Skin(
        id: "night", name: "Ночь", isDark: true,
        background: Color(hex: 0x1F2126),
        boardFill: Color(hex: 0x2A2D33),
        cellFill: .white,
        cornerFill: .white,
        cellStroke: Color(hex: 0x3A3D44),
        text: Color(hex: 0x1E1F22),
        secondaryText: Color(hex: 0x6A6E78),
        uiText: Color(hex: 0xF2F3F5),
        uiSecondaryText: Color(hex: 0x9EA3AD),
        accent: Color(hex: 0x8BC34A),
        highlight: Color(hex: 0xFFC107),
        danger: Color(hex: 0xE53935),
        groupColors: [
            .brown: Color(hex: 0xB07A52), .lightBlue: Color(hex: 0x5BC0EB),
            .pink: Color(hex: 0xC77DFF), .orange: Color(hex: 0xF4A261),
            .red: Color(hex: 0xE5636F), .yellow: Color(hex: 0xF2C94C),
            .green: Color(hex: 0x7BC67B), .darkBlue: Color(hex: 0x4F7DD9),
        ],
        playerColors: [0xE5484D, 0x7CB342, 0x3BA7E5, 0xA374E6, 0xF59E0B, 0x14B8A6].map { Color(hex: $0) },
        tokenSymbols: ["flame.fill", "leaf.fill", "drop.fill", "moon.stars.fill", "sun.max.fill", "bolt.fill"],
        diceFill: .white, dicePip: Color(hex: 0x1E1F22),
        fontDesign: .default, cornerRadius: 6
    )

    /// «Настолка»: тёплая бумага, классические цвета групп.
    static let paper = Skin(
        id: "paper", name: "Настолка", isDark: false,
        background: Color(hex: 0xEDE6D6),
        boardFill: Color(hex: 0xD7E8D2),
        cellFill: Color(hex: 0xFBF7EE),
        cornerFill: Color(hex: 0xF3EBD8),
        cellStroke: Color(hex: 0x3A3326).opacity(0.55),
        text: Color(hex: 0x2B251B),
        secondaryText: Color(hex: 0x6E6455),
        uiText: Color(hex: 0x2B251B),
        uiSecondaryText: Color(hex: 0x6E6455),
        accent: Color(hex: 0xC0392B),
        highlight: Color(hex: 0xF5B700),
        danger: Color(hex: 0xB03A2E),
        groupColors: [
            .brown: Color(hex: 0x8B5A2B), .lightBlue: Color(hex: 0x8FD3F4),
            .pink: Color(hex: 0xD6409F), .orange: Color(hex: 0xF39C12),
            .red: Color(hex: 0xE74C3C), .yellow: Color(hex: 0xF1C40F),
            .green: Color(hex: 0x27AE60), .darkBlue: Color(hex: 0x1F4E9C),
        ],
        playerColors: [0xD35400, 0x2980B9, 0x8E44AD, 0x16A085, 0xC0392B, 0x7F8C8D].map { Color(hex: $0) },
        tokenSymbols: ["car.fill", "airplane", "sailboat.fill", "hare.fill", "crown.fill", "star.fill"],
        diceFill: .white, dicePip: Color(hex: 0x2B251B),
        fontDesign: .serif, cornerRadius: 6
    )

    /// «Неон»: тёмная доска и светящиеся группы.
    static let neon = Skin(
        id: "neon", name: "Неон", isDark: true,
        background: Color(hex: 0x0B0B14),
        boardFill: Color(hex: 0x12121F),
        cellFill: Color(hex: 0x1A1A2E),
        cornerFill: Color(hex: 0x22223A),
        cellStroke: Color(hex: 0x3D3D66),
        text: Color(hex: 0xEDEDFF),
        secondaryText: Color(hex: 0x9A9AC0),
        uiText: Color(hex: 0xEDEDFF),
        uiSecondaryText: Color(hex: 0x9A9AC0),
        accent: Color(hex: 0x00E5FF),
        highlight: Color(hex: 0xFF2BD6),
        danger: Color(hex: 0xFF4D6D),
        groupColors: [
            .brown: Color(hex: 0xB8763E), .lightBlue: Color(hex: 0x4DF3FF),
            .pink: Color(hex: 0xFF4FD8), .orange: Color(hex: 0xFF9F1C),
            .red: Color(hex: 0xFF3B5C), .yellow: Color(hex: 0xFFE14D),
            .green: Color(hex: 0x39FF88), .darkBlue: Color(hex: 0x5C7CFF),
        ],
        playerColors: [0x00E5FF, 0xFF2BD6, 0xFFE14D, 0x39FF88, 0xFF9F1C, 0xB28DFF].map { Color(hex: $0) },
        tokenSymbols: ["bolt.fill", "flame.fill", "sparkles", "moon.stars.fill", "atom", "gamecontroller.fill"],
        diceFill: Color(hex: 0x22223A), dicePip: Color(hex: 0x00E5FF),
        fontDesign: .rounded, cornerRadius: 10,
        groupTint: 0.22
    )

    /// «Минимал»: чистый белый, тонкие линии.
    static let minimal = Skin(
        id: "minimal", name: "Минимал", isDark: false,
        background: Color(hex: 0xF7F7F7),
        boardFill: .white,
        cellFill: .white,
        cornerFill: Color(hex: 0xF0F0F0),
        cellStroke: Color(hex: 0xD0D0D0),
        text: Color(hex: 0x111111),
        secondaryText: Color(hex: 0x777777),
        uiText: Color(hex: 0x111111),
        uiSecondaryText: Color(hex: 0x777777),
        accent: Color(hex: 0x111111),
        highlight: Color(hex: 0x3D7EFF),
        danger: Color(hex: 0xE5484D),
        groupColors: [
            .brown: Color(hex: 0xA1887F), .lightBlue: Color(hex: 0x90CAF9),
            .pink: Color(hex: 0xF48FB1), .orange: Color(hex: 0xFFB74D),
            .red: Color(hex: 0xE57373), .yellow: Color(hex: 0xFFD54F),
            .green: Color(hex: 0x81C784), .darkBlue: Color(hex: 0x7986CB),
        ],
        playerColors: [0x111111, 0x3D7EFF, 0xE5484D, 0x30A46C, 0xF76B15, 0x8E4EC6].map { Color(hex: $0) },
        tokenSymbols: ["circle.fill", "square.fill", "triangle.fill", "diamond.fill", "hexagon.fill", "seal.fill"],
        diceFill: .white, dicePip: Color(hex: 0x111111),
        fontDesign: .default, cornerRadius: 4
    )

    /// «Казань»: зелёный, красный и золото.
    static let kazan = Skin(
        id: "kazan", name: "Казань", isDark: true,
        background: Color(hex: 0x0E3B2E),
        boardFill: Color(hex: 0x145A45),
        cellFill: Color(hex: 0xF6F1E4),
        cornerFill: Color(hex: 0xE9DFC5),
        cellStroke: Color(hex: 0xC9A24A),
        text: Color(hex: 0x1D1A14),
        secondaryText: Color(hex: 0x6B5E40),
        uiText: Color(hex: 0xF6F1E4),
        uiSecondaryText: Color(hex: 0xBFD3C4),
        accent: Color(hex: 0xC9A24A),
        highlight: Color(hex: 0xE53935),
        danger: Color(hex: 0xC62828),
        groupColors: [
            .brown: Color(hex: 0x7B4A24), .lightBlue: Color(hex: 0x4FC3F7),
            .pink: Color(hex: 0xC2185B), .orange: Color(hex: 0xEF6C00),
            .red: Color(hex: 0xC62828), .yellow: Color(hex: 0xF9A825),
            .green: Color(hex: 0x2E7D32), .darkBlue: Color(hex: 0x1A237E),
        ],
        playerColors: [0xE53935, 0x42A5F5, 0xF9A825, 0xBA68C8, 0x26C6DA, 0xA1887F].map { Color(hex: $0) },
        tokenSymbols: ["leaf.fill", "crown.fill", "building.columns.fill", "tram.fill", "shield.fill", "star.circle.fill"],
        diceFill: Color(hex: 0xF6F1E4), dicePip: Color(hex: 0x0E3B2E),
        fontDesign: .serif, cornerRadius: 8
    )
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

// MARK: - Скин в окружении SwiftUI

private struct SkinKey: EnvironmentKey {
    static let defaultValue: Skin = .arena
}

extension EnvironmentValues {
    var skin: Skin {
        get { self[SkinKey.self] }
        set { self[SkinKey.self] = newValue }
    }
}

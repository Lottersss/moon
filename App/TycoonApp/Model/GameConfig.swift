import Foundation
import TycoonCore

enum GameMode: String, CaseIterable, Identifiable, Codable {
    case classic, teams, reshuffle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: "Обычная"
        case .teams: "2×2"
        case .reshuffle: "Перестановка"
        }
    }

    var subtitle: String {
        switch self {
        case .classic: "Каждый сам за себя"
        case .teams: "Две команды по двое, напарники не платят ренту"
        case .reshuffle: "Поля перемешаны, третий кубик"
        }
    }
}

/// Всё, что выбирается на экране новой игры.
struct GameConfig: Codable {
    var mode: GameMode = .classic
    var players: [PlayerSetup] = [
        PlayerSetup(name: "Игрок 1"),
        PlayerSetup(name: "Игрок 2"),
        PlayerSetup(name: "Бот 1", isBot: true),
        PlayerSetup(name: "Бот 2", isBot: true),
    ]
    var maxRounds: Int? = nil
    /// Секунд на действие. `nil` — без таймера.
    var turnSeconds: Int? = 60
    var balancedDice = false
    /// Показывать экран «передайте телефон», когда ход переходит к другому живому игроку.
    var passDevicePrompt = true

    func makeSettings() -> GameSettings {
        var settings = mode == .reshuffle ? GameSettings.reshuffle : GameSettings.monopolyOne
        settings.maxRounds = maxRounds
        settings.diceMode = balancedDice ? .balanced : .random
        return settings
    }

    /// В 2×2 первые двое — команда A, следующие двое — команда B.
    func makePlayers() -> [PlayerSetup] {
        guard mode == .teams else { return players.map { var p = $0; p.team = nil; return p } }
        return players.prefix(4).enumerated().map { index, setup in
            var player = setup
            player.team = index / 2
            return player
        }
    }
}

enum Format {
    /// 15000 → «15 000k».
    static func money(_ value: Int) -> String {
        let digits = String(abs(value))
        var groups: [String] = []
        var end = digits.endIndex
        while end > digits.startIndex {
            let start = digits.index(end, offsetBy: -3, limitedBy: digits.startIndex) ?? digits.startIndex
            groups.insert(String(digits[start..<end]), at: 0)
            end = start
        }
        return (value < 0 ? "−" : "") + groups.joined(separator: "\u{2009}") + "k"
    }

    static func teamName(_ team: Int?) -> String? {
        guard let team else { return nil }
        return "Команда " + (team == 0 ? "A" : "B")
    }
}

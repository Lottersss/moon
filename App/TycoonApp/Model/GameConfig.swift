import Foundation
import TycoonCore

enum GameMode: String, CaseIterable, Identifiable, Codable {
    case classic, teams, reshuffle
    /// 2×2 и «Перестановка» сразу: команды, перемешанные поля и третий кубик.
    case teamsReshuffle = "teams-reshuffle"

    var id: String { rawValue }

    init(teams: Bool, reshuffle: Bool) {
        switch (teams, reshuffle) {
        case (false, false): self = .classic
        case (true, false): self = .teams
        case (false, true): self = .reshuffle
        case (true, true): self = .teamsReshuffle
        }
    }

    /// Две команды по двое.
    var isTeams: Bool { self == .teams || self == .teamsReshuffle }
    /// Перемешанное поле и третий кубик.
    var isReshuffle: Bool { self == .reshuffle || self == .teamsReshuffle }

    var title: String {
        switch self {
        case .classic: "Обычная"
        case .teams: "2×2"
        case .reshuffle: "Перестановка"
        case .teamsReshuffle: "2×2 · Перестановка"
        }
    }

    var subtitle: String {
        switch self {
        case .classic: "Каждый сам за себя"
        case .teams: "Две команды по двое, напарники не платят ренту"
        case .reshuffle: "Поля перемешаны, быстрый кубик с 8-го раунда"
        case .teamsReshuffle: "Команды по двое, поля перемешаны, быстрый кубик с 8-го раунда"
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
    /// Аватары игроков: место → значок аккаунта. `nil` у старых сохранений.
    var avatars: [Int: String]? = nil
    /// Какие аккаунты этого телефона сидят на каких местах (для статистики побед).
    var accounts: [Int: UUID]? = nil
    /// Свои названия полей: id клетки → название.
    var cellNames: [Int: String]? = nil

    /// Классическая доска с названиями, которые игрок задал сам.
    func makeBoard() -> Board {
        guard let names = cellNames, !names.isEmpty else { return .standard }
        return Board(cells: Board.standard.cells.map { cell in
            let custom = names[cell.id]?.trimmingCharacters(in: .whitespaces) ?? ""
            return CellInfo(id: cell.id, name: custom.isEmpty ? cell.name : custom, kind: cell.kind)
        })
    }

    func makeSettings() -> GameSettings {
        var settings = mode.isReshuffle ? GameSettings.reshuffle : GameSettings.monopolyOne
        settings.maxRounds = maxRounds
        settings.diceMode = balancedDice ? .balanced : .random
        return settings
    }

    /// В 2×2 первые двое — команда A, следующие двое — команда B.
    func makePlayers() -> [PlayerSetup] {
        guard mode.isTeams else { return players.map { var p = $0; p.team = nil; return p } }
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

import Foundation
import TycoonCore

/// Незаконченная партия на этом телефоне.
struct SavedGame: Codable {
    let config: GameConfig
    let state: GameState
    let log: [LogEntry]
    let savedAt: Date

    /// Короткое описание для стартового экрана: режим, круг, игроки.
    var summary: String {
        let names = state.turnOrder
            .map { state.players[$0] }
            .filter { !$0.isBankrupt }
            .map(\.name)
            .joined(separator: ", ")
        return "\(config.mode.title) · круг \(state.round) · \(names)"
    }
}

/// Автосохранение партии в файл: после каждого действия и при сворачивании приложения.
enum SaveStore {
    private static var url: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("current-game.json")
    }

    static func save(_ game: SavedGame) {
        guard let data = try? JSONEncoder().encode(game) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> SavedGame? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavedGame.self, from: data)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Постоянный идентификатор этого телефона: по нему хост узнаёт игрока,
/// который вернулся после потери связи.
enum DeviceIdentity {
    static let id: String = {
        let key = "tycoon.deviceID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()
}

import SwiftUI
import TycoonCore

/// Аккаунт игрока на этом телефоне: имя, аватар и статистика.
/// Хранится только на телефоне (сервера нет); по Bluetooth соперники видят имя и аватар.
struct Account: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var avatar: String
    var gamesPlayed = 0
    var wins = 0
    /// Привязка к аккаунту Monopoly One (вход через OAuth). Всё опционально — старые сохранения читаются.
    var monopolyID: Int? = nil
    var monopolyNick: String? = nil
    /// Фото из профиля Monopoly One (ссылка; картинка загружается при показе).
    var avatarURL: String? = nil
    /// Статистика на самом Monopoly One на момент входа.
    var monopolyGames: Int? = nil
    var monopolyWins: Int? = nil

    var isLinked: Bool { monopolyID != nil }

    var winRate: Int { gamesPlayed == 0 ? 0 : wins * 100 / gamesPlayed }

    /// Аватары — значки SF Symbols.
    static let avatars = [
        "moon.stars.fill", "star.fill", "crown.fill", "heart.fill", "bolt.fill", "flame.fill",
        "leaf.fill", "pawprint.fill", "hare.fill", "tortoise.fill", "bird.fill", "fish.fill",
        "cat.fill", "dog.fill", "gamecontroller.fill", "sparkles", "sun.max.fill", "snowflake",
        "music.note", "diamond.fill",
    ]
}

/// Все аккаунты на телефоне. «Основной» — тот, кем вы играете по Bluetooth
/// и кто по умолчанию сидит на первом месте в новой игре.
@MainActor
@Observable
final class AccountStore {
    static let shared = AccountStore()

    private(set) var accounts: [Account] = []
    private(set) var mainID: UUID?

    private static let key = "tycoon.accounts"
    private static let mainKey = "tycoon.mainAccount"

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Account].self, from: data), !saved.isEmpty {
            accounts = saved
            mainID = defaults.string(forKey: Self.mainKey).flatMap(UUID.init(uuidString:)) ?? saved[0].id
        } else {
            // Первый запуск: аккаунт из имени, которое раньше вводили для Bluetooth.
            let name = defaults.string(forKey: "playerName") ?? "Игрок"
            let first = Account(name: name, avatar: Account.avatars[0])
            accounts = [first]
            mainID = first.id
            save()
        }
    }

    var main: Account {
        accounts.first { $0.id == mainID } ?? accounts[0]
    }

    func account(_ id: UUID?) -> Account? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }
    }

    @discardableResult
    func add(name: String, avatar: String) -> Account {
        let account = Account(name: name, avatar: avatar)
        accounts.append(account)
        save()
        return account
    }

    func update(_ account: Account) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = account
        save()
    }

    func delete(_ id: UUID) {
        guard accounts.count > 1 else { return }
        accounts.removeAll { $0.id == id }
        if mainID == id { mainID = accounts[0].id }
        save()
    }

    /// Вход через Monopoly One: аккаунт с этим id обновляется, иначе создаётся новый
    /// (или привязывается нетронутый аккаунт, который создан при первом запуске).
    /// Вошедший становится основным. Токен не хранится — профиль читается один раз.
    @discardableResult
    func signIn(_ profile: MonopolyOne.Profile) -> Account {
        var account: Account
        if let index = accounts.firstIndex(where: { $0.monopolyID == profile.userID }) {
            account = accounts[index]
            link(profile, to: &account)
            accounts[index] = account
        } else if accounts.count == 1, !accounts[0].isLinked, accounts[0].gamesPlayed == 0 {
            account = accounts[0]
            account.name = String(profile.nick.prefix(20))
            link(profile, to: &account)
            accounts[0] = account
        } else {
            account = Account(name: String(profile.nick.prefix(20)), avatar: Account.avatars[0])
            link(profile, to: &account)
            accounts.append(account)
        }
        mainID = account.id
        save()
        return account
    }

    private func link(_ profile: MonopolyOne.Profile, to account: inout Account) {
        account.monopolyID = profile.userID
        account.monopolyNick = profile.nick
        account.avatarURL = profile.avatarURL?.absoluteString
        account.monopolyGames = profile.games
        account.monopolyWins = profile.wins
    }

    func makeMain(_ id: UUID) {
        mainID = id
        save()
    }

    /// Итог партии для аккаунта.
    func record(_ id: UUID, won: Bool) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].gamesPlayed += 1
        if won { accounts[index].wins += 1 }
        save()
    }

    private func save() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(accounts) { defaults.set(data, forKey: Self.key) }
        defaults.set(mainID?.uuidString, forKey: Self.mainKey)
    }
}

/// Свои названия полей. Хранятся на телефоне и применяются к доске новой партии
/// (по Bluetooth — названия хоста, их видят все).
@MainActor
@Observable
final class CellNameStore {
    static let shared = CellNameStore()

    private(set) var names: [Int: String] = [:]
    private static let key = "tycoon.cellNames"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Int: String].self, from: data) {
            names = saved
        }
    }

    /// Название сохраняется как набрано (пробелы обрезаются при создании доски),
    /// иначе в поле ввода нельзя было бы набрать пробел между словами.
    func set(_ name: String, for cell: CellID) {
        let blank = name.trimmingCharacters(in: .whitespaces).isEmpty
        names[cell] = blank ? nil : String(name.prefix(24))
        save()
    }

    func reset() {
        names = [:]
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(names) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

// MARK: - Аватары игроков в окружении SwiftUI

private struct AvatarsKey: EnvironmentKey {
    static let defaultValue: [PlayerID: String] = [:]
}

extension EnvironmentValues {
    /// Аватары игроков партии: место → значок. Если нет — фишка из скина.
    var avatars: [PlayerID: String] {
        get { self[AvatarsKey.self] }
        set { self[AvatarsKey.self] = newValue }
    }
}

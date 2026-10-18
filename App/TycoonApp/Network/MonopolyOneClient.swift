import Foundation
import TycoonCore

/// ID приложения, зарегистрированного на Monopoly One. Его выдаёт Monopoly One;
/// `app_secret` приложению не нужен (и класть его в приложение нельзя).
enum MonopolyOneConfig {
    /// Если ID известен заранее (например, для App Store), впишите его сюда.
    static let builtInAppID = 0

    private static let key = "monopolyOneAppID"

    /// Вписанный в приложении ID главнее зашитого.
    static var appID: Int {
        let saved = UserDefaults.standard.integer(forKey: key)
        return saved > 0 ? saved : builtInAppID
    }

    static func setAppID(_ id: Int) {
        UserDefaults.standard.set(id, forKey: key)
    }
}

/// Читает профиль по ключу доступа. Токен уходит только на monopoly-one.com,
/// сессия «эфемерная»: ни кеша, ни куки на диск не пишутся.
enum MonopolyOneClient {
    static func fetchProfile(accessToken: String) async throws -> MonopolyOne.Profile {
        guard let url = MonopolyOne.profileURL(accessToken: accessToken) else { throw MonopolyOneError.badResponse }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            throw MonopolyOneError.unreachable
        }
        return try MonopolyOne.parseProfile(data)
    }
}

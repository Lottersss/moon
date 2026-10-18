import Foundation

/// Вход через аккаунт Monopoly One по их OAuth (docs.mnpl.one/oauth/intro).
///
/// У приложения нет своего сервера, поэтому используется поток для приложений
/// (`response_type=access_token`): токен приходит прямо в приложение. Обмен кода
/// (`oauth.exchangeCode`) нужен серверам — ему требуется `app_secret`, а секрет
/// нельзя класть в приложение: его достанет любой.
///
/// Запрашиваются минимальные права (`scope=0`): токен нужен один раз, чтобы прочитать
/// профиль через `users.get`. Потом он выбрасывается и нигде не хранится.
/// Здесь только чистая логика (без сети), поэтому она проверяется тестами.
public enum MonopolyOne {
    public static let host = "monopoly-one.com"

    /// Страница, где пользователь разрешает доступ.
    /// `redirect_uri=blank` — специальное значение: после решения открывается
    /// `https://monopoly-one.com/oauth/blank`, а токен лежит в адресе после `#`.
    public static func authorizeURL(appID: Int, scope: Int = 0) -> URL? {
        guard appID > 0 else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/oauth"
        components.queryItems = [
            URLQueryItem(name: "app_id", value: String(appID)),
            URLQueryItem(name: "scope", value: String(scope)),
            URLQueryItem(name: "redirect_uri", value: "blank"),
            URLQueryItem(name: "response_type", value: "access_token"),
        ]
        return components.url
    }

    /// Это итоговая страница входа (`.../oauth/blank`)? Хост проверяется точно:
    /// `monopoly-one.com.evil.example` не подходит.
    public static func isRedirect(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let urlHost = url.host?.lowercased(),
              urlHost == host || urlHost == "www." + host else { return false }
        return url.path == "/oauth/blank" || url.path == "/oauth/blank/"
    }

    /// Разбирает адрес итоговой страницы: токен (или причину отказа) из части после `#`.
    public static func parseRedirect(_ url: URL) -> Result<Authorization, MonopolyOneError> {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // Данные приходят после `#`; на случай ответа через `?` читаем и его.
        let fields = formFields(components?.percentEncodedFragment)
            .merging(formFields(components?.percentEncodedQuery)) { fromFragment, _ in fromFragment }
        if let error = fields["error"], !error.isEmpty {
            let text = (fields["error_description"] ?? error).replacingOccurrences(of: "+", with: " ")
            return .failure(.denied(text))
        }
        guard let token = fields["access_token"], !token.isEmpty else { return .failure(.noToken) }
        return .success(Authorization(accessToken: token,
                                      userID: fields["user_id"].flatMap { Int($0) },
                                      expiresIn: fields["expires_in"].flatMap { Int($0) }))
    }

    /// Запрос профиля владельца токена: `users.get` без `user_id` отвечает про самого пользователя.
    public static func profileURL(accessToken: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let token = accessToken.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/users.get"
        // Кодируем сами: URLComponents оставляет «+» как есть, а сервер прочтёт его как пробел.
        components.percentEncodedQuery = "access_token=" + token
        return components.url
    }

    /// Разбирает ответ `users.get`: `{"code":0,"data":[{...User...}]}`.
    public static func parseProfile(_ data: Data) throws -> Profile {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MonopolyOneError.badResponse
        }
        let code = integer(root["code"]) ?? -1
        guard code == 0 else {
            throw MonopolyOneError.api(code: code, message: (root["message"] ?? root["error"]) as? String)
        }
        // Документация обещает список; одиночный объект тоже принимаем.
        let user = (root["data"] as? [[String: Any]])?.first ?? (root["data"] as? [String: Any])
        guard let user,
              let id = integer(user["user_id"]),
              let nick = (user["nick"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !nick.isEmpty else {
            throw MonopolyOneError.noProfile
        }
        return Profile(userID: id,
                       nick: nick,
                       avatarURL: avatar(user["avatar"] as? String),
                       games: integer(user["games"]),
                       wins: integer(user["games_wins"]))
    }

    // MARK: - Типы

    /// Что пришло после входа. Токен живёт сутки и привязан к IP; нужен только чтобы прочитать профиль.
    public struct Authorization: Equatable, Sendable {
        public var accessToken: String
        public var userID: Int?
        public var expiresIn: Int?

        public init(accessToken: String, userID: Int? = nil, expiresIn: Int? = nil) {
            self.accessToken = accessToken
            self.userID = userID
            self.expiresIn = expiresIn
        }
    }

    /// Публичная часть профиля Monopoly One.
    public struct Profile: Equatable, Sendable, Codable {
        public var userID: Int
        public var nick: String
        public var avatarURL: URL?
        /// Сыграно матчей на Monopoly One.
        public var games: Int?
        /// Побед на Monopoly One.
        public var wins: Int?

        public init(userID: Int, nick: String, avatarURL: URL? = nil, games: Int? = nil, wins: Int? = nil) {
            self.userID = userID
            self.nick = nick
            self.avatarURL = avatarURL
            self.games = games
            self.wins = wins
        }
    }

    // MARK: - Разбор

    /// `a=1&b=%D0%B0` → словарь. Плюс не считаем пробелом: токен — не текст.
    static func formFields(_ encoded: String?) -> [String: String] {
        guard let encoded, !encoded.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for pair in encoded.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawKey = parts.first, let key = String(rawKey).removingPercentEncoding else { continue }
            let value = parts.count > 1 ? String(parts[1]).removingPercentEncoding ?? "" : ""
            result[key] = value
        }
        return result
    }

    /// Число из JSON: целое, дробное с нулевой дробью или строка из цифр.
    static func integer(_ value: Any?) -> Int? {
        switch value {
        case let number as Int: return number
        case let number as Double where number == number.rounded() && abs(number) < 1e15: return Int(number)
        case let text as String: return Int(text)
        default: return nil
        }
    }

    /// Ссылка на аватар. Только https (без него iOS не загрузит картинку).
    static func avatar(_ raw: String?) -> URL? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasPrefix("//") {
            text = "https:" + text
        } else if text.hasPrefix("/") {
            text = "https://" + host + text
        } else if text.hasPrefix("http://") {
            text = "https://" + text.dropFirst("http://".count)
        }
        guard let url = URL(string: text), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}

public enum MonopolyOneError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Пользователь отказал в доступе или Monopoly One вернул ошибку входа.
    case denied(String)
    /// На итоговой странице нет токена.
    case noToken
    /// Метод API ответил ошибкой (`code` не 0).
    case api(code: Int, message: String?)
    /// Ответ не похож на ответ API.
    case badResponse
    /// В ответе нет профиля.
    case noProfile
    /// Страница или сервер недоступны.
    case unreachable

    public var description: String {
        switch self {
        case .denied(let reason): "Вход отменён: \(reason)"
        case .noToken: "Monopoly One не вернул ключ доступа. Попробуйте ещё раз."
        case .api(let code, let message):
            "Monopoly One ответил ошибкой \(code)" + (message.map { ": \($0)" } ?? "")
        case .badResponse: "Непонятный ответ от Monopoly One"
        case .noProfile: "Профиль не найден"
        case .unreachable: "Нет связи с Monopoly One. Проверьте интернет."
        }
    }
}

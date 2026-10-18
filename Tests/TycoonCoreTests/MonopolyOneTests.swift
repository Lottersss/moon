import Foundation
import Testing
@testable import TycoonCore

// Вход через Monopoly One: адрес входа, разбор ответа после входа и профиля (users.get).

@Test func authorizeURLUsesClientFlowWithMinimalScope() throws {
    let url = try #require(MonopolyOne.authorizeURL(appID: 42))
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
    #expect(url.host == "monopoly-one.com")
    #expect(url.path == "/oauth")
    #expect(value("app_id") == "42")
    #expect(value("response_type") == "access_token")
    #expect(value("redirect_uri") == "blank")
    #expect(value("scope") == "0")
    // Секрет приложения в адрес попасть не может: его нет в API функции.
    #expect(!url.absoluteString.contains("secret"))
}

@Test func authorizeURLNeedsAnAppID() {
    #expect(MonopolyOne.authorizeURL(appID: 0) == nil)
    #expect(MonopolyOne.authorizeURL(appID: -3) == nil)
}

@Test func redirectIsRecognisedOnlyOnTheRealHost() throws {
    let real = try #require(URL(string: "https://monopoly-one.com/oauth/blank#access_token=a"))
    let slash = try #require(URL(string: "https://monopoly-one.com/oauth/blank/#access_token=a"))
    #expect(MonopolyOne.isRedirect(real))
    #expect(MonopolyOne.isRedirect(slash))
    for text in ["https://monopoly-one.com/oauth?app_id=1",
                 "https://monopoly-one.com.evil.example/oauth/blank#access_token=a",
                 "https://evil.example/oauth/blank#access_token=a",
                 "http://monopoly-one.com/oauth/blank#access_token=a",
                 "https://monopoly-one.com/oauth/blank-not"] {
        let url = try #require(URL(string: text))
        #expect(!MonopolyOne.isRedirect(url), "\(text)")
    }
}

@Test func redirectGivesTokenFromTheFragment() throws {
    let url = try #require(URL(string: "https://monopoly-one.com/oauth/blank#access_token=y3NRX%2Bpec&user_id=1234567890&expires_in=86400"))
    let result = MonopolyOne.parseRedirect(url)
    #expect(result == .success(.init(accessToken: "y3NRX+pec", userID: 1_234_567_890, expiresIn: 86_400)))
}

@Test func redirectWithRefusalReportsTheReason() throws {
    let url = try #require(URL(string: "https://monopoly-one.com/oauth/blank#error=access_denied&error_description=User+denied+access"))
    #expect(MonopolyOne.parseRedirect(url) == .failure(.denied("User denied access")))
}

@Test func redirectWithoutTokenFails() throws {
    let url = try #require(URL(string: "https://monopoly-one.com/oauth/blank"))
    #expect(MonopolyOne.parseRedirect(url) == .failure(.noToken))
    let empty = try #require(URL(string: "https://monopoly-one.com/oauth/blank#access_token="))
    #expect(MonopolyOne.parseRedirect(empty) == .failure(.noToken))
}

@Test func profileRequestEncodesTheTokenSafely() throws {
    let url = try #require(MonopolyOne.profileURL(accessToken: "a+b/c d"))
    #expect(url.host == "monopoly-one.com")
    #expect(url.path == "/api/users.get")
    #expect(url.absoluteString.hasSuffix("?access_token=a%2Bb%2Fc%20d"))
}

@Test func profileParsesUsersGetAnswer() throws {
    let json = """
    {"code":0,"data":[{"user_id":1234567890,"domain":"nick","approved":1,"nick":" Лунатик ",
    "avatar":"//cdn.monopoly-one.com/a.png","online":1,"games":120,"games_wins":45,"xp":10,"xp_level":3}]}
    """
    let profile = try MonopolyOne.parseProfile(Data(json.utf8))
    #expect(profile == .init(userID: 1_234_567_890, nick: "Лунатик",
                             avatarURL: URL(string: "https://cdn.monopoly-one.com/a.png"),
                             games: 120, wins: 45))
}

@Test func shortProfileHasNoStatistics() throws {
    let json = #"{"code":0,"data":[{"user_id":7,"nick":"Short","avatar":"/img/7.png"}]}"#
    let profile = try MonopolyOne.parseProfile(Data(json.utf8))
    #expect(profile.games == nil && profile.wins == nil)
    #expect(profile.avatarURL?.absoluteString == "https://monopoly-one.com/img/7.png")
}

@Test func profileErrorsAreReported() {
    #expect(throws: MonopolyOneError.api(code: 3, message: "bad token")) {
        try MonopolyOne.parseProfile(Data(#"{"code":3,"message":"bad token"}"#.utf8))
    }
    #expect(throws: MonopolyOneError.badResponse) { try MonopolyOne.parseProfile(Data("<html>".utf8)) }
    #expect(throws: MonopolyOneError.noProfile) { try MonopolyOne.parseProfile(Data(#"{"code":0,"data":[]}"#.utf8)) }
    #expect(throws: MonopolyOneError.noProfile) {
        try MonopolyOne.parseProfile(Data(#"{"code":0,"data":[{"user_id":5,"nick":"  "}]}"#.utf8))
    }
}

@Test func onlyHTTPSAvatarsAreAccepted() {
    #expect(MonopolyOne.avatar("http://x.example/a.png")?.absoluteString == "https://x.example/a.png")
    #expect(MonopolyOne.avatar("javascript:alert(1)") == nil)
    #expect(MonopolyOne.avatar("file:///etc/passwd") == nil)
    #expect(MonopolyOne.avatar("") == nil)
    #expect(MonopolyOne.avatar(nil) == nil)
}

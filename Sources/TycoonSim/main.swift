// Симулятор баланса: прогоняет тысячи партий бот против бота и печатает статистику.
// Примеры:
//   swift run -c release tycoon-sim --games 10000 --players 4
//   swift run -c release tycoon-sim --mode reshuffle --games 10000
//   swift run -c release tycoon-sim --mode 2x2 --games 10000

import TycoonCore

// Без Foundation: симулятор собирается любым тулчейном Swift.

func fixed(_ value: Double, _ digits: Int) -> String {
    var factor = 1.0
    for _ in 0..<digits { factor *= 10 }
    let rounded = (value * factor).rounded() / factor
    var text = String(rounded)
    if digits == 0 { return String(Int(rounded)) }
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    var decimals = parts.count > 1 ? String(parts[1].prefix(digits)) : ""
    while decimals.count < digits { decimals += "0" }
    text = String(parts[0]) + "." + decimals
    return text
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

func leftPad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
}

// MARK: - Аргументы

enum Mode: String {
    case classic, reshuffle
    case teams = "2x2"
    case teamsReshuffle = "2x2-reshuffle"

    var isTeams: Bool { self == .teams || self == .teamsReshuffle }
    var isReshuffle: Bool { self == .reshuffle || self == .teamsReshuffle }
}

var games = 2_000
var playerCount = 4
var seed: UInt64 = 1
var rounds: Int? = 150
var diceMode = DiceMode.random
var mode = Mode.classic

let usage = "Параметры: --mode classic|reshuffle|2x2|2x2-reshuffle --games N --players 2..6 --seed N --rounds N|none --dice random|balanced"
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let key = arguments.removeFirst()
    let value = arguments.isEmpty ? "" : arguments.removeFirst()
    switch key {
    case "--mode": mode = Mode(rawValue: value) ?? mode
    case "--games": games = Int(value) ?? games
    case "--players": playerCount = min(max(Int(value) ?? playerCount, 2), 6)
    case "--seed": seed = UInt64(value) ?? seed
    case "--rounds": rounds = value == "none" ? nil : (Int(value) ?? 150)
    case "--dice": diceMode = DiceMode(rawValue: value) ?? diceMode
    default:
        print("Неизвестный параметр \(key). \(usage)")
        fatalError("неверные параметры")
    }
}
if mode.isTeams { playerCount = 4 }

var settings = mode.isReshuffle ? GameSettings.reshuffle : GameSettings.monopolyOne
settings.maxRounds = rounds
settings.diceMode = diceMode

// MARK: - Прогон

var winsBySeat = Array(repeating: 0, count: playerCount)
var firstTeamWins = 0
var draws = 0
var endedByLimit = 0
var aborted = 0
var totalRounds = 0
var errorCount = 0
var firstErrors: [String] = []
var landings: [String: Int] = [:]
/// Какая монополия собрана в партии первой и выиграл ли её владелец.
var firstMonopolyCount: [ColorGroup: Int] = [:]
var firstMonopolyWins: [ColorGroup: Int] = [:]
let bot = SimpleBot()

let clock = ContinuousClock()
let started = clock.now
let setups = (0..<playerCount).map { index in
    PlayerSetup(name: "Бот \(index + 1)", isBot: true, team: mode.isTeams ? index / 2 : nil)
}

for game in 0..<games {
    var state = GameState(players: setups, settings: settings, seed: seed &+ UInt64(game))
    let board = state.board
    var events: [GameEvent] = []
    var firstMonopoly: (group: ColorGroup, owner: PlayerID)?
    var steps = 0
    while let actor = state.activePlayer, steps < 200_000 {
        steps += 1
        let action = bot.decide(state.publicView, as: actor)
        do {
            events += try state.apply(action, by: actor)
        } catch {
            errorCount += 1
            if firstErrors.count < 5 { firstErrors.append("партия \(game): \(action) → \(error)") }
            let fallback = BotRunner.fallbackAction(for: state, actor: actor)
            guard let fallbackEvents = try? state.apply(fallback, by: actor) else { break }
            events += fallbackEvents
        }
        if firstMonopoly == nil {
            for group in ColorGroup.allCases {
                if let owner = board.cells(in: group).first.flatMap({ state.cells[$0].owner }),
                   state.ownsFullGroup(owner, group) {
                    firstMonopoly = (group, owner)
                    break
                }
            }
        }
    }

    func landingKey(_ cell: CellID) -> String {
        mode.isReshuffle ? board.cells[cell].name : "\(cell). \(board.cells[cell].name)"
    }
    for event in events {
        switch event {
        case .moved(_, _, let to, _): landings[landingKey(to), default: 0] += 1
        case .sentToJail: landings[landingKey(board.jailCell), default: 0] += 1
        case .gameOver(_, _, let byLimit): if byLimit { endedByLimit += 1 }
        default: break
        }
    }

    guard case .gameOver(let winner) = state.phase else {
        aborted += 1
        continue
    }
    totalRounds += state.round
    if let winner, let seat = state.turnOrder.firstIndex(of: winner) {
        winsBySeat[seat] += 1
        if mode.isTeams && state.players[winner].team == state.players[state.turnOrder[0]].team {
            firstTeamWins += 1
        }
    } else {
        draws += 1
    }

    if let first = firstMonopoly {
        firstMonopolyCount[first.group, default: 0] += 1
        let ownerWon = winner.map { $0 == first.owner || state.areTeammates($0, first.owner) } ?? false
        if ownerWon { firstMonopolyWins[first.group, default: 0] += 1 }
    }
}

// MARK: - Отчёт

func percent(_ part: Int, _ whole: Int) -> String {
    guard whole > 0 else { return "—" }
    return leftPad(fixed(Double(part) * 100 / Double(whole), 1), 5) + "%"
}

/// Полуширина 95% доверительного интервала для доли.
func margin(_ part: Int, _ whole: Int) -> String {
    guard whole > 0 else { return "" }
    let p = Double(part) / Double(whole)
    return "± " + fixed(1.96 * (p * (1 - p) / Double(whole)).squareRoot() * 100, 1) + "%"
}

let finished = games - aborted
let decided = finished - draws
let roundsLabel = rounds.map { String($0) } ?? "нет"
print("""
Режим: \(mode.rawValue), партий: \(games), игроков: \(playerCount), кубики: \(diceMode.rawValue), лимит кругов: \(roundsLabel)
Время: \(started.duration(to: clock.now))
Завершено: \(finished), прервано: \(aborted), по лимиту кругов: \(endedByLimit), ничьих: \(draws)
Средняя длина партии: \(finished > 0 ? fixed(Double(totalRounds) / Double(finished), 1) : "—") кругов
Ошибок движка при ходах ботов: \(errorCount)
""")

if mode.isTeams {
    print("Команда, которая ходит первой, победила: \(percent(firstTeamWins, decided))  \(margin(firstTeamWins, decided))  (честно ≈ 50%)")
} else {
    print("Победы по месту за столом (честно ≈ \(fixed(100 / Double(playerCount), 1))% у каждого):")
    for seat in 0..<playerCount {
        print("  \(seat + 1)-й ходит:  \(percent(winsBySeat[seat], decided))  \(margin(winsBySeat[seat], decided))")
    }
}

print("\nПервая собранная монополия: как часто она и как часто её владелец побеждает:")
for group in ColorGroup.allCases {
    let count = firstMonopolyCount[group, default: 0]
    let title = pad(group.title, 12)
    print("  \(title) первая в \(percent(count, finished)) партий, владелец победил в \(percent(firstMonopolyWins[group, default: 0], count))")
}

let totalLandings = landings.values.reduce(0, +)
print("\nСамые посещаемые клетки:")
for (name, count) in landings.sorted(by: { $0.value > $1.value }).prefix(10) {
    print("  \(pad(name, 26)) \(percent(count, totalLandings))")
}

if !firstErrors.isEmpty {
    print("\nПервые ошибки:")
    firstErrors.forEach { print("  \($0)") }
}

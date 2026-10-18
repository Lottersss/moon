public enum DeckKind: String, Codable, Sendable, CaseIterable {
    case chance
    case communityChest

    public var title: String {
        switch self {
        case .chance: "Шанс"
        case .communityChest: "Общественная казна"
        }
    }
}

public enum CardEffect: Codable, Sendable, Equatable {
    case moveTo(CellID)
    case moveBy(Int)
    /// К ближайшему вокзалу; если он чужой — двойная рента.
    case moveToNearestTransport
    /// К ближайшему предприятию; если оно чужое — рента по максимальному множителю.
    case moveToNearestUtility
    case receive(Int)
    case pay(Int)
    case payEachPlayer(Int)
    case repairs(perBranch: Int, perHotel: Int)
    case goToJail
    case getOutOfJail
}

public struct Card: Codable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let text: String
    public let effect: CardEffect

    public init(id: Int, text: String, effect: CardEffect) {
        self.id = id
        self.text = text
        self.effect = effect
    }

    /// Для «Перестановки»: карточка ведёт на ту же улицу, где бы она ни оказалась.
    func remapped(_ newIDs: [CellID]) -> Card {
        guard case .moveTo(let target) = effect else { return self }
        return Card(id: id, text: text, effect: .moveTo(newIDs[target]))
    }
}

/// Карточки — это колоды, а не случайный выбор при каждом попадании:
/// за цикл выпадает каждая карта, поэтому ни у кого не бывает серии одинаковых штрафов.
public enum ChanceDeck {
    public static let standard: [Card] = [
        Card(id: 0, text: "Отправляйтесь на Старт", effect: .moveTo(0)),
        Card(id: 1, text: "Летите в «Взлёт»", effect: .moveTo(24)),
        Card(id: 2, text: "Загляните в «Чирик»", effect: .moveTo(11)),
        Card(id: 3, text: "Отправляйтесь к ближайшему автоконцерну. Если он чужой — заплатите двойную ренту", effect: .moveToNearestTransport),
        Card(id: 4, text: "Отправляйтесь к ближайшему автоконцерну. Если он чужой — заплатите двойную ренту", effect: .moveToNearestTransport),
        Card(id: 5, text: "Отправляйтесь к ближайшей игровой студии. Если она чужая — заплатите 100 × сумму кубиков", effect: .moveToNearestUtility),
        Card(id: 6, text: "Банк выплачивает вам дивиденды: 500k", effect: .receive(500)),
        Card(id: 7, text: "Бесплатное освобождение из тюрьмы. Сохраните карточку", effect: .getOutOfJail),
        Card(id: 8, text: "Вернитесь на 3 клетки назад", effect: .moveBy(-3)),
        Card(id: 9, text: "Отправляйтесь в тюрьму", effect: .goToJail),
        Card(id: 10, text: "Капитальный ремонт: 250k за каждый дом, 1 000k за каждый отель", effect: .repairs(perBranch: 250, perHotel: 1_000)),
        Card(id: 11, text: "Штраф за превышение скорости: 150k", effect: .pay(150)),
        Card(id: 12, text: "Тест-драйв в «Турбо Моторс»", effect: .moveTo(5)),
        Card(id: 13, text: "Отправляйтесь в «Нейрон»", effect: .moveTo(39)),
        Card(id: 14, text: "Вас избрали председателем: заплатите каждому игроку 500k", effect: .payEachPlayer(500)),
        Card(id: 15, text: "Срок вашего кредита истёк: получите 1 500k", effect: .receive(1_500)),
    ]
}

public enum CommunityChestDeck {
    public static let standard: [Card] = [
        Card(id: 0, text: "Отправляйтесь на Старт", effect: .moveTo(0)),
        Card(id: 1, text: "Ошибка банка в вашу пользу: получите 2 000k", effect: .receive(2_000)),
        Card(id: 2, text: "Оплатите услуги врача: 500k", effect: .pay(500)),
        Card(id: 3, text: "Продажа акций: получите 500k", effect: .receive(500)),
        Card(id: 4, text: "Бесплатное освобождение из тюрьмы. Сохраните карточку", effect: .getOutOfJail),
        Card(id: 5, text: "Отправляйтесь в тюрьму", effect: .goToJail),
        Card(id: 6, text: "Отпускной фонд: получите 1 000k", effect: .receive(1_000)),
        Card(id: 7, text: "Возврат подоходного налога: 200k", effect: .receive(200)),
        Card(id: 8, text: "Выигрыш в лотерею: получите 1 000k", effect: .receive(1_000)),
        Card(id: 9, text: "Страховка жизни: получите 1 000k", effect: .receive(1_000)),
        Card(id: 10, text: "Оплатите лечение: 1 000k", effect: .pay(1_000)),
        Card(id: 11, text: "Оплатите обучение: 500k", effect: .pay(500)),
        Card(id: 12, text: "Гонорар за консультацию: 250k", effect: .receive(250)),
        Card(id: 13, text: "Ремонт улиц: 400k за каждый дом, 1 150k за каждый отель", effect: .repairs(perBranch: 400, perHotel: 1_150)),
        Card(id: 14, text: "Второе место на конкурсе красоты: 100k", effect: .receive(100)),
        Card(id: 15, text: "Вы получили наследство: 1 000k", effect: .receive(1_000)),
    ]
}

/// Состояние колоды. Скрыто от ботов и UI других игроков.
struct DeckState: Codable, Sendable, Equatable {
    var drawPile: [Int]
    var discard: [Int]
}

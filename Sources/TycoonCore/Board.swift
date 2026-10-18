public typealias CellID = Int

/// Группы фирм по отраслям (как в Monopoly One). Внутренние имена — цвета классической доски.
public enum ColorGroup: String, Codable, Sendable, CaseIterable {
    case brown, lightBlue, pink, orange, red, yellow, green, darkBlue

    public var title: String {
        switch self {
        case .brown: "Парфюмерия"
        case .lightBlue: "Одежда"
        case .pink: "Соцсети"
        case .orange: "Напитки"
        case .red: "Авиалинии"
        case .yellow: "Рестораны"
        case .green: "Отели"
        case .darkBlue: "Электроника"
        }
    }
}

public enum CellKind: Codable, Sendable, Equatable {
    case start
    /// Улица. `rents[0]` — рента без построек, `rents[1...5]` — с 1–4 домами и отелем.
    case company(group: ColorGroup, price: Int, rents: [Int], branchCost: Int)
    /// Вокзал: рента растёт с числом вокзалов у владельца.
    case transport(price: Int)
    /// Электростанция и Водопровод: рента = сумма кубиков × множитель.
    case utility(price: Int)
    case chance
    case communityChest
    case tax(amount: Int)
    case jail
    case parking
    /// Джекпот из Monopoly One. На классической доске его нет, но клетку можно добавить.
    case jackpot
    case goToJail

    public var isTransport: Bool {
        switch self {
        case .transport: true
        default: false
        }
    }

    public var isUtility: Bool {
        switch self {
        case .utility: true
        default: false
        }
    }
}

public struct CellInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: CellID
    public let name: String
    public let kind: CellKind

    public init(id: CellID, name: String, kind: CellKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    public var price: Int? {
        switch kind {
        case .company(_, let price, _, _), .transport(let price), .utility(let price): price
        default: nil
        }
    }

    public var branchCost: Int? {
        switch kind {
        case .company(_, _, _, let cost): cost
        default: nil
        }
    }

    public var group: ColorGroup? {
        switch kind {
        case .company(let group, _, _, _): group
        default: nil
        }
    }

    public var isPurchasable: Bool { price != nil }
}

public struct Board: Codable, Sendable, Equatable {
    public let cells: [CellInfo]
    public let jailCell: CellID
    public let transportCells: [CellID]
    public let utilityCells: [CellID]
    private let groupIndex: [ColorGroup: [CellID]]

    /// 4 дома + отель.
    public static let maxBranches = 5
    public static let transportRents = [250, 500, 1_000, 2_000]
    public static let utilityMultipliers = [40, 100]

    public init(cells: [CellInfo]) {
        precondition(cells.enumerated().allSatisfy { $0.offset == $0.element.id },
                     "id клетки должен совпадать с её индексом")
        self.cells = cells
        self.jailCell = cells.firstIndex { $0.kind == .jail } ?? 0
        self.transportCells = cells.filter { $0.kind.isTransport }.map(\.id)
        self.utilityCells = cells.filter { $0.kind.isUtility }.map(\.id)
        var index: [ColorGroup: [CellID]] = [:]
        for cell in cells {
            if let group = cell.group { index[group, default: []].append(cell.id) }
        }
        self.groupIndex = index
    }

    public var count: Int { cells.count }

    public func cells(in group: ColorGroup) -> [CellID] {
        groupIndex[group] ?? []
    }

    /// Угловые клетки (Старт, Тюрьма, Парковка, «В тюрьму») — их «Перестановка» не трогает.
    public var cornerCells: Set<CellID> {
        let side = count / 4
        return [0, side, side * 2, side * 3]
    }

    /// Режим «Перестановка»: все клетки, кроме угловых, встают в случайном порядке.
    /// `newIDs[старый id] = новый id` — нужен, чтобы карточки вели на те же улицы.
    public func rearranged<G: RandomNumberGenerator>(using generator: inout G) -> (board: Board, newIDs: [CellID]) {
        let corners = cornerCells
        let movable = cells.indices.filter { !corners.contains($0) }
        let shuffled = movable.shuffled(using: &generator)

        var newIDs = Array(cells.indices)
        for (slot, oldID) in zip(movable, shuffled) { newIDs[oldID] = slot }

        var newCells = cells
        for oldID in cells.indices {
            let newID = newIDs[oldID]
            newCells[newID] = CellInfo(id: newID, name: cells[oldID].name, kind: cells[oldID].kind)
        }
        return (Board(cells: newCells), newIDs)
    }
}

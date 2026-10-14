import SwiftUI
import TycoonCore

/// Геометрия квадратной доски: углы и по `side - 1` клеток на каждой стороне.
/// Старт — правый нижний угол, движение против часовой стрелки, как на настоящей доске.
struct BoardLayout {
    let size: CGFloat
    let count: Int

    var side: Int { count / 4 }
    var corner: CGFloat { size * 0.14 }
    var short: CGFloat { (size - 2 * corner) / CGFloat(side - 1) }

    enum Edge { case bottom, left, top, right, corner }

    func edge(of index: Int) -> Edge {
        if index % side == 0 { return .corner }
        switch index / side {
        case 0: return .bottom
        case 1: return .left
        case 2: return .top
        default: return .right
        }
    }

    func rect(for index: Int) -> CGRect {
        let k = CGFloat(index % side)
        switch index / side {
        case 0:
            if index % side == 0 { return CGRect(x: size - corner, y: size - corner, width: corner, height: corner) }
            return CGRect(x: size - corner - k * short, y: size - corner, width: short, height: corner)
        case 1:
            if index % side == 0 { return CGRect(x: 0, y: size - corner, width: corner, height: corner) }
            return CGRect(x: 0, y: size - corner - k * short, width: corner, height: short)
        case 2:
            if index % side == 0 { return CGRect(x: 0, y: 0, width: corner, height: corner) }
            return CGRect(x: corner + (k - 1) * short, y: 0, width: short, height: corner)
        default:
            if index % side == 0 { return CGRect(x: size - corner, y: 0, width: corner, height: corner) }
            return CGRect(x: size - corner, y: corner + (k - 1) * short, width: corner, height: short)
        }
    }

    /// Место фишки внутри клетки: фишки нескольких игроков не перекрывают друг друга.
    func tokenCenter(cell: Int, slot: Int, of total: Int) -> CGPoint {
        let r = rect(for: cell)
        guard total > 1 else { return CGPoint(x: r.midX, y: r.midY) }
        let columns = 2
        let rows = (total + 1) / 2
        let col = CGFloat(slot % columns)
        let row = CGFloat(slot / columns)
        let dx = r.width / CGFloat(columns + 1)
        let dy = r.height / CGFloat(rows + 1)
        return CGPoint(x: r.minX + dx * (col + 1), y: r.minY + dy * (row + 1))
    }
}

struct BoardView: View {
    @Environment(\.skin) private var skin
    let model: GameViewModel
    var onSelectCell: (CellID) -> Void

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let layout = BoardLayout(size: size, count: model.state.board.count)
            let highlighted = model.highlightedCells
            let state = model.state

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: skin.cornerRadius + 4)
                    .fill(skin.boardFill)
                    .frame(width: size, height: size)

                ForEach(state.board.cells) { info in
                    let rect = layout.rect(for: info.id)
                    CellView(info: info,
                             ownership: state.cells[info.id],
                             edge: layout.edge(of: info.id),
                             unit: layout.short,
                             highlighted: highlighted.contains(info.id),
                             isCurrent: state.players[state.currentPlayerID].position == info.id,
                             tag: tagText(info, state: state))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .onTapGesture { onSelectCell(info.id) }
                }

                BoardCenterView(model: model)
                    .frame(width: size - 2 * layout.corner - 8, height: size - 2 * layout.corner - 8)
                    .position(x: size / 2, y: size / 2)

                tokens(layout: layout, state: state)
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// Ценник: у свободной улицы — цена, у купленной — рента, у заложенной — 0k.
    private func tagText(_ info: CellInfo, state: GameState) -> String? {
        guard let price = info.price else { return nil }
        let own = state.cells[info.id]
        guard let owner = own.owner else { return Format.money(price) }
        if own.isMortgaged { return Format.money(0) }
        if info.kind.isUtility {
            let count = state.board.utilityCells.filter { state.cells[$0].owner == owner }.count
            let multipliers = Board.utilityMultipliers
            return "×\(multipliers[min(max(count, 1), multipliers.count) - 1])"
        }
        return Format.money(state.rentAmount(for: info.id))
    }

    private func tokens(layout: BoardLayout, state: GameState) -> some View {
        let alive = state.players.filter { !$0.isBankrupt }
        let byCell = Dictionary(grouping: alive, by: \.position)
        let size = max(12, layout.short * 0.55)
        return ForEach(alive) { player in
            let group = byCell[player.position] ?? [player]
            let slot = group.firstIndex { $0.id == player.id } ?? 0
            TokenView(player: player.id, size: size)
                .position(layout.tokenCenter(cell: player.position, slot: slot, of: group.count))
                .animation(.spring(response: 0.45, dampingFraction: 0.75), value: player.position)
                .allowsHitTesting(false)
        }
    }
}

/// Одна клетка доски в духе Monopoly One:
/// фон цвета группы, ценник на внешнем краю (цена или рента в цвете владельца),
/// звёзды-филиалы у внутреннего края, замок со счётчиком ходов при залоге.
struct CellView: View {
    @Environment(\.skin) private var skin
    let info: CellInfo
    let ownership: Ownership
    let edge: BoardLayout.Edge
    let unit: CGFloat
    let highlighted: Bool
    let isCurrent: Bool
    /// Текст ценника: цена свободной улицы или текущая рента купленной.
    let tag: String?

    @State private var glow = false

    var body: some View {
        ZStack {
            Rectangle().fill(edge == .corner ? skin.cornerFill : skin.cellFill)
            if let group = info.group {
                Rectangle().fill(skin.groupColor(group).opacity(skin.isDark && skin.id == "neon" ? 0.22 : 0.3))
            }
            oriented
                .opacity(ownership.isMortgaged ? 0.45 : 1)
            if ownership.isMortgaged {
                mortgageBadge
            }
        }
        .overlay(Rectangle().stroke(skin.cellStroke, lineWidth: 0.5))
        .overlay {
            if highlighted {
                Rectangle()
                    .stroke(skin.highlight, lineWidth: glow ? 3 : 1.5)
                    .shadow(color: skin.highlight, radius: glow ? 6 : 2)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { glow = true }
                    }
                    .onDisappear { glow = false }
            } else if isCurrent {
                Rectangle().stroke(skin.accent.opacity(0.8), lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
    }

    /// Содержимое рисуется «горизонтально» (внутренний край слева или справа)
    /// и поворачивается под свою сторону доски.
    @ViewBuilder private var oriented: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            switch edge {
            case .corner:
                CornerContent(info: info, unit: unit)
                    .frame(width: w, height: h)
            case .bottom:
                content(interiorLeading: true, length: h, thickness: w, tagAngle: -90)
                    .frame(width: h, height: w)
                    .rotationEffect(.degrees(90))
                    .position(x: w / 2, y: h / 2)
            case .top:
                content(interiorLeading: true, length: h, thickness: w, tagAngle: 90)
                    .frame(width: h, height: w)
                    .rotationEffect(.degrees(-90))
                    .position(x: w / 2, y: h / 2)
            case .left:
                content(interiorLeading: false, length: w, thickness: h, tagAngle: -90)
                    .frame(width: w, height: h)
            case .right:
                content(interiorLeading: true, length: w, thickness: h, tagAngle: 90)
                    .frame(width: w, height: h)
            }
        }
    }

    private func content(interiorLeading: Bool, length: CGFloat, thickness: CGFloat, tagAngle: Double) -> some View {
        HStack(spacing: 0) {
            if interiorLeading {
                stars(length: length, thickness: thickness)
                label(thickness: thickness)
                priceTag(length: length, thickness: thickness, angle: tagAngle)
            } else {
                priceTag(length: length, thickness: thickness, angle: tagAngle)
                label(thickness: thickness)
                stars(length: length, thickness: thickness)
            }
        }
    }

    /// Ценник на внешнем краю. Текст повёрнут так, чтобы читаться с края доски.
    @ViewBuilder private func priceTag(length: CGFloat, thickness: CGFloat, angle: Double) -> some View {
        if let tag {
            let width = length * 0.24
            ZStack {
                Rectangle().fill(ownership.owner.map { skin.playerColor($0) } ?? skin.cellStroke.opacity(0.18))
                Text(tag)
                    .font(skin.font(max(5, width * 0.62), .bold))
                    .foregroundStyle(ownership.owner == nil ? skin.text : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .frame(width: thickness * 0.94)
                    .rotationEffect(.degrees(angle))
            }
            .frame(width: width)
            .clipped()
        }
    }

    /// Филиалы — маленькие звёзды, отель — одна большая.
    @ViewBuilder private func stars(length: CGFloat, thickness: CGFloat) -> some View {
        let width = length * 0.14
        if ownership.branches == Board.maxBranches {
            Image(systemName: "star.fill")
                .font(.system(size: width * 0.95))
                .foregroundStyle(skin.highlight)
                .shadow(color: .black.opacity(0.4), radius: 1)
                .frame(width: width)
        } else if ownership.branches > 0 {
            VStack(spacing: 1) {
                ForEach(0..<ownership.branches, id: \.self) { _ in
                    Image(systemName: "star.fill")
                        .font(.system(size: min(width * 0.8, thickness / 5)))
                        .foregroundStyle(skin.highlight)
                        .shadow(color: .black.opacity(0.4), radius: 0.5)
                }
            }
            .frame(width: width)
        } else if info.group != nil {
            Color.clear.frame(width: width)
        }
    }

    private func label(thickness: CGFloat) -> some View {
        let fontSize = max(5, thickness * 0.24)
        return VStack(spacing: 1) {
            if let symbol = CellSymbol.name(for: info) {
                Image(systemName: symbol)
                    .font(.system(size: fontSize * 1.5))
                    .foregroundStyle(skin.secondaryText)
            }
            Text(info.name)
                .font(skin.font(fontSize, .semibold))
                .foregroundStyle(skin.text)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
        }
        .padding(2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Замок со счётчиком ходов до потери залога.
    private var mortgageBadge: some View {
        HStack(spacing: 1) {
            Image(systemName: "lock.fill")
            if let left = ownership.mortgageTurnsLeft { Text("\(left)") }
        }
        .font(.system(size: max(6, unit * 0.26), weight: .bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .background(skin.danger, in: Capsule())
        .shadow(radius: 1)
    }
}

struct CornerContent: View {
    @Environment(\.skin) private var skin
    let info: CellInfo
    let unit: CGFloat

    var body: some View {
        VStack(spacing: 2) {
            if let symbol = CellSymbol.name(for: info) {
                Image(systemName: symbol)
                    .font(.system(size: unit * 0.55, weight: .bold))
                    .foregroundStyle(skin.accent)
            }
            Text(info.name)
                .font(skin.font(max(6, unit * 0.22), .bold))
                .foregroundStyle(skin.text)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.5)
        }
        .padding(3)
    }
}

enum CellSymbol {
    static func name(for info: CellInfo) -> String? {
        switch info.kind {
        case .start: "arrow.left.circle.fill"
        case .company: nil
        case .transport: "tram.fill"
        case .utility: info.name.contains("Вод") ? "drop.fill" : "bolt.fill"
        case .chance: "questionmark.circle.fill"
        case .communityChest: "shippingbox.fill"
        case .tax: "banknote.fill"
        case .jail: "lock.fill"
        case .parking: "parkingsign.circle.fill"
        case .jackpot: "dice.fill"
        case .goToJail: "hand.raised.fill"
        }
    }
}

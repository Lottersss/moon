import SwiftUI
import TycoonCore

/// Свои названия полей. Пустое поле — стандартное название (оно видно серым).
/// Названия применяются к новым партиям; в игре по Bluetooth все видят названия хоста.
struct CellNamesView: View {
    @Environment(\.skin) private var skin

    private var store: CellNameStore { .shared }
    private let board = Board.standard

    var body: some View {
        List {
            Section {
                Text("Впишите свои названия — они появятся в следующей новой партии. Пустая строка — стандартное название.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(ColorGroup.allCases, id: \.self) { group in
                Section(group.title) {
                    ForEach(board.cells.filter { $0.group == group }) { cell in
                        row(cell, color: skin.groupColor(group))
                    }
                }
            }

            Section("Автоконцерны") {
                ForEach(board.cells.filter { if case .transport = $0.kind { true } else { false } }) { cell in
                    row(cell, color: .gray)
                }
            }

            Section("Игровые студии") {
                ForEach(board.cells.filter { if case .utility = $0.kind { true } else { false } }) { cell in
                    row(cell, color: .gray)
                }
            }

            if !store.names.isEmpty {
                Section {
                    Button("Вернуть стандартные названия", role: .destructive) { store.reset() }
                }
            }
        }
        .navigationTitle("Названия полей")
    }

    private func row(_ cell: CellInfo, color: Color) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 6, height: 24)
            TextField(cell.name, text: Binding(get: { store.names[cell.id] ?? "" },
                                               set: { store.set($0, for: cell.id) }))
            if let price = cell.price {
                Text(Format.money(price)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

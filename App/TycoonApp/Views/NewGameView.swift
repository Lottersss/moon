import SwiftUI
import TycoonCore

/// Настройка партии: режим, игроки, таймер, скин.
struct NewGameView: View {
    @Environment(\.skin) private var skin
    @Binding var skinID: String
    var onStart: (GameConfig) -> Void
    /// Игра по Bluetooth: создать комнату или найти комнату рядом.
    var onHost: (String) -> Void = { _ in }
    var onJoin: (String) -> Void = { _ in }

    @State private var config = GameConfig()
    @AppStorage("playerName") private var playerName = "Игрок"

    var body: some View {
        NavigationStack {
            Form {
                Section("Режим") {
                    Picker("Режим", selection: $config.mode) {
                        ForEach(GameMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(config.mode.subtitle).font(.footnote).foregroundStyle(.secondary)
                }

                Section {
                    ForEach(config.players.indices, id: \.self) { index in
                        playerRow(index)
                    }
                    if config.mode != .teams {
                        Stepper("Игроков: \(config.players.count)",
                                onIncrement: addPlayer, onDecrement: removePlayer)
                    }
                } header: {
                    Text("Игроки")
                } footer: {
                    if config.mode == .teams {
                        Text("Первые двое — команда A, следующие двое — команда B. Команды ходят по очереди.")
                    }
                }

                Section("Правила") {
                    Picker("Лимит кругов", selection: $config.maxRounds) {
                        Text("Без лимита").tag(Int?.none)
                        ForEach([20, 30, 50, 100], id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                    }
                    Picker("Время на ход", selection: $config.turnSeconds) {
                        Text("Без таймера").tag(Int?.none)
                        ForEach([30, 60, 90, 120], id: \.self) { Text("\($0) с").tag(Int?.some($0)) }
                    }
                    Toggle("Ровные кубики", isOn: $config.balancedDice)
                    Toggle("«Передайте телефон» между игроками", isOn: $config.passDevicePrompt)
                }

                Section {
                    TextField("Ваше имя", text: $playerName)
                    Button {
                        onHost(playerName)
                    } label: {
                        Label("Создать комнату", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    Button {
                        onJoin(playerName)
                    } label: {
                        Label("Найти комнату рядом", systemImage: "magnifyingglass")
                    }
                } header: {
                    Text("По Bluetooth")
                } footer: {
                    Text("Каждый играет на своём iPhone. Телефоны должны быть рядом, интернет не нужен.")
                }

                Section("Скин") {
                    SkinPicker(skinID: $skinID)
                }

                Section {
                    Button {
                        onStart(config)
                    } label: {
                        Label("Начать игру", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!isValid)
                }
            }
            .navigationTitle("Новая игра")
            .onChange(of: config.mode) { _, mode in
                if mode == .teams { fitPlayers(to: 4) }
            }
        }
        .tint(skin.accent)
    }

    private var isValid: Bool {
        let names = config.players.map { $0.name.trimmingCharacters(in: .whitespaces) }
        return (2...6).contains(config.players.count) && !names.contains("")
    }

    private func playerRow(_ index: Int) -> some View {
        HStack(spacing: 10) {
            TokenView(player: index, size: 26)
            TextField("Имя", text: $config.players[index].name)
            if config.mode == .teams {
                Text(index < 2 ? "A" : "B")
                    .font(.caption.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
            Toggle(isOn: $config.players[index].isBot) {
                Image(systemName: "cpu")
            }
            .toggleStyle(.button)
        }
    }

    private func addPlayer() {
        guard config.players.count < 6 else { return }
        config.players.append(PlayerSetup(name: "Бот \(config.players.count + 1)", isBot: true))
    }

    private func removePlayer() {
        guard config.players.count > 2 else { return }
        config.players.removeLast()
    }

    private func fitPlayers(to count: Int) {
        while config.players.count < count { addPlayer() }
        while config.players.count > count { config.players.removeLast() }
    }
}

/// Выбор скина: превью доски в цветах скина.
struct SkinPicker: View {
    @Binding var skinID: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Skin.all) { skin in
                    let selected = skin.id == skinID
                    VStack(spacing: 6) {
                        SkinPreview(skin: skin)
                            .frame(width: 84, height: 84)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(selected ? skin.accent : Color.clear, lineWidth: 3)
                            )
                        Text(skin.name).font(.caption.weight(selected ? .bold : .regular))
                    }
                    .onTapGesture { skinID = skin.id }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

struct SkinPreview: View {
    let skin: Skin

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(skin.background)
            RoundedRectangle(cornerRadius: 8).fill(skin.boardFill).padding(8)
            VStack(spacing: 3) {
                HStack(spacing: 3) {
                    ForEach(Array(ColorGroup.allCases.prefix(4)), id: \.self) { group in
                        Rectangle().fill(skin.groupColor(group)).frame(width: 10, height: 14)
                    }
                }
                HStack(spacing: 3) {
                    ForEach(Array(ColorGroup.allCases.suffix(4)), id: \.self) { group in
                        Rectangle().fill(skin.groupColor(group)).frame(width: 10, height: 14)
                    }
                }
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { id in
                        TokenView(player: id, size: 14)
                    }
                }
                .environment(\.skin, skin)
            }
        }
    }
}

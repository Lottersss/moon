import SwiftUI
import TycoonCore

/// Настройка партии: режим, игроки, таймер, скин.
struct NewGameView: View {
    @Environment(\.skin) private var skin
    @Binding var skinID: String
    var onStart: (GameConfig) -> Void
    /// Игра по Bluetooth: создать комнату или найти комнату рядом.
    var onHost: () -> Void = {}
    var onJoin: () -> Void = {}
    /// Незаконченная партия на этом телефоне.
    var saved: SavedGame? = nil
    var onResume: () -> Void = {}
    var onDiscard: () -> Void = {}

    @State private var config = GameConfig()
    /// Какой аккаунт сидит на каком месте (только живые игроки).
    @State private var seatAccounts: [Int: UUID] = [:]

    private var accounts: AccountStore { .shared }
    private var cellNames: CellNameStore { .shared }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        AccountsView()
                    } label: {
                        HStack(spacing: 12) {
                            AvatarCircle(symbol: accounts.main.avatar, size: 44, imageURL: accounts.main.avatarURL)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(accounts.main.name).font(.headline)
                                Text(AccountsView.stats(accounts.main))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Аккаунт")
                }

                if let saved {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(saved.summary).font(.subheadline)
                            Text(saved.savedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button(action: onResume) {
                            Label("Продолжить партию", systemImage: "play.circle.fill")
                                .font(.headline)
                        }
                        Button("Удалить сохранение", role: .destructive, action: onDiscard)
                    } header: {
                        Text("Незаконченная партия")
                    }
                }

                Section("Режим") {
                    Picker("Режим", selection: teams) {
                        Text("Каждый сам за себя").tag(false)
                        Text("2×2").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Перестановка (быстрая игра)", isOn: reshuffle)
                    Text(config.mode.subtitle).font(.footnote).foregroundStyle(.secondary)
                }

                Section {
                    ForEach(config.players.indices, id: \.self) { index in
                        playerRow(index)
                    }
                    if !config.mode.isTeams {
                        Stepper("Игроков: \(config.players.count)",
                                onIncrement: addPlayer, onDecrement: removePlayer)
                    }
                } header: {
                    Text("Игроки")
                } footer: {
                    if config.mode.isTeams {
                        Text("Первые двое — команда A, следующие двое — команда B. Команды ходят по очереди. Нажмите на значок игрока, чтобы выбрать аккаунт.")
                    } else {
                        Text("Нажмите на значок живого игрока, чтобы выбрать его аккаунт — победы попадут в его статистику.")
                    }
                }

                Section("Правила") {
                    Picker("Лимит кругов", selection: $config.maxRounds) {
                        Text("Без лимита").tag(Int?.none)
                        ForEach([20, 30, 50, 100], id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                    }
                    Picker("Время на ход", selection: $config.turnSeconds) {
                        Text("Без таймера").tag(Int?.none)
                        ForEach([30, 45, 60, 90, 120], id: \.self) { Text("\($0) с").tag(Int?.some($0)) }
                    }
                    Toggle("Ровные кубики", isOn: $config.balancedDice)
                    Toggle("«Передайте телефон» между игроками", isOn: $config.passDevicePrompt)
                }

                Section {
                    NavigationLink {
                        CellNamesView()
                    } label: {
                        LabeledContent("Названия полей",
                                       value: cellNames.names.isEmpty ? "Стандартные" : "Своих: \(cellNames.names.count)")
                    }
                } header: {
                    Text("Поля")
                }

                Section {
                    Button {
                        onHost()
                    } label: {
                        Label("Создать комнату", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    Button {
                        onJoin()
                    } label: {
                        Label("Найти комнату рядом", systemImage: "magnifyingglass")
                    }
                } header: {
                    Text("По Bluetooth")
                } footer: {
                    Text("Вы играете как «\(accounts.main.name)». Каждый играет на своём iPhone, телефоны должны быть рядом, интернет не нужен. В партии есть чат.")
                }

                Section("Скин") {
                    SkinPicker(skinID: $skinID)
                }

                Section {
                    Button {
                        onStart(finalConfig)
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
                if mode.isTeams { fitPlayers(to: 4) }
            }
            .onAppear(perform: seatMainAccount)
        }
        .tint(skin.accent)
    }

    /// Режим собирается из двух независимых переключателей: команды и «Перестановка».
    private var teams: Binding<Bool> {
        Binding(get: { config.mode.isTeams },
                set: { config.mode = GameMode(teams: $0, reshuffle: config.mode.isReshuffle) })
    }

    private var reshuffle: Binding<Bool> {
        Binding(get: { config.mode.isReshuffle },
                set: { on in
                    config.mode = GameMode(teams: config.mode.isTeams, reshuffle: on)
                    // Быстрая игра Monopoly One: 45 секунд на ход вместо обычных.
                    if config.turnSeconds != nil { config.turnSeconds = on ? 45 : 60 }
                })
    }

    /// Первое место по умолчанию занимает основной аккаунт.
    private func seatMainAccount() {
        guard seatAccounts.isEmpty, !config.players.isEmpty, !config.players[0].isBot else { return }
        let main = accounts.main
        seatAccounts[0] = main.id
        config.players[0].name = main.name
    }

    /// Аватары мест, у которых выбран аккаунт.
    private var avatarMap: [Int: String] {
        seatAccounts.compactMapValues { accounts.account($0)?.avatar }
    }

    /// Настройки партии вместе с аккаунтами, аватарами и своими названиями полей.
    private var finalConfig: GameConfig {
        var result = config
        let seats = seatAccounts.filter { config.players.indices.contains($0.key) && !config.players[$0.key].isBot }
        result.accounts = seats
        result.avatars = seats.compactMapValues { accounts.account($0)?.avatar }
        result.cellNames = cellNames.names
        return result
    }

    private func pick(_ account: Account?, for index: Int) {
        if let account {
            seatAccounts = seatAccounts.filter { $0.value != account.id }
            seatAccounts[index] = account.id
            config.players[index].name = account.name
            config.players[index].isBot = false
        } else {
            seatAccounts[index] = nil
            config.players[index].name = "Игрок \(index + 1)"
        }
    }

    private var isValid: Bool {
        let names = config.players.map { $0.name.trimmingCharacters(in: .whitespaces) }
        return (2...6).contains(config.players.count) && !names.contains("")
    }

    private func playerRow(_ index: Int) -> some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(accounts.accounts) { account in
                    Button {
                        pick(account, for: index)
                    } label: {
                        Label(account.name, systemImage: account.avatar)
                    }
                }
                Divider()
                Button("Гость (без аккаунта)") { pick(nil, for: index) }
            } label: {
                TokenView(player: index, size: 26)
                    .environment(\.avatars, avatarMap)
            }
            .disabled(config.players[index].isBot)
            TextField("Имя", text: $config.players[index].name)
            if config.mode.isTeams {
                Text(index < 2 ? "A" : "B")
                    .font(.caption.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
            Toggle(isOn: Binding(get: { config.players[index].isBot },
                                 set: { isBot in
                                     config.players[index].isBot = isBot
                                     if isBot { seatAccounts[index] = nil }
                                 })) {
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

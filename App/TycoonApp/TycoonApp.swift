import SwiftUI
import TycoonCore

@main
struct TycoonApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Корневой экран: настройка партии или сама партия.
struct RootView: View {
    @AppStorage("skin") private var skinID = Skin.night.id
    @State private var game: GameViewModel?
    @State private var lobby: NetworkLobby?
    @State private var saved = SaveStore.load()
    @State private var showSkins = false

    var body: some View {
        let skin = Skin.named(skinID)
        Group {
            if let lobby {
                if let networkGame = lobby.game {
                    GameView(model: networkGame,
                             onExit: closeLobby,
                             onChangeSkin: { showSkins = true })
                        .alert("Связь с хостом потеряна",
                               isPresented: Binding(get: { lobby.connectionLost },
                                                    set: { lobby.connectionLost = $0 })) {
                            Button("Выйти", action: closeLobby)
                        } message: {
                            Text("Телефон хоста отключился или ушёл слишком далеко.")
                        }
                } else {
                    LobbyView(lobby: lobby, onClose: closeLobby)
                }
            } else if let game {
                GameView(model: game,
                         onExit: {
                             self.game = nil
                             saved = SaveStore.load()
                         },
                         onChangeSkin: { showSkins = true })
            } else {
                NewGameView(skinID: $skinID,
                            onStart: { config in game = GameViewModel(config: config) },
                            onHost: { name in lobby = NetworkLobby(role: .host, name: name) },
                            onJoin: { name in lobby = NetworkLobby(role: .client, name: name) },
                            saved: saved,
                            onResume: {
                                if let saved { game = GameViewModel(restoring: saved) }
                            },
                            onDiscard: {
                                SaveStore.clear()
                                saved = nil
                            })
            }
        }
        .environment(\.skin, skin)
        .preferredColorScheme(skin.isDark ? .dark : .light)
        .task {
            startDemoIfRequested()
            await startNetworkDemoIfRequested()
        }
        .animation(.easeInOut, value: skinID)
        .sheet(isPresented: $showSkins) {
            NavigationStack {
                SkinPicker(skinID: $skinID)
                    .padding()
                    .navigationTitle("Скин")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.height(220)])
        }
    }

    private func closeLobby() {
        lobby?.leave()
        lobby = nil
    }

    /// Для отладки по сети: `-host Имя` открывает комнату и начинает партию с ботами,
    /// как только подключится один телефон; `-join Имя` подключается к первой найденной комнате.
    private func startNetworkDemoIfRequested() async {
        let args = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        if let name = value(after: "-host") {
            let room = NetworkLobby(role: .host, name: name)
            lobby = room
            for _ in 0..<120 where room.seats.count < 2 {
                try? await Task.sleep(for: .milliseconds(500))
            }
            room.addBot()
            room.addBot()
            room.start()
        } else if let name = value(after: "-join") {
            let room = NetworkLobby(role: .client, name: name)
            lobby = room
            for _ in 0..<120 where room.hosts.isEmpty {
                try? await Task.sleep(for: .milliseconds(500))
            }
            if let host = room.hosts.first { room.join(host) }
        }
    }

    /// Для отладки: `-demo classic|teams|reshuffle` сразу запускает партию,
    /// `-skin neon` выбирает скин, `-human` делает первого игрока живым (иначе все боты).
    private func startDemoIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        if let skin = value(after: "-skin") { skinID = skin }
        if args.contains("-resume"), game == nil, let saved {
            game = GameViewModel(restoring: saved)
            return
        }
        guard game == nil, let mode = value(after: "-demo") else { return }
        var config = GameConfig()
        config.mode = GameMode(rawValue: mode) ?? .classic
        config.turnSeconds = nil
        config.passDevicePrompt = false
        config.players = (0..<4).map { PlayerSetup(name: "Бот \($0 + 1)", isBot: true) }
        if args.contains("-human") { config.players[0] = PlayerSetup(name: "Лоттерс") }
        game = GameViewModel(config: config)
    }
}

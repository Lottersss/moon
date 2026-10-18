import SwiftUI
import TycoonCore

/// Комната для игры по Bluetooth: хост собирает игроков, остальные ищут комнату рядом.
struct LobbyView: View {
    @Environment(\.skin) private var skin
    let lobby: NetworkLobby
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        if !lobby.canStart || lobby.role == .client {
                            ProgressView()
                        }
                        Text(lobby.status)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                switch lobby.role {
                case .host: hostSections
                case .client: clientSections
                }
            }
            .navigationTitle(lobby.role == .host ? "Моя комната" : "Найти комнату")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Выйти", action: onClose)
                }
            }
        }
        .tint(skin.accent)
    }

    // MARK: - Хост

    @ViewBuilder private var hostSections: some View {
        Section {
            ForEach(Array(lobby.seats.enumerated()), id: \.element.id) { index, seat in
                HStack(spacing: 10) {
                    TokenView(player: index, size: 26)
                        .environment(\.avatars, seat.avatar.map { [index: $0] } ?? [:])
                    Text(seat.name)
                    Spacer()
                    Text(seat.isHost ? "Вы" : seat.isBot ? "Бот" : "Телефон")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if lobby.mode.isTeams {
                        Text(index < 2 ? "A" : "B").font(.caption.bold())
                    }
                }
                .swipeActions {
                    if !seat.isHost {
                        Button("Убрать", role: .destructive) { lobby.removeSeat(seat) }
                    }
                }
            }
            Button {
                lobby.addBot()
            } label: {
                Label("Добавить бота", systemImage: "cpu")
            }
            .disabled(lobby.seats.count >= NetworkLobby.maxSeats)
        } header: {
            Text("Игроки")
        } footer: {
            Text("Друзья открывают «По Bluetooth» → «Найти комнату» на своих iPhone рядом. Интернет не нужен.")
        }

        Section("Правила") {
            Picker("Режим", selection: Binding(get: { lobby.mode }, set: { lobby.mode = $0 })) {
                ForEach(GameMode.allCases) { Text($0.title).tag($0) }
            }
            Picker("Время на ход", selection: Binding(get: { lobby.turnSeconds }, set: { lobby.turnSeconds = $0 })) {
                Text("Без таймера").tag(Int?.none)
                ForEach([30, 45, 60, 90, 120], id: \.self) { Text("\($0) с").tag(Int?.some($0)) }
            }
            Picker("Лимит кругов", selection: Binding(get: { lobby.maxRounds }, set: { lobby.maxRounds = $0 })) {
                Text("Без лимита").tag(Int?.none)
                ForEach([20, 30, 50, 100], id: \.self) { Text("\($0)").tag(Int?.some($0)) }
            }
            if lobby.mode.isTeams && lobby.seats.count != 4 {
                Text("Для 2×2 нужно ровно 4 игрока (можно с ботами)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        Section {
            Button {
                lobby.start()
            } label: {
                Label("Начать игру", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .disabled(!lobby.canStart)
        }
    }

    // MARK: - Клиент

    @ViewBuilder private var clientSections: some View {
        if lobby.joinedHost == nil {
            Section("Комнаты рядом") {
                if lobby.hosts.isEmpty {
                    Text("Пока никого. Попросите друга создать комнату.")
                        .foregroundStyle(.secondary)
                }
                ForEach(lobby.hosts, id: \.self) { host in
                    Button {
                        lobby.join(host)
                    } label: {
                        Label(host.displayName, systemImage: "dot.radiowaves.left.and.right")
                    }
                }
            }
        } else {
            Section("В комнате") {
                ForEach(Array(lobby.seats.enumerated()), id: \.element.id) { index, seat in
                    HStack(spacing: 10) {
                        TokenView(player: index, size: 26)
                        Text(seat.name)
                        if seat.name == lobby.myName {
                            Spacer()
                            Text("Вы").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

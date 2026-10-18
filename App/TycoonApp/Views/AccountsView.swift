import SwiftUI
import TycoonCore

/// Аватар аккаунта: значок в цветном кружке.
struct AvatarCircle: View {
    @Environment(\.skin) private var skin
    let symbol: String
    var size: CGFloat = 36
    var color: Color? = nil
    /// Фото из профиля Monopoly One. Пока грузится или если не загрузилось — виден значок.
    var imageURL: String? = nil

    var body: some View {
        ZStack {
            Circle().fill(color ?? skin.accent)
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .bold))
                .foregroundStyle(.white)
            if let url = imageURL.flatMap({ URL(string: $0) }) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
                .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
    }
}

/// Аккаунты на этом телефоне: имя, аватар, статистика. Звёздочка — основной аккаунт.
struct AccountsView: View {
    @Environment(\.skin) private var skin
    @State private var editing: Account?
    @State private var creating = false
    @State private var signingIn = false

    private var store: AccountStore { .shared }

    var body: some View {
        List {
            Section {
                ForEach(store.accounts) { account in
                    row(account)
                }
            } footer: {
                Text("Основной аккаунт (★) — им вы играете по Bluetooth, он же садится на первое место в новой игре. Нажмите на аккаунт, чтобы изменить имя и аватар.")
            }

            Section {
                Button {
                    signingIn = true
                } label: {
                    Label("Войти через Monopoly One", systemImage: "person.crop.circle.badge.checkmark")
                }
                Button {
                    creating = true
                } label: {
                    Label("Добавить аккаунт", systemImage: "person.badge.plus")
                }
            } footer: {
                Text("Вход через Monopoly One подтягивает ваш ник, фото и статистику оттуда. Пароль приложение не получает и не хранит, ключ доступа нужен один раз. Для игры за одним телефоном у каждого может быть свой аккаунт.")
            }
        }
        .navigationTitle("Аккаунты")
        .sheet(item: $editing) { account in
            AccountEditor(title: "Аккаунт", account: account) { store.update($0) }
                .environment(\.skin, skin)
        }
        .sheet(isPresented: $signingIn) {
            MonopolyOneSignInView()
                .environment(\.skin, skin)
        }
        .sheet(isPresented: $creating) {
            AccountEditor(title: "Новый аккаунт",
                          account: Account(name: "", avatar: Account.avatars.randomElement() ?? "star.fill")) {
                store.add(name: $0.name, avatar: $0.avatar)
            }
            .environment(\.skin, skin)
        }
    }

    private func row(_ account: Account) -> some View {
        HStack(spacing: 12) {
            AvatarCircle(symbol: account.avatar, size: 40, imageURL: account.avatarURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name).font(.headline)
                Text(Self.stats(account)).font(.caption).foregroundStyle(.secondary)
                if let line = Self.monopolyLine(account) {
                    Label(line, systemImage: "checkmark.seal.fill")
                        .font(.caption2)
                        .foregroundStyle(skin.accent)
                }
            }
            Spacer()
            Button {
                store.makeMain(account.id)
            } label: {
                Image(systemName: account.id == store.main.id ? "star.fill" : "star")
                    .foregroundStyle(account.id == store.main.id ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture { editing = account }
        .swipeActions {
            if store.accounts.count > 1 {
                Button("Удалить", role: .destructive) { store.delete(account.id) }
            }
        }
    }

    /// «Monopoly One: Ник · 120 игр, 45 побед» — только у вошедших через Monopoly One.
    static func monopolyLine(_ account: Account) -> String? {
        guard account.isLinked else { return nil }
        var line = "Monopoly One: " + (account.monopolyNick ?? account.name)
        if let games = account.monopolyGames {
            line += " · игр \(games)"
            if let wins = account.monopolyWins { line += ", побед \(wins)" }
        }
        return line
    }

    static func stats(_ account: Account) -> String {
        guard account.gamesPlayed > 0 else { return "Ещё не играл" }
        return "Партий: \(account.gamesPlayed) · Побед: \(account.wins) (\(account.winRate)%)"
    }
}

/// Имя и аватар аккаунта.
struct AccountEditor: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @State var account: Account
    var onSave: (Account) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 5)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        AvatarCircle(symbol: account.avatar, size: 76, imageURL: account.avatarURL)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    TextField("Имя", text: $account.name)
                        .onChange(of: account.name) { _, name in
                            if name.count > 20 { account.name = String(name.prefix(20)) }
                        }
                }

                Section("Аватар") {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(Account.avatars, id: \.self) { symbol in
                            AvatarCircle(symbol: symbol, size: 46,
                                         color: symbol == account.avatar ? nil : Color.gray.opacity(0.45))
                                .onTapGesture { account.avatar = symbol }
                        }
                    }
                    .padding(.vertical, 4)
                }

                if account.isLinked {
                    Section {
                        LabeledContent("Ник", value: account.monopolyNick ?? account.name)
                        if let games = account.monopolyGames { LabeledContent("Игр", value: "\(games)") }
                        if let wins = account.monopolyWins { LabeledContent("Побед", value: "\(wins)") }
                        Button("Отвязать от Monopoly One", role: .destructive) {
                            account.monopolyID = nil
                            account.monopolyNick = nil
                            account.avatarURL = nil
                            account.monopolyGames = nil
                            account.monopolyWins = nil
                        }
                    } header: {
                        Text("Monopoly One")
                    } footer: {
                        Text("Данные взяты при входе. Чтобы обновить, войдите ещё раз.")
                    }
                }

                if account.gamesPlayed > 0 {
                    Section("Статистика") {
                        LabeledContent("Партий", value: "\(account.gamesPlayed)")
                        LabeledContent("Побед", value: "\(account.wins)")
                        LabeledContent("Процент побед", value: "\(account.winRate)%")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        account.name = account.name.trimmingCharacters(in: .whitespaces)
                        onSave(account)
                        dismiss()
                    }
                    .disabled(account.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

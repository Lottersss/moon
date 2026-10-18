import SwiftUI
import WebKit
import TycoonCore

/// Вход через Monopoly One: страница разрешения доступа внутри приложения,
/// потом один запрос профиля. Токен после этого выбрасывается.
struct MonopolyOneSignInView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.skin) private var skin

    private enum Step {
        case appID
        case web(URL)
        case loading
        case failed(String)
    }

    @State private var step: Step = .appID
    @State private var appIDText = ""
    /// Растёт при «Повторить»: страница входа создаётся заново.
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .appID: appIDForm
                case .web(let url):
                    MonopolyOneWebView(url: url, onResult: handle)
                        .id(attempt)
                        .ignoresSafeArea(edges: .bottom)
                case .loading:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Получаю профиль…").foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    VStack(spacing: 14) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.orange)
                        Text(message).multilineTextAlignment(.center)
                        Button("Повторить", action: begin).buttonStyle(.borderedProminent)
                    }
                    .padding(24)
                }
            }
            .navigationTitle("Monopoly One")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
        .tint(skin.accent)
        .onAppear(perform: begin)
    }

    private var appIDForm: some View {
        Form {
            Section {
                TextField("ID приложения", text: $appIDText)
                    .keyboardType(.numberPad)
            } header: {
                Text("ID приложения")
            } footer: {
                Text("Для входа нужен ID приложения (app_id), зарегистрированного на Monopoly One. Секретный ключ (app_secret) сюда вводить не нужно — он остаётся только у Monopoly One.")
            }
            Section {
                Button("Продолжить") {
                    if let id = Int(appIDText.trimmingCharacters(in: .whitespaces)), id > 0 {
                        MonopolyOneConfig.setAppID(id)
                        begin()
                    }
                }
                .disabled((Int(appIDText.trimmingCharacters(in: .whitespaces)) ?? 0) <= 0)
            }
        }
    }

    private func begin() {
        if let url = MonopolyOne.authorizeURL(appID: MonopolyOneConfig.appID) {
            attempt += 1
            step = .web(url)
        } else {
            step = .appID
        }
    }

    private func handle(_ result: Result<MonopolyOne.Authorization, MonopolyOneError>) {
        switch result {
        case .failure(let error):
            step = .failed(error.description)
        case .success(let authorization):
            step = .loading
            Task { @MainActor in
                do {
                    let profile = try await MonopolyOneClient.fetchProfile(accessToken: authorization.accessToken)
                    AccountStore.shared.signIn(profile)
                    dismiss()
                } catch let error as MonopolyOneError {
                    step = .failed(error.description)
                } catch {
                    step = .failed(MonopolyOneError.unreachable.description)
                }
            }
        }
    }
}

/// Страница входа Monopoly One. Как только она ведёт на `.../oauth/blank`, забираем токен из адреса
/// и не загружаем эту страницу. Хранилище временное: куки и сессия не остаются в приложении.
struct MonopolyOneWebView: UIViewRepresentable {
    let url: URL
    var onResult: (Result<MonopolyOne.Authorization, MonopolyOneError>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onResult: (Result<MonopolyOne.Authorization, MonopolyOneError>) -> Void
        private var finished = false

        init(onResult: @escaping (Result<MonopolyOne.Authorization, MonopolyOneError>) -> Void) {
            self.onResult = onResult
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .allow }
            if MonopolyOne.isRedirect(url) {
                finish(MonopolyOne.parseRedirect(url))
                return .cancel
            }
            // Только защищённые страницы: внутри входа никуда больше не уходим.
            return url.scheme == "https" || url.scheme == "about" ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        private func report(_ error: Error) {
            // Отмена перехода на итоговую страницу (-999) — это не ошибка.
            if (error as NSError).code == NSURLErrorCancelled { return }
            finish(.failure(.unreachable))
        }

        private func finish(_ result: Result<MonopolyOne.Authorization, MonopolyOneError>) {
            guard !finished else { return }
            finished = true
            onResult(result)
        }
    }
}

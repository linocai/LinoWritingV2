import Foundation
import SwiftUI

/// Composition root. Builds and holds shared singletons for the app.
/// The whole tree is built lazily so unit tests can override pieces.
@MainActor
final class AppEnvironment: ObservableObject {

    static let shared = AppEnvironment()

    let keychain: KeychainStore
    let settings: Settings
    let errorBus: ErrorBus

    private(set) lazy var apiClient: APIClientProtocol = APIClient(
        config: { [weak self] in
            guard let self,
                  let url = self.keychain.baseURL,
                  let token = self.keychain.token,
                  !token.isEmpty
            else { return nil }
            return APIClient.Config(baseURL: url, token: token)
        }
    )

    private(set) lazy var appStore: AppStore = AppStore(keychain: keychain, settings: settings)
    private(set) lazy var bookshelfStore: BookshelfStore = BookshelfStore(api: apiClient, errorBus: errorBus)
    private(set) lazy var bookStore: BookStore = BookStore(api: apiClient, errorBus: errorBus)
    private(set) lazy var charactersStore: CharactersStore = CharactersStore(api: apiClient, errorBus: errorBus)
    private(set) lazy var chaptersStore: ChaptersStore = ChaptersStore(api: apiClient, errorBus: errorBus)
    private(set) lazy var chapterEditorStore: ChapterEditorStore = ChapterEditorStore(api: apiClient, errorBus: errorBus)
    private(set) lazy var timelineStore: TimelineStore = TimelineStore(api: apiClient, errorBus: errorBus)
    private(set) lazy var providerKeysStore: ProviderKeysStore = ProviderKeysStore(api: apiClient, errorBus: errorBus)
    // v0.7 §5.D / Phase D-log: backs the Settings → "Agent 日志" tab.
    private(set) lazy var agentLogStore: AgentLogStore = AgentLogStore(api: apiClient, errorBus: errorBus)
    // v1.0.0 EE §5.5: backs the Settings → 人格 (Agent persona editor) tab.
    private(set) lazy var personaStore: PersonaStore = PersonaStore(api: apiClient, errorBus: errorBus)

    init(
        keychain: KeychainStore = .shared,
        settings: Settings = .shared,
        errorBus: ErrorBus? = nil
    ) {
        self.keychain = keychain
        self.settings = settings
        self.errorBus = errorBus ?? ErrorBus()
    }
}

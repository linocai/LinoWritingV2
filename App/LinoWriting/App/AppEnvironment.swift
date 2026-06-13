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
        },
        // §5.W.4: the pre-auth `pair_confirm` endpoint needs the base URL
        // before any token exists, so resolve it straight from Keychain
        // (seeded to the production default on first launch).
        baseURLProvider: { [weak self] in self?.keychain.baseURL }
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
    // v0.9 §5.W / W-2: backs the Settings → 连接 → 设备管理 sub-section.
    private(set) lazy var deviceStore: DeviceStore = DeviceStore(api: apiClient, errorBus: errorBus)
    // v1.0.0 EE §5.5: backs the book-level 大纲面板 (outline panel).
    private(set) lazy var outlineStore: OutlineStore = OutlineStore(api: apiClient, errorBus: errorBus)
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

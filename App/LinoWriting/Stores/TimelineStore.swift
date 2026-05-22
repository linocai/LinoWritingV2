import Foundation
import SwiftUI

@MainActor
public final class TimelineStore: ObservableObject {

    @Published public private(set) var events: [TimelineEvent] = []
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var hasMore: Bool = true
    @Published public var characterId: String?

    private let pageSize: Int = 50
    private let api: APIClientProtocol
    private let errorBus: ErrorBus

    public init(api: APIClientProtocol, errorBus: ErrorBus) {
        self.api = api
        self.errorBus = errorBus
    }

    public func setCharacter(_ id: String?) {
        characterId = id
        events = []
        hasMore = true
    }

    public func reset() {
        characterId = nil
        events = []
        hasMore = true
    }

    public func loadInitial() async {
        guard let id = characterId else { return }
        events = []
        hasMore = true
        await fetchPage(characterId: id, before: nil, replace: true)
    }

    public func loadMore() async {
        guard let id = characterId, hasMore, !isLoading else { return }
        await fetchPage(characterId: id, before: events.last?.createdAt, replace: false)
    }

    private func fetchPage(characterId: String, before: Date?, replace: Bool) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await api.listTimeline(characterId: characterId, limit: pageSize, before: before)
            if replace { events = page } else { events.append(contentsOf: page) }
            if page.count < pageSize { hasMore = false }
        } catch let error as AppError {
            errorBus.publish(error)
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
        }
    }
}

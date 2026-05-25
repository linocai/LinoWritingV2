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

    /// v0.7 §5.C — edit one event in-place. On success the local row is
    /// swapped for the server's response (so `editedAt` is fresh) without
    /// having to reload the whole page. On failure the original row stays
    /// and the error is surfaced via `errorBus` so the inline editor can
    /// leave the user's draft alone.
    @discardableResult
    public func updateEvent(
        id eventId: String,
        eventText: String?,
        eventType: TimelineEventType?
    ) async -> TimelineEvent? {
        do {
            let updated = try await api.updateTimelineEvent(
                id: eventId,
                eventText: eventText,
                eventType: eventType
            )
            if let idx = events.firstIndex(where: { $0.id == eventId }) {
                events[idx] = updated
            }
            return updated
        } catch let error as AppError {
            errorBus.publish(error)
            return nil
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
            return nil
        }
    }

    /// v0.7 §5.C — physically delete. Local list is updated optimistically
    /// only on the server's 204; we don't risk removing the row pre-flight
    /// because the only signal the user gets back from a failed delete is
    /// the Toast — leaving the row visible means they can retry.
    @discardableResult
    public func deleteEvent(id eventId: String) async -> Bool {
        do {
            try await api.deleteTimelineEvent(id: eventId)
            events.removeAll { $0.id == eventId }
            return true
        } catch let error as AppError {
            errorBus.publish(error)
            return false
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
            return false
        }
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

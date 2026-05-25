import XCTest
@testable import LinoWriting

/// PROJECT_PLAN v0.7 §5.C — TimelineEvent inline edit / delete.
///
/// Coverage:
/// - TimelineStore.updateEvent calls the API + swaps the local row in place
///   (so the new editedAt becomes visible without a reload)
/// - TimelineStore.deleteEvent calls the API + removes the local row
/// - TimelineEventPatchRequest encodes snake_case event_text / event_type
/// - TimelineEvent decodes `edited_at` and falls back to nil on legacy payloads
@MainActor
final class TimelineEventEditTests: XCTestCase {

    // MARK: helpers

    private func seed(_ mock: MockAPIClient, count: Int = 2) async -> [TimelineEvent] {
        let bookId = UUID().uuidString
        let characterId = UUID().uuidString
        let chapterId = UUID().uuidString
        var made: [TimelineEvent] = []
        for i in 0..<count {
            let e = TimelineEvent(
                id: UUID().uuidString,
                bookId: bookId,
                characterId: characterId,
                chapterId: chapterId,
                chapterIndex: i + 1,
                eventType: .action,
                eventText: "事件 \(i + 1)",
                createdAt: Date().addingTimeInterval(Double(-i) * 60),
                editedAt: nil
            )
            mock.timelineEvents.append(e)
            made.append(e)
        }
        return made
    }

    private func makeStore(api: MockAPIClient, bus: ErrorBus) -> TimelineStore {
        TimelineStore(api: api, errorBus: bus)
    }

    private func loadIntoStore(_ store: TimelineStore, characterId: String) async {
        store.setCharacter(characterId)
        await store.loadInitial()
    }

    // MARK: updateEvent

    func test_updateEvent_swapsLocalRowWithServerResponse() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let seeded = await seed(mock)
        let target = seeded.first!
        let store = makeStore(api: mock, bus: bus)
        await loadIntoStore(store, characterId: target.characterId)
        XCTAssertEqual(store.events.first?.id, target.id)
        XCTAssertNil(store.events.first?.editedAt, "freshly seeded event must have editedAt == nil")

        let updated = await store.updateEvent(
            id: target.id,
            eventText: "改写后的事件",
            eventType: nil
        )

        XCTAssertNotNil(updated)
        XCTAssertEqual(mock.calls.last, "updateTimelineEvent")
        let local = store.events.first { $0.id == target.id }
        XCTAssertEqual(local?.eventText, "改写后的事件")
        XCTAssertNotNil(local?.editedAt, "after a successful PATCH the local row must surface the new editedAt")
        XCTAssertNil(bus.current, "happy path must not publish to the error bus")
    }

    func test_updateEvent_failure_keepsLocalRowAndPublishesError() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let seeded = await seed(mock)
        let target = seeded.first!
        let store = makeStore(api: mock, bus: bus)
        await loadIntoStore(store, characterId: target.characterId)

        mock.errorToThrow = .conflict("乐观锁失败")
        let result = await store.updateEvent(
            id: target.id,
            eventText: "不应保存",
            eventType: nil
        )

        XCTAssertNil(result)
        // The local row must still be the original — failed PATCH must not
        // optimistically overwrite local state (the inline editor needs the
        // pristine value to restore the user's view).
        let local = store.events.first { $0.id == target.id }
        XCTAssertEqual(local?.eventText, "事件 1")
        XCTAssertNil(local?.editedAt)
        XCTAssertEqual(bus.current?.message, "乐观锁失败")
    }

    // MARK: deleteEvent

    func test_deleteEvent_removesLocalRowOnSuccess() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let seeded = await seed(mock, count: 3)
        let target = seeded[1]
        let store = makeStore(api: mock, bus: bus)
        await loadIntoStore(store, characterId: target.characterId)
        XCTAssertEqual(store.events.count, 3)

        let ok = await store.deleteEvent(id: target.id)
        XCTAssertTrue(ok)
        XCTAssertEqual(mock.calls.last, "deleteTimelineEvent")
        XCTAssertEqual(store.events.count, 2)
        XCTAssertFalse(store.events.contains { $0.id == target.id })
        XCTAssertNil(bus.current)
    }

    func test_deleteEvent_failure_keepsLocalRowAndPublishesError() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let seeded = await seed(mock, count: 2)
        let target = seeded[0]
        let store = makeStore(api: mock, bus: bus)
        await loadIntoStore(store, characterId: target.characterId)

        mock.errorToThrow = .notFound("timeline_event")
        let ok = await store.deleteEvent(id: target.id)

        XCTAssertFalse(ok)
        XCTAssertEqual(store.events.count, 2, "failed delete must leave the local list intact")
        XCTAssertTrue(store.events.contains { $0.id == target.id })
        XCTAssertNotNil(bus.current)
    }

    // MARK: Codable / wire contract

    func test_timelineEvent_decodes_editedAt_whenPresent() throws {
        let json = """
        {
          "id": "ev-1",
          "book_id": "b1",
          "character_id": "c1",
          "chapter_id": "ch1",
          "chapter_index": 1,
          "event_type": "action",
          "event_text": "改过的事件",
          "created_at": "2026-05-25T10:00:00Z",
          "edited_at": "2026-05-25T11:00:00Z"
        }
        """.data(using: .utf8)!
        let event = try CodecFactory.makeDecoder().decode(TimelineEvent.self, from: json)
        XCTAssertNotNil(event.editedAt)
        XCTAssertEqual(event.eventText, "改过的事件")
    }

    func test_timelineEvent_decodes_editedAt_fallsBackToNil_whenMissing() throws {
        // Legacy pre-v0.7 payload — no `edited_at` key. Must NOT throw and
        // must default to nil so the "已编辑" marker stays hidden.
        let json = """
        {
          "id": "ev-1",
          "book_id": "b1",
          "character_id": "c1",
          "chapter_id": "ch1",
          "chapter_index": 1,
          "event_type": "action",
          "event_text": "原始事件",
          "created_at": "2026-05-25T10:00:00Z"
        }
        """.data(using: .utf8)!
        let event = try CodecFactory.makeDecoder().decode(TimelineEvent.self, from: json)
        XCTAssertNil(event.editedAt)
    }

    func test_patchRequest_encodes_snakeCase() throws {
        let payload = TimelineEventPatchRequest(
            eventText: "新文本",
            eventType: .secretLearned
        )
        let data = try CodecFactory.makeEncoder().encode(payload)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["event_text"] as? String, "新文本")
        XCTAssertEqual(obj["event_type"] as? String, "secret_learned")
        XCTAssertNil(obj["eventText"], "must not leak camelCase key")
        XCTAssertNil(obj["eventType"], "must not leak camelCase key")
    }
}

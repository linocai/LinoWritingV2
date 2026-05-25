import XCTest
@testable import LinoWriting

/// PROJECT_PLAN v0.7 §5.D / Phase D-log — Admin Log Panel store.
///
/// Coverage:
/// - `load()` populates `entries` and drains `isLoading`.
/// - `loadMore()` appends without duplicating prior rows.
/// - `setFilter(_:)` resets `entries` and triggers a reload with the new
///   `agent_name` query param.
/// - `hasMore` flips false when the API returns a short page.
/// - Errors propagate via `ErrorBus` and don't crash the store state.
/// - The four `AgentLogFilter` cases map to the exact backend strings the
///   backend writes (`expander` / `writer` / `extractor` / `admin_reset`)
///   or `nil` for `.all`.
@MainActor
final class AgentLogStoreTests: XCTestCase {

    // MARK: helpers

    private func makeLog(
        id: String = UUID().uuidString,
        agentName: String = "writer",
        createdAt: Date,
        error: String? = nil
    ) -> AgentLog {
        AgentLog(
            id: id,
            chapterId: nil,
            agentName: agentName,
            inputPreview: "input for \(id)",
            outputPreview: "output for \(id)",
            latencyMs: 1234,
            tokensIn: 500,
            tokensOut: 700,
            error: error,
            createdAt: createdAt
        )
    }

    /// Seed `count` logs spaced 1 minute apart (newest first).
    private func seed(_ mock: MockAPIClient, count: Int, agentName: String = "writer") {
        let now = Date()
        for i in 0..<count {
            let log = makeLog(
                id: "log-\(agentName)-\(i)",
                agentName: agentName,
                createdAt: now.addingTimeInterval(Double(-i) * 60)
            )
            mock.agentLogs.append(log)
        }
    }

    // MARK: load()

    func test_load_populatesEntriesAndClearsLoadingFlag() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        seed(mock, count: 3)
        let store = AgentLogStore(api: mock, errorBus: bus, pageSize: 50)

        await store.load()

        XCTAssertEqual(store.entries.count, 3)
        XCTAssertFalse(store.isLoading, "isLoading must drain after load() completes")
        XCTAssertEqual(mock.calls.last, "listAgentLogs")
        XCTAssertNil(bus.current, "happy path must not publish to ErrorBus")
    }

    // MARK: loadMore()

    func test_loadMore_appendsWithoutDuplicates() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        // 6 rows total; pageSize=3 so loadMore appends rows 4..6.
        seed(mock, count: 6)
        let store = AgentLogStore(api: mock, errorBus: bus, pageSize: 3)

        await store.load()
        let firstPageIds = store.entries.map(\.id)
        XCTAssertEqual(firstPageIds.count, 3)

        await store.loadMore()
        let allIds = store.entries.map(\.id)
        XCTAssertEqual(allIds.count, 6, "loadMore must append exactly the next page")
        XCTAssertEqual(Set(allIds).count, 6, "no row may be duplicated across pages")
        XCTAssertEqual(Array(allIds.prefix(3)), firstPageIds, "first page rows must stay in place")
    }

    // MARK: setFilter()

    func test_setFilter_clearsAndReloadsWithNewAgentName() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        seed(mock, count: 2, agentName: "writer")
        seed(mock, count: 4, agentName: "extractor")
        let store = AgentLogStore(api: mock, errorBus: bus, pageSize: 50)

        await store.load()
        XCTAssertEqual(store.entries.count, 6, "filter = .all returns every row")

        await store.setFilter(.extractor)

        XCTAssertEqual(store.filter, .extractor)
        XCTAssertEqual(store.entries.count, 4, "switching to .extractor must return only extractor rows")
        XCTAssertTrue(
            store.entries.allSatisfy { $0.agentName == "extractor" },
            "every row in the result set must match the new filter"
        )
    }

    func test_setFilter_sameValueIsNoop() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        seed(mock, count: 3)
        let store = AgentLogStore(api: mock, errorBus: bus, pageSize: 50)

        await store.load()
        let priorCallCount = mock.calls.filter { $0 == "listAgentLogs" }.count

        await store.setFilter(.all)

        let nowCallCount = mock.calls.filter { $0 == "listAgentLogs" }.count
        XCTAssertEqual(nowCallCount, priorCallCount, "setFilter to the same value must not trigger an extra API hit")
    }

    // MARK: hasMore

    func test_hasMore_flipsFalse_whenServerReturnsShortPage() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        seed(mock, count: 2)
        // pageSize larger than total seed → first response is "short".
        let store = AgentLogStore(api: mock, errorBus: bus, pageSize: 50)

        XCTAssertTrue(store.hasMore, "default state must allow first load to attempt")
        await store.load()
        XCTAssertFalse(store.hasMore, "short page must terminate pagination")
    }

    func test_loadMore_isNoop_whenHasMoreIsFalse() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        seed(mock, count: 2)
        let store = AgentLogStore(api: mock, errorBus: bus, pageSize: 50)

        await store.load()
        XCTAssertFalse(store.hasMore)
        let callsAfterLoad = mock.calls.filter { $0 == "listAgentLogs" }.count

        await store.loadMore()
        let callsAfterLoadMore = mock.calls.filter { $0 == "listAgentLogs" }.count
        XCTAssertEqual(callsAfterLoad, callsAfterLoadMore, "loadMore must short-circuit once hasMore is false")
    }

    // MARK: error propagation

    func test_load_publishesErrorOnFailure() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        mock.errorToThrow = .transport("network down")
        let store = AgentLogStore(api: mock, errorBus: bus, pageSize: 50)

        await store.load()

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(store.isLoading, "isLoading must drain even on failure")
        XCTAssertNotNil(bus.current, "transport failures must surface via ErrorBus")
    }

    // MARK: filter value mapping (wire contract)

    func test_agentLogFilter_apiValue_matchesBackendAgentNameStrings() {
        XCTAssertNil(AgentLogStore.AgentLogFilter.all.apiValue, ".all must omit the query param")
        XCTAssertEqual(AgentLogStore.AgentLogFilter.expander.apiValue, "expander")
        XCTAssertEqual(AgentLogStore.AgentLogFilter.writer.apiValue, "writer")
        XCTAssertEqual(AgentLogStore.AgentLogFilter.extractor.apiValue, "extractor")
        XCTAssertEqual(AgentLogStore.AgentLogFilter.adminReset.apiValue, "admin_reset")
    }

    func test_agentLogFilter_displayNames_areChinese() {
        XCTAssertEqual(AgentLogStore.AgentLogFilter.all.displayName, "全部")
        XCTAssertEqual(AgentLogStore.AgentLogFilter.expander.displayName, "提纲展开")
        XCTAssertEqual(AgentLogStore.AgentLogFilter.writer.displayName, "写作")
        XCTAssertEqual(AgentLogStore.AgentLogFilter.extractor.displayName, "提取")
        XCTAssertEqual(AgentLogStore.AgentLogFilter.adminReset.displayName, "强制重置")
    }
}

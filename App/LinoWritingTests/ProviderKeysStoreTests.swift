import XCTest
@testable import LinoWriting

/// Coverage for `ProviderKeysStore` — the §5.E.6 store layer.
///
/// Network layer is faked with `MockAPIClient`, which mirrors the backend's
/// "list returns api_key masked / mutations accept full key / active summary
/// references the masked key" semantics.
@MainActor
final class ProviderKeysStoreTests: XCTestCase {

    // MARK: load

    func test_load_fillsItemsAndActive() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let store = ProviderKeysStore(api: mock, errorBus: bus)

        // Seed two keys; the first is active.
        let k1 = try! await mock.createProviderKey(ProviderKeyCreate(
            keyLabel: "主 Grok", providerHint: "xai",
            baseUrl: "https://api.x.ai/v1", apiKey: "secret_aaaa1234", modelName: "grok-4"
        ))
        _ = try! await mock.createProviderKey(ProviderKeyCreate(
            keyLabel: "OpenAI", providerHint: "openai",
            baseUrl: "https://api.openai.com/v1", apiKey: "sk-foo5678", modelName: "gpt-4o"
        ))
        _ = try! await mock.setActiveProviderKey(id: k1.id)
        mock.calls.removeAll()

        await store.load()

        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.active?.activeProviderKeyId, k1.id)
        XCTAssertEqual(store.active?.keyLabel, "主 Grok")
        XCTAssertEqual(store.active?.apiKeyMask, "****1234")
        XCTAssertTrue(mock.calls.contains("listProviderKeys"))
        XCTAssertTrue(mock.calls.contains("getActiveProviderKey"))
    }

    func test_load_emptyBackend_returnsEmptyState() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let store = ProviderKeysStore(api: mock, errorBus: bus)

        await store.load()

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNil(store.active?.activeProviderKeyId)
    }

    // MARK: create

    func test_create_addsItem_andReloadsList() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let store = ProviderKeysStore(api: mock, errorBus: bus)
        await store.load()
        XCTAssertEqual(store.items.count, 0)

        let payload = ProviderKeyCreate(
            keyLabel: "DeepSeek",
            providerHint: "deepseek",
            baseUrl: "https://api.deepseek.com/v1",
            apiKey: "ds-thisisfullkey9999",
            modelName: "deepseek-chat"
        )
        let created = await store.create(payload)

        XCTAssertNotNil(created)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.keyLabel, "DeepSeek")
        // Returned key from mock is already masked (mirrors backend).
        XCTAssertEqual(store.items.first?.apiKey, "****9999")
    }

    // MARK: update

    func test_update_modifiesField_andReloadsList() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let store = ProviderKeysStore(api: mock, errorBus: bus)

        let k = try! await mock.createProviderKey(ProviderKeyCreate(
            keyLabel: "Old Label",
            providerHint: "custom",
            baseUrl: "https://example.com/v1",
            apiKey: "secretabcd",
            modelName: "old-model"
        ))
        await store.load()
        XCTAssertEqual(store.items.first?.keyLabel, "Old Label")

        let updated = await store.update(
            id: k.id,
            payload: ProviderKeyUpdate(keyLabel: "New Label", modelName: "new-model")
        )

        XCTAssertNotNil(updated)
        XCTAssertEqual(store.items.first?.keyLabel, "New Label")
        XCTAssertEqual(store.items.first?.modelName, "new-model")
        // Untouched fields preserved.
        XCTAssertEqual(store.items.first?.baseUrl, "https://example.com/v1")
        // API key untouched — should remain the original masked form.
        XCTAssertEqual(store.items.first?.apiKey, "****abcd")
    }

    func test_update_apiKeyOnly_swapsMask() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let store = ProviderKeysStore(api: mock, errorBus: bus)
        let k = try! await mock.createProviderKey(ProviderKeyCreate(
            keyLabel: "L", providerHint: nil,
            baseUrl: "https://x.example.com/v1",
            apiKey: "old_keyAAAA", modelName: "m"
        ))
        await store.load()
        XCTAssertEqual(store.items.first?.apiKey, "****AAAA")

        await store.update(id: k.id, payload: ProviderKeyUpdate(apiKey: "brand_new_keyZZZZ"))

        XCTAssertEqual(store.items.first?.apiKey, "****ZZZZ")
    }

    /// E-3 reviewer 🟡 #3: locks the contract that an unspecified `apiKey`
    /// (left blank by the user in `SecureField`) must serialise as a *missing*
    /// JSON field, not as an empty string. The backend rejects empty strings
    /// with a 422 (`Field(min_length=1)`), so a regression here would surface
    /// as "edit key with blank password field => 422" in production.
    func test_update_payload_withNilApiKey_omitsFieldFromJson() throws {
        let payload = ProviderKeyUpdate(
            keyLabel: "新名字",
            providerHint: nil,
            baseUrl: nil,
            apiKey: nil,
            modelName: nil
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(payload)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["key_label"] as? String, "新名字")
        XCTAssertFalse(json.keys.contains("api_key"),
                       "api_key must be absent (not \"\") when SecureField is empty")
        XCTAssertFalse(json.keys.contains("provider_hint"),
                       "provider_hint must be absent when unchanged")
    }

    // MARK: delete

    func test_delete_removesItem() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let store = ProviderKeysStore(api: mock, errorBus: bus)
        let k1 = try! await mock.createProviderKey(ProviderKeyCreate(
            keyLabel: "K1", providerHint: nil, baseUrl: "https://a.example.com/v1",
            apiKey: "k1secret1111", modelName: "m"
        ))
        _ = try! await mock.createProviderKey(ProviderKeyCreate(
            keyLabel: "K2", providerHint: nil, baseUrl: "https://b.example.com/v1",
            apiKey: "k2secret2222", modelName: "m"
        ))
        await store.load()
        XCTAssertEqual(store.items.count, 2)

        await store.delete(id: k1.id)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.keyLabel, "K2")
    }

    func test_delete_activeKey_clearsActive() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let store = ProviderKeysStore(api: mock, errorBus: bus)
        let k = try! await mock.createProviderKey(ProviderKeyCreate(
            keyLabel: "Solo", providerHint: nil,
            baseUrl: "https://c.example.com/v1",
            apiKey: "solokey3333", modelName: "m"
        ))
        _ = try! await mock.setActiveProviderKey(id: k.id)
        await store.load()
        XCTAssertEqual(store.active?.activeProviderKeyId, k.id)

        await store.delete(id: k.id)

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNil(store.active?.activeProviderKeyId)
    }

    // MARK: setActive

    func test_setActive_updatesActiveSummary() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let store = ProviderKeysStore(api: mock, errorBus: bus)
        let k1 = try! await mock.createProviderKey(ProviderKeyCreate(
            keyLabel: "K1", providerHint: "xai",
            baseUrl: "https://api.x.ai/v1",
            apiKey: "secret1234", modelName: "grok-4"
        ))
        let k2 = try! await mock.createProviderKey(ProviderKeyCreate(
            keyLabel: "K2", providerHint: "openai",
            baseUrl: "https://api.openai.com/v1",
            apiKey: "secret5678", modelName: "gpt-4o"
        ))
        _ = try! await mock.setActiveProviderKey(id: k1.id)
        await store.load()
        XCTAssertEqual(store.active?.activeProviderKeyId, k1.id)

        await store.setActive(id: k2.id)

        XCTAssertEqual(store.active?.activeProviderKeyId, k2.id)
        XCTAssertEqual(store.active?.keyLabel, "K2")
        XCTAssertEqual(store.active?.modelName, "gpt-4o")
        XCTAssertEqual(store.active?.apiKeyMask, "****5678")
    }

    // MARK: error propagation

    func test_load_errorPublishesToErrorBus() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        mock.errorToThrow = .upstream("LLM down", retryable: true)
        let store = ProviderKeysStore(api: mock, errorBus: bus)

        await store.load()

        XCTAssertNotNil(bus.current)
        XCTAssertTrue(store.items.isEmpty)
    }

    // MARK: sortedItems

    func test_sortedItems_isCaseInsensitive() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        _ = try! await mock.createProviderKey(ProviderKeyCreate(
            keyLabel: "zeta", providerHint: nil, baseUrl: "https://a.example.com/v1",
            apiKey: "zk", modelName: "m"
        ))
        _ = try! await mock.createProviderKey(ProviderKeyCreate(
            keyLabel: "Alpha", providerHint: nil, baseUrl: "https://b.example.com/v1",
            apiKey: "ak", modelName: "m"
        ))
        let store = ProviderKeysStore(api: mock, errorBus: bus)
        await store.load()

        let labels = store.sortedItems.map { $0.keyLabel }
        XCTAssertEqual(labels, ["Alpha", "zeta"])
    }
}

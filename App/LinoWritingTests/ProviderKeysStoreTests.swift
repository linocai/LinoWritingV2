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

    // MARK: §5.M / M-2 per-agent active key

    /// 用 agent_role='writer' key,activate 到 writer slot → 成功且 store.activeAgents[.writer] 反映。
    func test_setActiveAgentKey_writerKey_toWriterSlot_succeeds() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let store = ProviderKeysStore(api: mock, errorBus: bus)

        let claude = try! await mock.createProviderKey(ProviderKeyCreate(
            keyLabel: "Claude 4.5",
            providerHint: "openrouter",
            baseUrl: "https://openrouter.ai/api/v1",
            apiKey: "sk-or-claudeXXXX",
            modelName: "anthropic/claude-sonnet-4.5",
            agentRole: .writer
        ))
        await store.load()
        // 初始三个 slot 都 unset.
        XCTAssertNil(store.activeAgents[.writer]?.activeProviderKeyId)

        await store.setActiveAgentKey(agentRole: .writer, providerKeyId: claude.id)

        XCTAssertNil(bus.current, "无错误时 ErrorBus 应保持 nil")
        XCTAssertEqual(store.activeAgents[.writer]?.activeProviderKeyId, claude.id)
        XCTAssertEqual(store.activeAgents[.writer]?.agentRole, .writer)
        XCTAssertEqual(store.activeAgents[.writer]?.keyLabel, "Claude 4.5")
        XCTAssertEqual(store.activeAgents[.writer]?.modelName, "anthropic/claude-sonnet-4.5")
        // 其它 slot 不应受影响.
        XCTAssertNil(store.activeAgents[.extractor]?.activeProviderKeyId)
        XCTAssertNil(store.activeAgents[.expander]?.activeProviderKeyId)
    }

    /// agent_role='writer' key 激活到 extractor slot → 409 conflict → ErrorBus 收到。
    func test_setActiveAgentKey_writerKey_toExtractorSlot_publishesConflict() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let store = ProviderKeysStore(api: mock, errorBus: bus)

        let claude = try! await mock.createProviderKey(ProviderKeyCreate(
            keyLabel: "Claude 4.5",
            providerHint: "openrouter",
            baseUrl: "https://openrouter.ai/api/v1",
            apiKey: "sk-or-claudeXXXX",
            modelName: "anthropic/claude-sonnet-4.5",
            agentRole: .writer
        ))
        await store.load()
        XCTAssertNil(bus.current)

        await store.setActiveAgentKey(agentRole: .extractor, providerKeyId: claude.id)

        // 错误应通过 ErrorBus 浮上来,而非 throw.
        XCTAssertNotNil(bus.current)
        // ErrorBus.Notice 只保留 message 字符串(§5.N 前 v0.6 实现);
        // 这里通过文案断言 conflict 来源,而非 enum case 检查。
        let msg = bus.current?.message ?? ""
        XCTAssertTrue(msg.contains("Claude 4.5") || msg.contains("Writer") || msg.contains("Extractor"),
                      "conflict 文案应当带 key 名或 slot 名,实际:\(msg)")
        // slot 不应被错误地写入.
        XCTAssertNil(store.activeAgents[.extractor]?.activeProviderKeyId)
    }

    /// setActiveAgentKey(nil) 清回 generic → store.activeAgents[role]?.activeProviderKeyId == nil。
    func test_setActiveAgentKey_nil_clearsBackToGeneric() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let store = ProviderKeysStore(api: mock, errorBus: bus)

        let grok = try! await mock.createProviderKey(ProviderKeyCreate(
            keyLabel: "Grok mini",
            providerHint: "xai",
            baseUrl: "https://api.x.ai/v1",
            apiKey: "xai-grokminiZZZZ",
            modelName: "grok-3-mini",
            agentRole: .extractor
        ))
        await store.load()
        await store.setActiveAgentKey(agentRole: .extractor, providerKeyId: grok.id)
        XCTAssertEqual(store.activeAgents[.extractor]?.activeProviderKeyId, grok.id)

        // 显式清除.
        await store.setActiveAgentKey(agentRole: .extractor, providerKeyId: nil)

        XCTAssertNil(bus.current, "清除是合法操作,不应触发 ErrorBus")
        XCTAssertNil(store.activeAgents[.extractor]?.activeProviderKeyId)
        // 但 ActiveAgentKeyRead 自身仍要 present(后端 GET 总会返一个 read shape,
        // 只是 activeProviderKeyId 为 nil).
        XCTAssertEqual(store.activeAgents[.extractor]?.agentRole, .extractor)
        // mock 记录到的最后一次 PUT payload 应当 carry nil(契约测试:
        // ActiveAgentKeyUpdate 编码时 nil 要变成 explicit JSON null,而不是
        // 被 JSONEncoder 默认行为省略).
        XCTAssertEqual(mock.lastSetActiveAgentPayload?.role, .extractor)
        XCTAssertNil(mock.lastSetActiveAgentPayload?.providerKeyId)
    }

    /// load() 应该并发 fetch 三个 per-agent slot,store.activeAgents 三 key 都 present。
    func test_load_populatesAllThreeAgentSlots() async {
        let mock = MockAPIClient()
        let bus = ErrorBus()
        let store = ProviderKeysStore(api: mock, errorBus: bus)

        await store.load()

        // 即使三个 slot 都没绑 key,GET 也会返回 ActiveAgentKeyRead(role, nil, …)。
        XCTAssertEqual(store.activeAgents[.writer]?.agentRole, .writer)
        XCTAssertEqual(store.activeAgents[.extractor]?.agentRole, .extractor)
        XCTAssertEqual(store.activeAgents[.expander]?.agentRole, .expander)
        XCTAssertNil(store.activeAgents[.writer]?.activeProviderKeyId)
        XCTAssertNil(store.activeAgents[.extractor]?.activeProviderKeyId)
        XCTAssertNil(store.activeAgents[.expander]?.activeProviderKeyId)
        // 并发 fetch 都打出去.
        XCTAssertEqual(mock.calls.filter { $0 == "getActiveAgentKey" }.count, 3)
    }

    /// `ActiveAgentKeyUpdate(providerKeyId: nil)` 序列化必须 emit `null`,而非省略字段。
    /// 后端用 null 作为"清除"信号(`exclude_unset` 区分未传 vs 传 null);如果
    /// JSON 不含 `provider_key_id` 键,后端会把这当成"未传"而保持现状,UI 与后端
    /// 行为脱节。
    func test_activeAgentKeyUpdate_nil_emitsExplicitJsonNull() throws {
        let payload = ActiveAgentKeyUpdate(providerKeyId: nil)
        let data = try JSONEncoder().encode(payload)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(json.keys.contains("provider_key_id"),
                      "nil 必须 emit `provider_key_id: null`,不能省略字段")
        XCTAssertTrue(json["provider_key_id"] is NSNull,
                      "字段值必须是 JSON null")
    }

    /// `ProviderKeyCreate.agentRole = nil` 应当 emit 字段省略(或 null,后端等价处理),
    /// 而 `.writer` 应序列化成 `"writer"` snake_case。
    func test_providerKeyCreate_agentRole_serializesAsSnakeCase() throws {
        let payload = ProviderKeyCreate(
            keyLabel: "Claude",
            providerHint: "openrouter",
            baseUrl: "https://openrouter.ai/api/v1",
            apiKey: "sk-or-XXXX",
            modelName: "anthropic/claude-sonnet-4.5",
            agentRole: .writer
        )
        let data = try JSONEncoder().encode(payload)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["agent_role"] as? String, "writer",
                       "agent_role 必须 snake_case,值为 enum rawValue")
        XCTAssertFalse(json.keys.contains("agentRole"),
                       "不应 leak camelCase 字段")
    }

    /// `ProviderKeyUpdate` 三态 agentRole 序列化契约:
    ///   - `.untouched` → 不写 `agent_role` 键
    ///   - `.set(.expander)` → `"agent_role": "expander"`
    ///   - `.clear` → `"agent_role": null`(显式清回 generic)
    func test_providerKeyUpdate_agentRole_triState_serialization() throws {
        let enc = JSONEncoder()

        let untouched = ProviderKeyUpdate(keyLabel: "x", agentRole: .untouched)
        let untouchedJson = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try enc.encode(untouched)) as? [String: Any]
        )
        XCTAssertFalse(untouchedJson.keys.contains("agent_role"),
                       "`.untouched` 必须省略 agent_role 键(对齐后端 exclude_unset)")

        let set = ProviderKeyUpdate(keyLabel: "x", agentRole: .set(.expander))
        let setJson = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try enc.encode(set)) as? [String: Any]
        )
        XCTAssertEqual(setJson["agent_role"] as? String, "expander")

        let clear = ProviderKeyUpdate(keyLabel: "x", agentRole: .clear)
        let clearJson = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try enc.encode(clear)) as? [String: Any]
        )
        XCTAssertTrue(clearJson.keys.contains("agent_role"))
        XCTAssertTrue(clearJson["agent_role"] is NSNull,
                      "`.clear` 必须 emit JSON null,而非省略键")
    }

    /// `ProviderKey` 解码缺失 `agent_role` 字段 → fallback nil(老 payload 容错,
    /// 与 §5.A.6 Chapter.source 同款模式)。
    func test_providerKey_decoding_missingAgentRole_fallbacksToNil() throws {
        let json = """
        {
          "id": "abc",
          "key_label": "Legacy",
          "base_url": "https://api.x.ai/v1",
          "api_key": "****1234",
          "model_name": "grok-4",
          "created_at": "2025-01-01T00:00:00Z",
          "updated_at": "2025-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!
        let key = try CodecFactory.makeDecoder().decode(ProviderKey.self, from: json)
        XCTAssertNil(key.agentRole)
        XCTAssertEqual(key.keyLabel, "Legacy")
    }

    /// `ProviderKey` 解码带 `agent_role: "extractor"` → round-trip 拿到 .extractor。
    func test_providerKey_decoding_withAgentRole_roundTrips() throws {
        let json = """
        {
          "id": "abc",
          "key_label": "Grok mini",
          "provider_hint": "xai",
          "base_url": "https://api.x.ai/v1",
          "api_key": "****ZZZZ",
          "model_name": "grok-3-mini",
          "agent_role": "extractor",
          "created_at": "2025-01-01T00:00:00Z",
          "updated_at": "2025-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!
        let key = try CodecFactory.makeDecoder().decode(ProviderKey.self, from: json)
        XCTAssertEqual(key.agentRole, .extractor)
    }

    /// `ActiveAgentKeyRead` 解码: agent_role 路径段映射到 enum,nullable 字段省略时 nil。
    func test_activeAgentKeyRead_decoding_emptySlot() throws {
        let json = """
        {
          "agent_role": "writer",
          "active_provider_key_id": null,
          "key_label": null,
          "provider_hint": null,
          "model_name": null,
          "api_key_mask": null
        }
        """.data(using: .utf8)!
        let read = try CodecFactory.makeDecoder().decode(ActiveAgentKeyRead.self, from: json)
        XCTAssertEqual(read.agentRole, .writer)
        XCTAssertNil(read.activeProviderKeyId)
        XCTAssertNil(read.keyLabel)
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

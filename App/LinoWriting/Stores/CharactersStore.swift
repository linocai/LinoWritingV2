import Foundation
import SwiftUI

@MainActor
public final class CharactersStore: ObservableObject {

    @Published public private(set) var characters: [Character] = []
    @Published public private(set) var isLoading: Bool = false
    @Published public var selectedCharacterId: String?
    @Published public var showNewCharacterSheet: Bool = false
    /// IDs whose live_fields were touched by the last finalize call.
    /// Cleared when the user opens the card to edit it.
    @Published public var pendingHighlightIds: Set<String> = []

    private let api: APIClientProtocol
    private let errorBus: ErrorBus
    private var currentBookId: String?

    public init(api: APIClientProtocol, errorBus: ErrorBus) {
        self.api = api
        self.errorBus = errorBus
    }

    public func load(bookId: String) async {
        currentBookId = bookId
        isLoading = true
        defer { isLoading = false }
        do {
            characters = try await api.listCharacters(bookId: bookId)
            // Keep selection if still present, else pick first.
            if let sel = selectedCharacterId, characters.contains(where: { $0.id == sel }) {
                // ok
            } else {
                selectedCharacterId = characters.first?.id
            }
        } catch let error as AppError {
            errorBus.publish(error)
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
        }
    }

    public func reset() {
        characters = []
        selectedCharacterId = nil
        pendingHighlightIds = []
        currentBookId = nil
    }

    public func selected() -> Character? {
        guard let id = selectedCharacterId else { return characters.first }
        return characters.first(where: { $0.id == id })
    }

    public func select(_ id: String) {
        selectedCharacterId = id
        // Visiting the card clears its highlight.
        pendingHighlightIds.remove(id)
    }

    public func create(name: String, role: String?) async -> Character? {
        guard let bookId = currentBookId else { return nil }
        do {
            let new = try await api.createCharacter(
                bookId: bookId,
                CharacterCreateRequest(name: name, role: role)
            )
            characters.append(new)
            selectedCharacterId = new.id
            showNewCharacterSheet = false
            return new
        } catch let error as AppError {
            errorBus.publish(error); return nil
        } catch {
            errorBus.publish(.transport(error.localizedDescription)); return nil
        }
    }

    public func delete(_ character: Character) async {
        do {
            try await api.deleteCharacter(id: character.id)
            characters.removeAll { $0.id == character.id }
            if selectedCharacterId == character.id {
                selectedCharacterId = characters.first?.id
            }
        } catch let error as AppError {
            errorBus.publish(error)
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
        }
    }

    public func patch(_ character: Character, _ payload: CharacterPatchRequest) async {
        do {
            let updated = try await api.patchCharacter(id: character.id, payload)
            if let idx = characters.firstIndex(where: { $0.id == character.id }) {
                characters[idx] = updated
            }
        } catch let error as AppError {
            errorBus.publish(error)
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
        }
    }

    // MARK: Inline field updates

    public func updateName(_ character: Character, to value: String) async {
        await patch(character, CharacterPatchRequest(name: value))
    }

    public func updateRole(_ character: Character, to value: String) async {
        await patch(character, CharacterPatchRequest(role: value))
    }

    public func updateFrozenField(_ character: Character, key: String, value: JSONValue) async {
        var fields = character.frozenFields
        fields[key] = value
        await patch(character, CharacterPatchRequest(frozenFields: fields))
    }

    public func updateLiveField(_ character: Character, key: String, value: JSONValue) async {
        var fields = character.liveFields
        fields[key] = value
        await patch(character, CharacterPatchRequest(liveFields: fields))
    }

    public func removeFrozenField(_ character: Character, key: String) async {
        var fields = character.frozenFields
        fields.removeValue(forKey: key)
        await patch(character, CharacterPatchRequest(frozenFields: fields))
    }

    public func removeLiveField(_ character: Character, key: String) async {
        var fields = character.liveFields
        fields.removeValue(forKey: key)
        await patch(character, CharacterPatchRequest(liveFields: fields))
    }

    /// Mark a set of characters as "Agent-modified" so their cards show a red dot.
    public func markUpdated(_ ids: [String]) {
        pendingHighlightIds.formUnion(ids)
    }
}

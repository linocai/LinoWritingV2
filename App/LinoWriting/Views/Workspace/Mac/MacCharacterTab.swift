#if os(macOS)
import SwiftUI

/// v1.1.0 (FF) Phase 3 — 角色 tab. Character chip row (logo avatar + name,
/// red dot when `pending_field_highlights` non-empty) + "+ 角色"; selected
/// character card in three segments: 固定设定 (frozen_fields, locked grey),
/// 动态字段 (live_fields, orange dot before pending keys), 作者笔记
/// (author_notes, purple block); card-head delete. Field tap = inline edit,
/// PATCH live_fields auto-clears the dot (backend). macOS-only.
///
/// v1.3.0 (II) P1 — editing completeness: all three sections now support
/// add ("+ 字段"/"+ 笔记") and per-row delete; frozen_fields is no longer
/// locked-read-only (author owns it at book-open time, extractor never
/// touches it — see PROJECT_PLAN §4.0); card-head name/role become
/// inline-editable. All wired to existing `CharactersStore` methods
/// (updateFrozenField/updateLiveField/updateAuthorNote/removeFrozenField/
/// removeLiveField/removeAuthorNote/updateName/updateRole) — zero backend
/// change.
struct MacCharacterTab: View {
    let book: Book

    @EnvironmentObject var charactersStore: CharactersStore
    @EnvironmentObject var chaptersStore: ChaptersStore

    @State private var newCharName = ""
    @State private var showNewChar = false
    @State private var showImportChars = false
    @State private var pendingDelete: Character?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            chipRow
            if let character = charactersStore.selected() {
                card(character)
            } else {
                emptyCard
            }
        }
        .padding(.top, 2)
        .sheet(isPresented: $showNewChar) { newCharSheet }
        .sheet(isPresented: $showImportChars) {
            MacImportCharactersSheet(book: book)
        }
        .alert("删除这个角色？",
               isPresented: .constant(pendingDelete != nil),
               presenting: pendingDelete) { ch in
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                let target = ch
                pendingDelete = nil
                Task { await charactersStore.delete(target) }
            }
        } message: { ch in
            Text("《\(ch.name)》及其所有时间线事件都会被删除。")
        }
    }

    // MARK: - Chips

    private var chipRow: some View {
        FlowLayout(spacing: 8) {
            ForEach(charactersStore.characters) { ch in
                chip(ch)
            }
            addChipButton
            importCharsButton
        }
    }

    private func chip(_ ch: Character) -> some View {
        let selected = charactersStore.selectedCharacterId == ch.id
        let hasDot = charactersStore.cardHasPendingHighlight(ch)
        return Button { charactersStore.select(ch.id) } label: {
            HStack(spacing: 8) {
                avatar(ch.name, size: 24, font: 12)
                Text(ch.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LWColor.bodyText)
            }
            .padding(.leading, 7).padding(.trailing, 11).padding(.vertical, 6)
            .background(
                selected ? LWColor.accentStart.opacity(0.12) : LWColor.hex(0x787D96, opacity: 0.07),
                in: Capsule()
            )
            .overlay(
                Capsule().stroke(selected ? LWColor.accentStart.opacity(0.35) : Color.clear, lineWidth: 0.5)
            )
            .overlay(alignment: .topTrailing) {
                if hasDot {
                    Circle().fill(LWColor.fieldDot)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(Color.white, lineWidth: 1))
                        .offset(x: 2, y: -1)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { pointer($0) }
    }

    private var addChipButton: some View {
        Button { newCharName = ""; showNewChar = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                Text("角色").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(LWColor.mutedText)
            .padding(.leading, 11).padding(.trailing, 13).padding(.vertical, 6)
            .background(LWColor.hex(0x787D96, opacity: 0.07), in: Capsule())
            .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 0.5, dash: [3]))
                .foregroundStyle(LWColor.hex(0x282D46, opacity: 0.18)))
        }
        .buttonStyle(.plain)
        .onHover { pointer($0) }
    }

    /// v1.3.0 (II/JJ) P6 — "导入人物卡" moved here from the deleted 大纲 tab
    /// (`MacOutlineTab`). Opens `MacImportCharactersSheet` (paste-text LLM
    /// parse, the only import path since P2).
    private var importCharsButton: some View {
        Button { showImportChars = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 12, weight: .semibold))
                Text("导入人物卡").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(LWColor.mutedText)
            .padding(.leading, 11).padding(.trailing, 13).padding(.vertical, 6)
            .background(LWColor.hex(0x787D96, opacity: 0.07), in: Capsule())
            .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 0.5, dash: [3]))
                .foregroundStyle(LWColor.hex(0x282D46, opacity: 0.18)))
        }
        .buttonStyle(.plain)
        .onHover { pointer($0) }
    }

    // MARK: - Card

    private func card(_ character: Character) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // head
            HStack(alignment: .top, spacing: 11) {
                avatar(character.name, size: 40, font: 18, radius: 11)
                VStack(alignment: .leading, spacing: 4) {
                    MacCardHeadField(
                        value: character.name,
                        font: LWFont.songti(16, weight: .bold),
                        color: LWColor.titleText,
                        placeholder: "姓名…",
                        allowsEmpty: false
                    ) { newValue in
                        Task { await charactersStore.updateName(character, to: newValue) }
                    }
                    MacCardHeadField(
                        value: character.role ?? "",
                        font: .system(size: 12),
                        color: LWColor.mutedText3,
                        placeholder: "身份 · 可留空"
                    ) { newValue in
                        Task { await charactersStore.updateRole(character, to: newValue) }
                    }
                }
                Spacer()
                LWIconButton(systemName: "trash", foreground: LWColor.danger, size: 30, fontSize: 13, help: "删除角色") {
                    pendingDelete = character
                }
            }

            segment("固定设定 · 开书录入", color: LWColor.mutedText3) {
                fieldList(character, fields: character.frozenFields, kind: .frozen)
                addFieldButton(kind: .frozen) { key, value in
                    Task { await charactersStore.updateFrozenField(character, key: key, value: .string(value)) }
                }
            }
            segment("动态字段 · 随剧情更新", color: LWColor.hex(0x1F7A8C)) {
                fieldList(character, fields: character.liveFields, kind: .live)
                addFieldButton(kind: .live) { key, value in
                    Task { await charactersStore.updateLiveField(character, key: key, value: .string(value)) }
                }
            }
            segment("作者笔记 · 仅供理解，不入正文", color: LWColor.authorNote) {
                noteList(character)
                addNoteButton { key, value in
                    Task { await charactersStore.updateAuthorNote(character, key: key, value: .string(value)) }
                }
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.66))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(LWColor.hex(0x282D46, opacity: 0.08), lineWidth: 0.5)
        )
    }

    private var emptyCard: some View {
        Text("还没有角色。点「＋ 角色」逐张录入，或「导入人物卡」粘贴人设文本自动解析。")
            .font(.system(size: 13)).foregroundStyle(LWColor.mutedText3)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
    }

    @ViewBuilder
    private func segment<Content: View>(_ title: String, color: Color, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LWSectionLabel(title, color: color)
            content()
        }
    }

    private enum FieldKind { case frozen, live }

    @ViewBuilder
    private func fieldList(_ character: Character, fields: [String: JSONValue], kind: FieldKind) -> some View {
        if fields.isEmpty {
            Text("—").font(.system(size: 12.5)).foregroundStyle(LWColor.mutedText3)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(fields.keys.sorted(), id: \.self) { key in
                    MacFieldRow(
                        key: key,
                        value: stringValue(fields[key]),
                        pending: kind == .live && character.pendingFieldHighlights[key] != nil,
                        editable: true
                    ) { newValue in
                        switch kind {
                        case .live:
                            Task { await charactersStore.updateLiveField(character, key: key, value: .string(newValue)) }
                        case .frozen:
                            Task { await charactersStore.updateFrozenField(character, key: key, value: .string(newValue)) }
                        }
                    } onDelete: {
                        switch kind {
                        case .live:
                            Task { await charactersStore.removeLiveField(character, key: key) }
                        case .frozen:
                            Task { await charactersStore.removeFrozenField(character, key: key) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func noteList(_ character: Character) -> some View {
        if character.authorNotes.isEmpty {
            Text("—").font(.system(size: 12.5)).foregroundStyle(LWColor.mutedText3)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(character.authorNotes.keys.sorted(), id: \.self) { key in
                    MacNoteRow(key: key, value: stringValue(character.authorNotes[key])) { newValue in
                        Task { await charactersStore.updateAuthorNote(character, key: key, value: .string(newValue)) }
                    } onDelete: {
                        Task { await charactersStore.removeAuthorNote(character, key: key) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func addFieldButton(kind: FieldKind, onAdd: @escaping (String, String) -> Void) -> some View {
        MacAddFieldRow(placeholder: kind == .frozen ? "＋ 字段" : "＋ 字段", onAdd: onAdd)
    }

    @ViewBuilder
    private func addNoteButton(onAdd: @escaping (String, String) -> Void) -> some View {
        MacAddFieldRow(placeholder: "＋ 笔记", onAdd: onAdd)
    }

    // MARK: - New char sheet

    private var newCharSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("新增角色").font(LWFont.songti(18, weight: .semibold)).foregroundStyle(LWColor.titleText)
            VStack(alignment: .leading, spacing: 8) {
                LWSectionLabel("名字")
                TextField("角色名…", text: $newCharName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submitNewChar)
            }
            HStack {
                Button("取消") { showNewChar = false }
                    .buttonStyle(.plain).foregroundStyle(LWColor.secondaryText)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                LWPrimaryButton(title: "创建", height: 36, enabled: !newCharName.trimmingCharacters(in: .whitespaces).isEmpty) {
                    submitNewChar()
                }
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private func submitNewChar() {
        let name = newCharName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            _ = await charactersStore.create(name: name, role: nil)
            showNewChar = false
        }
    }

    // MARK: - Helpers

    private func avatar(_ name: String, size: CGFloat, font: CGFloat, radius: CGFloat? = nil) -> some View {
        Group {
            if let r = radius {
                RoundedRectangle(cornerRadius: r, style: .continuous).fill(LWColor.logoGradient)
            } else {
                Circle().fill(LWColor.logoGradient)
            }
        }
        .frame(width: size, height: size)
        .overlay(
            Text(String(name.prefix(1)))
                .font(LWFont.songti(font, weight: .semibold))
                .foregroundStyle(.white)
        )
    }

    private func stringValue(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        switch value {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "是" : "否"
        case .array(let a): return a.map { stringValue($0) }.joined(separator: "、")
        case .object: return ""
        case .null: return ""
        }
    }
}

// MARK: - Field row (frozen / live)

private struct MacFieldRow: View {
    let key: String
    let value: String
    let pending: Bool
    let editable: Bool
    let onCommit: (String) -> Void
    let onDelete: () -> Void

    @State private var editing = false
    @State private var draft = ""
    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            HStack(spacing: 5) {
                if pending {
                    Circle().fill(LWColor.fieldDot).frame(width: 6, height: 6)
                }
                Text(key)
                    .font(.system(size: 12.5))
                    .foregroundStyle(LWColor.mutedText3)
            }
            .frame(minWidth: 52, alignment: .leading)

            if editing {
                TextField("", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(LWColor.bodyText)
                    .focused($focused)
                    .onChange(of: focused) { _, f in if !f { commit() } }
                    .onSubmit { commit() }
            } else {
                Text(value.isEmpty ? "—" : value)
                    .font(.system(size: 12.5))
                    .foregroundStyle(LWColor.bodyText)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { if editable { startEdit() } }
            }

            if editable {
                Button(action: onDelete) {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(LWColor.danger.opacity(hovered ? 0.9 : 0.5))
                }
                .buttonStyle(.plain)
                .help("删除字段")
                .onHover { h in hovered = h; pointer(h) }
            }
        }
    }

    private func startEdit() {
        draft = value
        editing = true
        DispatchQueue.main.async { focused = true }
    }
    private func commit() {
        editing = false
        if draft != value { onCommit(draft) }
    }
}

// MARK: - Author note row (purple block)

private struct MacNoteRow: View {
    let key: String
    let value: String
    let onCommit: (String) -> Void
    let onDelete: () -> Void

    @State private var editing = false
    @State private var draft = ""
    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Group {
                if editing {
                    TextField("", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundStyle(LWColor.secondaryText)
                        .focused($focused)
                        .onChange(of: focused) { _, f in if !f { commit() } }
                        .onSubmit { commit() }
                } else {
                    (Text("\(key) · ").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(LWColor.authorNote)
                     + Text(value).font(.system(size: 12.5)).foregroundStyle(LWColor.secondaryText))
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { startEdit() }
                }
            }
            Button(action: onDelete) {
                Image(systemName: "minus.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(LWColor.danger.opacity(hovered ? 0.9 : 0.5))
            }
            .buttonStyle(.plain)
            .help("删除笔记")
            .onHover { h in hovered = h; pointer(h) }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(LWColor.hex(0x9A6BE0, opacity: 0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func startEdit() {
        draft = value
        editing = true
        DispatchQueue.main.async { focused = true }
    }
    private func commit() {
        editing = false
        if draft != value { onCommit(draft) }
    }
}

// MARK: - Card-head inline-editable field (name / role)

/// v1.3.0 (II) P1 — tap-to-edit name/role in the card head, same inline
/// pattern as `MacFieldRow` (commit on blur/return, no-op if unchanged).
///
/// 审后修复 🟡#1: `allowsEmpty` gates whether a blank commit is legal.
/// name (`allowsEmpty: false`) treats a cleared field as a cancelled edit —
/// draft is discarded and `onCommit` is never called, so the store/PATCH
/// path is untouched. role (`allowsEmpty: true`, default) keeps the
/// original behavior — blank is a valid "no role" value.
private struct MacCardHeadField: View {
    let value: String
    let font: Font
    let color: Color
    let placeholder: String
    var allowsEmpty: Bool = true
    let onCommit: (String) -> Void

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if editing {
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .font(font)
                .foregroundStyle(color)
                .focused($focused)
                .onChange(of: focused) { _, f in if !f { commit() } }
                .onSubmit { commit() }
        } else {
            Text(value.isEmpty ? placeholder : value)
                .font(font)
                .foregroundStyle(value.isEmpty ? LWColor.mutedText3 : color)
                .contentShape(Rectangle())
                .onTapGesture { startEdit() }
        }
    }

    private func startEdit() {
        draft = value
        editing = true
        DispatchQueue.main.async { focused = true }
    }
    private func commit() {
        editing = false
        if let resolved = CardHeadFieldCommit.resolve(draft: draft, original: value, allowsEmpty: allowsEmpty) {
            onCommit(resolved)
        }
    }
}

// MARK: - "+ 字段 / + 笔记" add row

/// v1.3.0 (II) P1 — section-tail add control shared by 固定设定/动态字段/作者笔记.
/// Collapsed = dashed "＋ 字段" pill; tapped = key+value input pair; key
/// trimmed-non-empty is required to submit (mirrors the create-character
/// name-required gate).
private struct MacAddFieldRow: View {
    let placeholder: String
    let onAdd: (String, String) -> Void

    @State private var adding = false
    @State private var key = ""
    @State private var value = ""
    @FocusState private var keyFocused: Bool

    var body: some View {
        if adding {
            HStack(spacing: 8) {
                TextField("字段名…", text: $key)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(LWColor.mutedText3)
                    .frame(minWidth: 60, maxWidth: 90, alignment: .leading)
                    .focused($keyFocused)
                TextField("内容…", text: $value, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(LWColor.bodyText)
                    .onSubmit(submit)
                Button("添加", action: submit)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(canSubmit ? LWColor.accentText : LWColor.mutedText3)
                    .disabled(!canSubmit)
                Button {
                    adding = false; key = ""; value = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundStyle(LWColor.mutedText3)
                }
                .buttonStyle(.plain)
            }
            .onAppear { keyFocused = true }
        } else {
            Button {
                adding = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                    Text(placeholder).font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(LWColor.mutedText3)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(
                    Capsule().strokeBorder(style: StrokeStyle(lineWidth: 0.5, dash: [3]))
                        .foregroundStyle(LWColor.hex(0x282D46, opacity: 0.18))
                )
            }
            .buttonStyle(.plain)
            .onHover { pointer($0) }
        }
    }

    private var canSubmit: Bool {
        !key.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func submit() {
        let trimmedKey = key.trimmingCharacters(in: .whitespaces)
        guard !trimmedKey.isEmpty else { return }
        onAdd(trimmedKey, value)
        adding = false
        key = ""; value = ""
    }
}

// MARK: - Import characters sheet (paste full character-sheet prose → LLM parse)

/// v1.3.0 (II) P2 — "导入人物卡" upgraded from "one name per line → blank
/// card" to "粘贴整段人物设定文本，自动解析成角色卡" (the only import path;
/// the old batch-blank-card mode is fully removed, no SegmentedControl).
/// Manual per-field card creation still exists via the "＋ 角色" button
/// above — a separate, independent entry point.
///
/// v1.3.0 (JJ) P6 — moved here from the deleted `MacOutlineTab.swift` (大纲
/// tab removal); the trigger button now lives in `MacCharacterTab.chipRow`.
struct MacImportCharactersSheet: View {
    let book: Book
    @EnvironmentObject var charactersStore: CharactersStore
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var isSubmitting = false
    @State private var emptyResultNotice = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导入人物卡").font(LWFont.songti(18, weight: .semibold)).foregroundStyle(LWColor.titleText)
            Text("粘贴整段人物设定文本，自动解析成角色卡。")
                .font(.system(size: 12)).foregroundStyle(LWColor.mutedText3)
            LWTextArea(text: $text, placeholder: "粘贴人物设定文本…", minHeight: 240, font: LWFont.songti(13.5), lineSpacing: 6)
            if emptyResultNotice {
                Text("未能从文本解析出角色。")
                    .font(.system(size: 12)).foregroundStyle(LWColor.warning)
            }
            HStack {
                Button("取消") { dismiss() }.buttonStyle(.plain).foregroundStyle(LWColor.secondaryText).keyboardShortcut(.cancelAction)
                Spacer()
                LWPrimaryButton(
                    title: isSubmitting ? "解析中…" : "解析导入",
                    height: 36,
                    enabled: !isSubmitting && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    submit()
                }
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func submit() {
        isSubmitting = true
        emptyResultNotice = false
        Task {
            let result = await charactersStore.importFromText(bookId: book.id, rawText: text)
            isSubmitting = false
            if let result {
                if result.isEmpty {
                    emptyResultNotice = true
                } else {
                    dismiss()
                }
            }
            // nil (error) case: errorBus already published a Toast, sheet
            // stays open so the author can retry or edit the pasted text.
        }
    }
}

#endif

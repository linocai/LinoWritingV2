#if os(iOS)
import SwiftUI

/// v1.2.0 (GG, P3) — 角色 segment of the iOS book-detail screen.
///
/// Handoff `LinoWriting iOS.dc.html` 屏2 角色 tab:
///   - horizontally-scrolling character chips (logo avatar + name, **red dot**
///     when `pending_field_highlights` non-empty) + "＋ 角色"
///     (`POST /books/{id}/characters`).
///   - selected character card in three segments:
///       固定设定 · 锁定 (frozen_fields, grey, locked)
///       动态字段 · 随剧情更新 (live_fields, **orange dot** before pending keys)
///       作者笔记 · 仅供理解，不入正文 (author_notes, purple block)
///     card-head delete (`DELETE /characters/{id}`).
///   - field tap = inline edit (`PATCH /characters/{id}`); editing a live_fields
///     key auto-clears its orange dot (backend clears `pending_field_highlights`).
///
/// Mirrors `MacCharacterTab`'s logic (same Stores) reflowed for iPhone full
/// width. iOS-only.
struct IOSCharactersSection: View {
    let book: Book

    @EnvironmentObject var charactersStore: CharactersStore

    @State private var showNewChar = false
    @State private var pendingDelete: Character?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            chipRow
            if let character = charactersStore.selected() {
                card(character)
            } else {
                emptyCard
            }
        }
        .sheet(isPresented: $showNewChar) {
            IOSNewCharacterSheet()
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

    // MARK: - Chip row (horizontal scroll)

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(charactersStore.characters) { ch in
                    chip(ch)
                }
                addChipButton
            }
            .padding(.vertical, 2)
        }
    }

    private func chip(_ ch: Character) -> some View {
        let selected = charactersStore.selectedCharacterId == ch.id
        let hasDot = charactersStore.cardHasPendingHighlight(ch)
        return Button { charactersStore.select(ch.id) } label: {
            HStack(spacing: 8) {
                avatar(ch.name, size: 24, font: 12)
                Text(ch.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(selected ? LWColor.accentDeep : LWColor.bodyText)
            }
            .padding(.leading, 7).padding(.trailing, 13).padding(.vertical, 6)
            .background(
                selected ? LWColor.accentStart.opacity(0.14) : Color.white.opacity(0.7),
                in: Capsule()
            )
            .overlay(
                Capsule().stroke(
                    selected ? LWColor.accentStart.opacity(0.32) : LWColor.hex(0x282D46, opacity: 0.08),
                    lineWidth: 0.5
                )
            )
            .overlay(alignment: .topTrailing) {
                if hasDot {
                    Circle().fill(LWColor.danger)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(Color.white, lineWidth: 1))
                        .offset(x: 1, y: -1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var addChipButton: some View {
        Button { showNewChar = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                Text("角色").font(.system(size: 13.5, weight: .semibold))
            }
            .foregroundStyle(LWColor.mutedText)
            .padding(.horizontal, 13).padding(.vertical, 6)
            .background(LWColor.hex(0x787D96, opacity: 0.07), in: Capsule())
            .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 0.5, dash: [3]))
                .foregroundStyle(LWColor.hex(0x282D46, opacity: 0.18)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Card

    private func card(_ character: Character) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // head
            HStack(spacing: 12) {
                avatar(character.name, size: 44, font: 20, radius: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(character.name)
                        .font(LWFont.songti(18, weight: .bold))
                        .foregroundStyle(LWColor.titleText)
                    Text(character.role?.nonEmptyOr("角色") ?? "角色")
                        .font(.system(size: 12.5)).foregroundStyle(LWColor.mutedText3)
                }
                Spacer()
                Button { pendingDelete = character } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(LWColor.danger)
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(LWColor.hex(0x282D46, opacity: 0.1), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }

            segment("固定设定 · 锁定", color: LWColor.mutedText3) {
                fieldList(character, fields: character.frozenFields, kind: .frozen)
            }
            segment("动态字段 · 随剧情更新", color: LWColor.hex(0x1F7A8C)) {
                fieldList(character, fields: character.liveFields, kind: .live)
            }
            segment("作者笔记 · 仅供理解，不入正文", color: LWColor.authorNote) {
                noteList(character)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(LWColor.hex(0x282D46, opacity: 0.08), lineWidth: 0.5)
        )
    }

    private var emptyCard: some View {
        Text("还没有角色。点「＋ 角色」逐张录入，或在大纲里导入人物卡。")
            .font(.system(size: 13)).foregroundStyle(LWColor.mutedText3)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
    }

    @ViewBuilder
    private func segment<Content: View>(_ title: String, color: Color, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.1 * 11)
                .foregroundStyle(color)
            content()
        }
    }

    private enum FieldKind { case frozen, live }

    @ViewBuilder
    private func fieldList(_ character: Character, fields: [String: JSONValue], kind: FieldKind) -> some View {
        if fields.isEmpty {
            Text("—").font(.system(size: 13)).foregroundStyle(LWColor.mutedText3)
        } else {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(fields.keys.sorted(), id: \.self) { key in
                    IOSCharFieldRow(
                        key: key,
                        value: stringValue(fields[key]),
                        pending: kind == .live && character.pendingFieldHighlights[key] != nil,
                        editable: kind == .live
                    ) { newValue in
                        Task { await charactersStore.updateLiveField(character, key: key, value: .string(newValue)) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func noteList(_ character: Character) -> some View {
        if character.authorNotes.isEmpty {
            Text("—").font(.system(size: 13)).foregroundStyle(LWColor.mutedText3)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(character.authorNotes.keys.sorted(), id: \.self) { key in
                    IOSCharNoteRow(key: key, value: stringValue(character.authorNotes[key])) { newValue in
                        Task { await charactersStore.updateAuthorNote(character, key: key, value: .string(newValue)) }
                    }
                }
            }
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

// MARK: - Field row (frozen / live, inline edit on tap)

private struct IOSCharFieldRow: View {
    let key: String
    let value: String
    let pending: Bool
    let editable: Bool
    let onCommit: (String) -> Void

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            HStack(spacing: 5) {
                if pending {
                    Circle().fill(LWColor.fieldDot).frame(width: 6, height: 6)
                }
                Text(key)
                    .font(.system(size: 13))
                    .foregroundStyle(LWColor.mutedText3)
            }
            .frame(minWidth: 54, alignment: .leading)

            if editing {
                TextField("", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(LWColor.bodyText)
                    .focused($focused)
                    .onChange(of: focused) { _, f in if !f { commit() } }
                    .onSubmit { commit() }
            } else {
                Text(value.isEmpty ? "—" : value)
                    .font(.system(size: 13))
                    .foregroundStyle(LWColor.bodyText)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { if editable { startEdit() } }
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

// MARK: - Author note row (purple block, inline edit on tap)

private struct IOSCharNoteRow: View {
    let key: String
    let value: String
    let onCommit: (String) -> Void

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(LWColor.secondaryText)
                    .focused($focused)
                    .onChange(of: focused) { _, f in if !f { commit() } }
                    .onSubmit { commit() }
            } else {
                (Text("\(key) · ").font(.system(size: 13, weight: .semibold)).foregroundStyle(LWColor.authorNote)
                 + Text(value).font(.system(size: 13)).foregroundStyle(LWColor.secondaryText))
                    .lineSpacing(2.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { startEdit() }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(LWColor.hex(0x9A6BE0, opacity: 0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

// MARK: - New character sheet

struct IOSNewCharacterSheet: View {
    @EnvironmentObject var charactersStore: CharactersStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var role = ""
    @State private var isSubmitting = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field("名字", text: $name, placeholder: "角色名…", serif: true).focused($nameFocused)
                    field("身份 · 可留空", text: $role, placeholder: "如：领航员 · 主角", serif: false)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }
            .background(LWColor.hex(0xF2F2F7))
            .navigationTitle("新增角色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.foregroundStyle(LWColor.accentText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: submit) {
                        if isSubmitting { ProgressView() } else { Text("创建").fontWeight(.semibold) }
                    }
                    .foregroundStyle(canSubmit ? LWColor.accentText : LWColor.mutedText)
                    .disabled(!canSubmit)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { nameFocused = true }
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String, serif: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(LWColor.secondaryText)
            TextField(placeholder, text: text)
                .font(serif ? LWFont.songti(16) : .system(size: 15))
                .foregroundStyle(LWColor.bodyText)
                .submitLabel(.done)
                .onSubmit(submit)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: LWMetrics.controlRadius, style: .continuous).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: LWMetrics.controlRadius, style: .continuous).stroke(LWColor.hex(0x282D46, opacity: 0.12), lineWidth: 0.5))
        }
    }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !isSubmitting
    }

    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        Task {
            _ = await charactersStore.create(
                name: name.trimmingCharacters(in: .whitespaces),
                role: role.trimmingCharacters(in: .whitespaces).nonEmptyOrNil
            )
            isSubmitting = false
            dismiss()
        }
    }
}

private extension String {
    var nonEmptyOrNil: String? { isEmpty ? nil : self }
}
#endif

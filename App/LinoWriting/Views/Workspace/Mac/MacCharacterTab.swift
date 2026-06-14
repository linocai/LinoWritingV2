#if os(macOS)
import SwiftUI

/// v1.1.0 (FF) Phase 3 — 角色 tab. Character chip row (logo avatar + name,
/// red dot when `pending_field_highlights` non-empty) + "+ 角色"; selected
/// character card in three segments: 固定设定 (frozen_fields, locked grey),
/// 动态字段 (live_fields, orange dot before pending keys), 作者笔记
/// (author_notes, purple block); card-head delete. Field tap = inline edit,
/// PATCH live_fields auto-clears the dot (backend). macOS-only.
struct MacCharacterTab: View {
    let book: Book

    @EnvironmentObject var charactersStore: CharactersStore
    @EnvironmentObject var chaptersStore: ChaptersStore

    @State private var newCharName = ""
    @State private var showNewChar = false
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

    // MARK: - Card

    private func card(_ character: Character) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // head
            HStack(spacing: 11) {
                avatar(character.name, size: 40, font: 18, radius: 11)
                VStack(alignment: .leading, spacing: 2) {
                    Text(character.name)
                        .font(LWFont.songti(16, weight: .bold))
                        .foregroundStyle(LWColor.titleText)
                    Text(character.role?.nonEmpty ?? "角色")
                        .font(.system(size: 12)).foregroundStyle(LWColor.mutedText3)
                }
                Spacer()
                LWIconButton(systemName: "trash", foreground: LWColor.danger, size: 30, fontSize: 13, help: "删除角色") {
                    pendingDelete = character
                }
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
        .padding(16)
        .background(Color.white.opacity(0.66))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(LWColor.hex(0x282D46, opacity: 0.08), lineWidth: 0.5)
        )
    }

    private var emptyCard: some View {
        Text("还没有角色。点「+ 角色」或在大纲里导入人物卡。")
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
            Text("—").font(.system(size: 12.5)).foregroundStyle(LWColor.mutedText3)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(character.authorNotes.keys.sorted(), id: \.self) { key in
                    MacNoteRow(key: key, value: stringValue(character.authorNotes[key])) { newValue in
                        Task { await charactersStore.updateAuthorNote(character, key: key, value: .string(newValue)) }
                    }
                }
            }
        }
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

    @State private var editing = false
    @State private var draft = ""
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

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
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

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
#endif

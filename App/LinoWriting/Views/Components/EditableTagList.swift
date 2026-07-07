import SwiftUI

/// v1.3.1 (KK) P6 — cross-platform editable tag list for `[String]`-shaped
/// `StructuredPrompt` fields (`mustHappen` / `mustNotHappen` / `focusTraits`).
/// Mirrors the "+ 字段/+ 笔记" add-row pattern `MacCharacterTab`'s
/// `MacAddFieldRow` established for `[String: JSONValue]` dictionaries (v1.3.0
/// II P1), reshaped for bare string arrays: each tag renders with a small
/// trailing "×" delete affordance, plus a trailing dashed "＋ 添加" pill that
/// expands into a single-field text input on tap. Reuses the glass-styled
/// `LWTagChip` colors and the existing `FlowLayout` (`InlineEditableTags.swift`)
/// rather than the older `InlineEditableTags` component's plain-style chips,
/// so this reads consistently with stage2's other tag groups
/// (`MacChapterEditor.tagGroup` / `IOSChapterEditPlaceholder.tagGroup`).
///
/// `maxCount` (used by `focusTraits`, capped at 2 per PROJECT_PLAN §4 P6) hides
/// the add control once the cap is reached rather than disabling it silently —
/// a short caption explains why.
struct EditableTagList: View {
    let items: [String]
    let tagFg: Color
    let tagBg: Color
    var maxCount: Int? = nil
    var addPlaceholder: String = "输入内容…"
    let onAdd: (String) -> Void
    let onRemove: (Int) -> Void

    @State private var adding = false
    @State private var draft = ""
    @FocusState private var draftFocused: Bool

    private var atCap: Bool {
        if let maxCount { return items.count >= maxCount }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    removableTag(item, index: index)
                }
                if !atCap {
                    addControl
                }
            }
            if let maxCount, atCap {
                Text("最多选 \(maxCount) 个，删除一个才能再加。")
                    .font(.system(size: 11))
                    .foregroundStyle(LWColor.mutedText3)
            }
        }
    }

    private func removableTag(_ text: String, index: Int) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(tagFg)
            Button { onRemove(index) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(tagFg.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(tagBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var addControl: some View {
        if adding {
            HStack(spacing: 6) {
                TextField(addPlaceholder, text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .frame(minWidth: 90, maxWidth: 160)
                    .focused($draftFocused)
                    .onSubmit(submit)
                Button("添加", action: submit)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(canSubmit ? LWColor.accentText : LWColor.mutedText3)
                    .disabled(!canSubmit)
                Button {
                    adding = false; draft = ""
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(LWColor.mutedText3)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Color.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onAppear { draftFocused = true }
        } else {
            Button { adding = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
                    Text("添加").font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(LWColor.mutedText3)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(
                    Capsule().strokeBorder(style: StrokeStyle(lineWidth: 0.5, dash: [3]))
                        .foregroundStyle(LWColor.hex(0x282D46, opacity: 0.18))
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var canSubmit: Bool {
        !draft.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func submit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onAdd(trimmed)
        adding = false
        draft = ""
    }
}

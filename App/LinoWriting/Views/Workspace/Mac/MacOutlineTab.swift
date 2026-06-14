#if os(macOS)
import SwiftUI

/// v1.1.0 (FF) Phase 3 — 大纲 tab. Explanation + "⇪ 导入总大纲"
/// (`ingestOutline`) / "导入人物卡" + a large living Songti outline editor
/// bound to `OutlineStore` (blur → `patchOutline`). macOS-only.
struct MacOutlineTab: View {
    let book: Book

    @EnvironmentObject var outlineStore: OutlineStore
    @EnvironmentObject var charactersStore: CharactersStore

    @State private var draft = ""
    @State private var showImportOutline = false
    @State private var showImportChars = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("全书骨架 · 故事线 ＋ 人物简介。开篇时从对话 AI 里磨好约 5000 字总大纲，导入这里；之后剧情走偏，随手改两笔——大纲是活的，每一章都会读它。")
                .font(.system(size: 12))
                .foregroundStyle(LWColor.mutedText3)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                LWPrimaryButton(title: "导入总大纲", systemImage: "square.and.arrow.up", height: 36, horizontalPadding: 14) {
                    showImportOutline = true
                }
                LWBorderedButton(title: "导入人物卡", height: 36) { showImportChars = true }
            }

            LWSectionLabel("活体大纲 · 可随时手改")

            LWTextArea(
                text: $draft,
                placeholder: "粘贴或编辑全书大纲…",
                minHeight: 430,
                font: LWFont.songti(13.5),
                lineSpacing: 6
            )
            .focused($focused)
            .onChange(of: focused) { _, f in if !f { commit() } }
        }
        .task(id: book.id) {
            if outlineStore.loadedBookId != book.id { await outlineStore.load(bookId: book.id) }
            // Unconditional initial sync — the task runs once per book before
            // any user edit, so it's safe to seed the draft even if the editor
            // has grabbed focus on mount.
            syncDraft()
        }
        // `outline` is the @Published source of truth (rawText is computed, so
        // observing it directly won't fire). Re-sync the draft when it lands.
        .onChange(of: outlineStore.outline) { _, _ in if !focused { syncDraft() } }
        .sheet(isPresented: $showImportOutline) {
            MacOutlineImportSheet(book: book)
        }
        .sheet(isPresented: $showImportChars) {
            MacImportCharactersSheet(book: book)
        }
    }

    private func syncDraft() { draft = outlineStore.rawText }

    private func commit() {
        guard draft != outlineStore.rawText else { return }
        Task { await outlineStore.patch(bookId: book.id, rawText: draft) }
    }
}

// MARK: - Outline import sheet (paste prose → ingest)

struct MacOutlineImportSheet: View {
    let book: Book
    @EnvironmentObject var outlineStore: OutlineStore
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导入总大纲").font(LWFont.songti(18, weight: .semibold)).foregroundStyle(LWColor.titleText)
            Text("粘贴你打磨好的全书大纲（散文体，约 5000 字）。导入会覆盖现有大纲。")
                .font(.system(size: 12)).foregroundStyle(LWColor.mutedText3)
            LWTextArea(text: $text, placeholder: "粘贴全书大纲…", minHeight: 280, font: LWFont.songti(13.5), lineSpacing: 6)
            HStack {
                Button("取消") { dismiss() }.buttonStyle(.plain).foregroundStyle(LWColor.secondaryText).keyboardShortcut(.cancelAction)
                Spacer()
                LWPrimaryButton(title: outlineStore.isSaving ? "导入中…" : "导入", height: 36, enabled: !outlineStore.isSaving && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    Task {
                        if await outlineStore.ingest(bookId: book.id, rawText: text) != nil { dismiss() }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

// MARK: - Import characters sheet (one name per line → createCharacter)

struct MacImportCharactersSheet: View {
    let book: Book
    @EnvironmentObject var charactersStore: CharactersStore
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导入人物卡").font(LWFont.songti(18, weight: .semibold)).foregroundStyle(LWColor.titleText)
            Text("每行一个角色名，批量创建空白角色卡；之后在「角色」tab 里补设定。")
                .font(.system(size: 12)).foregroundStyle(LWColor.mutedText3)
            LWTextArea(text: $text, placeholder: "林渊\n沈清\n…", minHeight: 200, font: LWFont.songti(13.5), lineSpacing: 6)
            HStack {
                Button("取消") { dismiss() }.buttonStyle(.plain).foregroundStyle(LWColor.secondaryText).keyboardShortcut(.cancelAction)
                Spacer()
                LWPrimaryButton(title: isSubmitting ? "导入中…" : "创建", height: 36, enabled: !isSubmitting && !names.isEmpty) {
                    submit()
                }
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private var names: [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func submit() {
        isSubmitting = true
        Task {
            for name in names { _ = await charactersStore.create(name: name, role: nil) }
            isSubmitting = false
            dismiss()
        }
    }
}
#endif

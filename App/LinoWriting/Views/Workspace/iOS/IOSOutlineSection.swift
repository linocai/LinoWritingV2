#if os(iOS)
import SwiftUI

/// v1.2.0 (GG, P3) — 大纲 segment of the iOS book-detail screen.
///
/// Handoff `LinoWriting iOS.dc.html` 屏2 大纲 tab:
///   - explanation prose (全书骨架 · 故事线 ＋ 人物简介…大纲是活的，每章都会读它).
///   - "⇪ 导入总大纲" (`POST /books/{id}/outline/ingest`) + "导入人物卡"
///     (`POST /books/{id}/characters`, batch from one-name-per-line).
///   - 活体大纲 · 可随时手改 — a large Songti `LWTextArea` bound to
///     `OutlineStore` (blur → `PATCH /books/{id}/outline`).
///
/// Mirrors `MacOutlineTab` reflowed for iPhone full width. The `LWTextArea`
/// auto-grabs focus on mount, so the initial draft sync uses `.task(id:)`
/// (unconditional, runs once per book before any edit) per the CLAUDE.md坑;
/// `onChange(of: outline)` guards against overwriting an in-progress edit.
/// iOS-only.
struct IOSOutlineSection: View {
    let book: Book

    @EnvironmentObject var outlineStore: OutlineStore

    @State private var draft = ""
    @State private var showImportOutline = false
    @State private var showImportChars = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("全书骨架 · 故事线 ＋ 人物简介。开篇时从对话 AI 磨好约 5000 字总大纲导入；剧情走偏随手改两笔——大纲是活的，每章都会读它。")
                .font(.system(size: 13))
                .foregroundStyle(LWColor.mutedText3)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button { showImportOutline = true } label: {
                    Text("⇪ 导入总大纲")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(LWColor.accentGradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: LWColor.accentStop.opacity(0.8), radius: 8, y: 6)
                }
                .buttonStyle(.plain)

                Button { showImportChars = true } label: {
                    Text("导入人物卡")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(LWColor.secondaryText2)
                        .padding(.horizontal, 16)
                        .frame(height: 42)
                        .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(LWColor.hex(0x282D46, opacity: 0.12), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }

            Text("活体大纲 · 可随时手改")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.1 * 11)
                .foregroundStyle(LWColor.mutedText3)

            LWTextArea(
                text: $draft,
                placeholder: "粘贴或编辑全书大纲…",
                minHeight: 360,
                font: LWFont.songti(14.5),
                lineSpacing: 8,
                background: Color.white.opacity(0.7)
            )
            .focused($focused)
            .onChange(of: focused) { _, f in if !f { commit() } }
        }
        .task(id: book.id) {
            if outlineStore.loadedBookId != book.id { await outlineStore.load(bookId: book.id) }
            syncDraft()
        }
        .onChange(of: outlineStore.outline) { _, _ in if !focused { syncDraft() } }
        .sheet(isPresented: $showImportOutline) {
            IOSOutlineImportSheet(book: book)
        }
        .sheet(isPresented: $showImportChars) {
            IOSImportCharactersSheet(book: book)
        }
    }

    private func syncDraft() { draft = outlineStore.rawText }

    private func commit() {
        guard draft != outlineStore.rawText else { return }
        Task { await outlineStore.patch(bookId: book.id, rawText: draft) }
    }
}

// MARK: - Outline import sheet (paste prose → ingest)

struct IOSOutlineImportSheet: View {
    let book: Book
    @EnvironmentObject var outlineStore: OutlineStore
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("粘贴你打磨好的全书大纲（散文体，约 5000 字）。导入会覆盖现有大纲。")
                        .font(.system(size: 12.5)).foregroundStyle(LWColor.mutedText3)
                    LWTextArea(text: $text, placeholder: "粘贴全书大纲…", minHeight: 320, font: LWFont.songti(14), lineSpacing: 7, background: Color.white)
                }
                .padding(.horizontal, 20).padding(.top, 14)
            }
            .background(LWColor.hex(0xF2F2F7))
            .navigationTitle("导入总大纲")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.foregroundStyle(LWColor.accentText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { if await outlineStore.ingest(bookId: book.id, rawText: text) != nil { dismiss() } }
                    } label: {
                        if outlineStore.isSaving { ProgressView() } else { Text("导入").fontWeight(.semibold) }
                    }
                    .foregroundStyle(canSubmit ? LWColor.accentText : LWColor.mutedText)
                    .disabled(!canSubmit)
                }
            }
        }
        .presentationDetents([.large])
    }

    private var canSubmit: Bool {
        !outlineStore.isSaving && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Import characters sheet (one name per line → createCharacter)

struct IOSImportCharactersSheet: View {
    let book: Book
    @EnvironmentObject var charactersStore: CharactersStore
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("每行一个角色名，批量创建空白角色卡；之后在「角色」里补设定。")
                        .font(.system(size: 12.5)).foregroundStyle(LWColor.mutedText3)
                    LWTextArea(text: $text, placeholder: "林晚\n沈砚\n…", minHeight: 240, font: LWFont.songti(14), lineSpacing: 7, background: Color.white)
                }
                .padding(.horizontal, 20).padding(.top, 14)
            }
            .background(LWColor.hex(0xF2F2F7))
            .navigationTitle("导入人物卡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.foregroundStyle(LWColor.accentText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: submit) {
                        if isSubmitting { ProgressView() } else { Text("创建").fontWeight(.semibold) }
                    }
                    .foregroundStyle(names.isEmpty ? LWColor.mutedText : LWColor.accentText)
                    .disabled(names.isEmpty || isSubmitting)
                }
            }
        }
        .presentationDetents([.large])
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

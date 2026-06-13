import SwiftUI

/// v1.0.0 EE §5.5 — the book-level 大纲面板 (outline panel).
///
/// Plain-prose only, **no「消化」button** (§5.5): the author pastes their
/// ~5000-word outline into one TextEditor, then either 摄入 (first save, when
/// the book never ingested) or 保存 (living-outline hand-edit) it. The display
/// surface and the ingest surface are the same TextEditor — the author 回看s
/// the stored text in it and hand-edits in place, exactly the §5.1 contract.
///
/// Presented as a sheet from the workspace toolbar so it renders identically on
/// macOS / iPad / iPhone. The pinned header + scrolling body + pinned footer
/// layout follows the import-sheet fix from v0.9.3 (avoids button clipping);
/// the macOS-only `.frame(minWidth:)` is `#if os(macOS)`-guarded per the iOS
/// layout铁律 (a bare minWidth would overflow an iPhone and push edge content
/// off-screen — the v0.9.4/0.9.5 white-screen root cause).
public struct OutlinePanelView: View {
    let book: Book

    @EnvironmentObject var outlineStore: OutlineStore
    @Environment(\.dismiss) private var dismiss

    /// Editable draft. Seeded from the loaded outline; the author types here.
    @State private var draft: String = ""
    /// True once the draft diverges from the stored text — enables 保存.
    @State private var dirty: Bool = false
    /// Tracks whether we've done the initial load → seed so re-renders don't
    /// clobber the author's in-progress typing.
    @State private var didSeed: Bool = false

    public init(book: Book) { self.book = book }

    /// First save uses 摄入 (ingest) when nothing exists yet; subsequent saves
    /// use 保存 (patch). Mirrors the §5.1 endpoint split.
    private var hasStoredOutline: Bool {
        (outlineStore.outline?.rawText?.isEmpty == false)
    }

    private var saveButtonTitle: String {
        hasStoredOutline ? "保存" : "摄入"
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            editorBody
            Divider()
            footer
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 680, minHeight: 480, idealHeight: 620)
        #endif
        .task {
            await outlineStore.load(bookId: book.id)
            seedDraftIfNeeded()
        }
        .onChange(of: outlineStore.outline) { _, _ in
            seedDraftIfNeeded()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("全书大纲")
                    .font(.title3.weight(.semibold))
                Text("把你在对话框 AI 磨好的 ~5000 字总提纲粘贴进来；这是优化师每章 just-in-time 读的静态计划。纯散文，作者手改才变。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("完成") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    // MARK: Editor

    @ViewBuilder
    private var editorBody: some View {
        if outlineStore.isLoading && !didSeed {
            ProgressView("加载中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !hasStoredOutline && draft.isEmpty {
                    Text("还没有大纲。把总提纲粘贴到下面，点「摄入」保存。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                TextEditor(text: $draft)
                    .font(.system(.body))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
                    )
                    .onChange(of: draft) { _, newValue in
                        dirty = (newValue != (outlineStore.outline?.rawText ?? ""))
                    }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(draft.count) 字")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if let updated = outlineStore.outline?.updatedAt {
                Text("上次保存 \(Self.timeFormatter.string(from: updated))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if outlineStore.isSaving {
                ProgressView().controlSize(.small)
            }
            Button(saveButtonTitle) {
                Task { await saveOutline() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(outlineStore.isSaving || !dirty)
            #if os(macOS)
            .keyboardShortcut("s", modifiers: .command)
            #endif
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Actions

    private func seedDraftIfNeeded() {
        // Only seed from the server copy while the author hasn't started
        // editing — otherwise a late load()/onChange would wipe their typing.
        guard !dirty else { return }
        let stored = outlineStore.outline?.rawText ?? ""
        if draft != stored {
            draft = stored
        }
        didSeed = true
    }

    private func saveOutline() async {
        let text = draft
        let saved: BookOutline?
        if hasStoredOutline {
            saved = await outlineStore.patch(bookId: book.id, rawText: text)
        } else {
            saved = await outlineStore.ingest(bookId: book.id, rawText: text)
        }
        if saved != nil {
            // Server copy is now authoritative and == draft → clear dirty.
            dirty = false
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
}

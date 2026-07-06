#if os(macOS)
import SwiftUI

/// v1.1.0 (FF) Phase 3 — 设定 tab. 作品名称 (`patchBook`) / 封面色 6 swatch /
/// 世界观设定 (world_setting) / 文风指令 (style_directive) / "删除整本作品…"
/// (`deleteBook` → back to shelf). macOS-only.
struct MacBookSettingsTab: View {
    let book: Book

    @EnvironmentObject var appStore: AppStore
    @EnvironmentObject var bookStore: BookStore
    @EnvironmentObject var bookshelfStore: BookshelfStore
    @EnvironmentObject var charactersStore: CharactersStore
    @EnvironmentObject var chaptersStore: ChaptersStore
    @EnvironmentObject var chapterEditorStore: ChapterEditorStore
    @EnvironmentObject var timelineStore: TimelineStore

    @State private var titleDraft = ""
    @State private var worldDraft = ""
    @State private var styleDraft = ""
    @State private var showDeleteConfirm = false
    @FocusState private var titleFocused: Bool
    @FocusState private var worldFocused: Bool
    @FocusState private var styleFocused: Bool

    private var current: Book { bookStore.book ?? book }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LWSectionLabel("作品名称")
            TextField("作品名称", text: $titleDraft)
                .textFieldStyle(.plain)
                .font(LWFont.songti(15, weight: .semibold))
                .foregroundStyle(LWColor.bodyText)
                .padding(.horizontal, 13).frame(height: 38)
                .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(LWColor.hex(0x282D46, opacity: 0.1), lineWidth: 0.5))
                .focused($titleFocused)
                .onChange(of: titleFocused) { _, f in if !f { commitTitle() } }
                .onSubmit { commitTitle() }
                .padding(.bottom, 14)

            LWSectionLabel("封面颜色")
            HStack(spacing: 9) {
                ForEach(LWColor.coverSwatchNames, id: \.self) { name in
                    swatch(name)
                }
            }
            .padding(.bottom, 18)

            LWSectionLabel("世界观设定")
            LWTextArea(text: $worldDraft, placeholder: "这个世界的设定…", minHeight: 110, font: .system(size: 13), lineSpacing: 4)
                .focused($worldFocused)
                .onChange(of: worldFocused) { _, f in if !f { commitWorld() } }
                .padding(.bottom, 16)

            LWSectionLabel("文风指令")
            LWTextArea(text: $styleDraft, placeholder: "希望 Writer 遵循的文风…", minHeight: 80, font: .system(size: 13), lineSpacing: 4)
                .focused($styleFocused)
                .onChange(of: styleFocused) { _, f in if !f { commitStyle() } }
                .padding(.bottom, 16)

            Divider().overlay(LWMetrics.hairlineLight)
            Button { showDeleteConfirm = true } label: {
                Text("删除整本作品…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LWColor.danger)
                    .frame(maxWidth: .infinity).frame(height: 36)
                    .background(LWColor.danger.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(LWColor.danger.opacity(0.28), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .onHover { pointer($0) }
            .padding(.top, 16)
        }
        .onAppear { syncDrafts() }
        .onChange(of: current.id) { _, _ in syncDrafts() }
        .alert("确定删除整本作品？", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { deleteBook() }
        } message: {
            Text("《\(current.title)》及其所有章节、角色、时间线都会被删除，不可恢复。")
        }
    }

    private func swatch(_ name: String) -> some View {
        let selected = (current.coverColor ?? "indigo") == name
        return Button { setCover(name) } label: {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LWColor.coverGradient(name))
                .frame(width: 30, height: 30)
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).inset(by: -3).stroke(Color.white, lineWidth: 2).opacity(selected ? 1 : 0))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).inset(by: -4).stroke(LWColor.accentStart, lineWidth: 2).opacity(selected ? 1 : 0))
                .padding(4)
        }
        .buttonStyle(.plain)
        .onHover { pointer($0) }
    }

    // MARK: - Actions

    private func syncDrafts() {
        titleDraft = current.title
        worldDraft = current.worldSetting ?? ""
        styleDraft = current.styleDirective ?? ""
    }

    private func commitTitle() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != current.title else { titleDraft = current.title; return }
        Task {
            await bookStore.patchTitle(trimmed)
            syncToShelf()
        }
    }
    private func commitWorld() {
        guard worldDraft != (current.worldSetting ?? "") else { return }
        Task { await bookStore.patchWorldSetting(worldDraft) }
    }
    private func commitStyle() {
        guard styleDraft != (current.styleDirective ?? "") else { return }
        Task { await bookStore.patchStyleDirective(styleDraft) }
    }
    private func setCover(_ name: String) {
        guard name != current.coverColor else { return }
        Task {
            await bookStore.patchCoverColor(name)
            syncToShelf()
        }
    }

    private func syncToShelf() {
        if let updated = bookStore.book {
            appStore.updateCurrentBook(updated)
            bookshelfStore.upsert(updated)
        }
    }

    private func deleteBook() {
        let target = current
        Task {
            await bookshelfStore.delete(target)
            chapterEditorStore.reset()
            chaptersStore.reset()
            charactersStore.reset()
            timelineStore.reset()
            appStore.closeBook()
        }
    }
}
#endif

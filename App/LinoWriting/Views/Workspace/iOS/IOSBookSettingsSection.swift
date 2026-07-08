#if os(iOS)
import SwiftUI

/// v1.2.0 (GG, P3) — 设定 segment of the iOS book-detail screen.
///
/// Handoff `LinoWriting iOS.dc.html` 屏2 设定 tab:
///   - 作品名称 (Songti input, `PATCH /books/{id}` title).
///   - 封面颜色: 6 named swatches (`PATCH /books/{id}` cover_color).
///   - 世界观设定 (`world_setting`), blur → `PATCH /books/{id}`.
///   - 导出整本… (`GET /books/{id}/export`) / 删除整本作品… (`DELETE /books/{id}`).
///
/// Mirrors `MacBookSettingsTab` reflowed for iPhone full width. Editing the
/// title / cover also syncs the shelf cache + open-book metadata so the change
/// shows on the next shelf visit. iOS-only.
/// v1.5.0 (NN) P2 — 「文风指令」输入框已删（全局 `style_directive` 退场，
/// 全书文风底色载体移到 Writer 人格）。v1.5.2 已于全链删除（DB 列/后端 schema/
/// 前端字段一并移除）。
struct IOSBookSettingsSection: View {
    let book: Book

    @EnvironmentObject var appStore: AppStore
    @EnvironmentObject var bookStore: BookStore
    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var chaptersStore: ChaptersStore
    @EnvironmentObject var charactersStore: CharactersStore
    @EnvironmentObject var timelineStore: TimelineStore

    @State private var titleDraft = ""
    @State private var worldDraft = ""
    @State private var showExportSheet = false
    @State private var showDeleteConfirm = false
    @FocusState private var titleFocused: Bool
    @FocusState private var worldFocused: Bool

    private var current: Book { bookStore.book ?? book }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            label("作品名称")
            TextField("作品名称", text: $titleDraft)
                .font(LWFont.songti(16, weight: .semibold))
                .foregroundStyle(LWColor.bodyText)
                .padding(.horizontal, 14).frame(height: 42)
                .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(LWColor.hex(0x282D46, opacity: 0.1), lineWidth: 0.5))
                .focused($titleFocused)
                .onChange(of: titleFocused) { _, f in if !f { commitTitle() } }
                .onSubmit { commitTitle() }
                .padding(.bottom, 16)

            label("封面颜色")
            HStack(spacing: 10) {
                ForEach(LWColor.coverSwatchNames, id: \.self) { name in
                    swatch(name)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 18)

            label("世界观设定")
            LWTextArea(text: $worldDraft, placeholder: "这个世界的设定…", minHeight: 110, font: .system(size: 13.5), lineSpacing: 5, background: Color.white.opacity(0.7))
                .focused($worldFocused)
                .onChange(of: worldFocused) { _, f in if !f { commitWorld() } }
                .padding(.bottom, 16)

            Button { showExportSheet = true } label: {
                Text("导出整本…")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LWColor.secondaryText2)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(LWColor.hex(0x282D46, opacity: 0.12), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 10)

            Button { showDeleteConfirm = true } label: {
                Text("删除整本作品…")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LWColor.danger)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(LWColor.danger.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(LWColor.danger.opacity(0.28), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { syncDrafts() }
        .onChange(of: current.id) { _, _ in syncDrafts() }
        .sheet(isPresented: $showExportSheet) {
            IOSExportBookSheet(book: current)
        }
        .alert("确定删除整本作品？", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { deleteBook() }
        } message: {
            Text("《\(current.title)》及其所有章节、角色、时间线都会被删除，不可恢复。")
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .tracking(0.1 * 11)
            .foregroundStyle(LWColor.mutedText3)
            .padding(.bottom, 9)
    }

    private func swatch(_ name: String) -> some View {
        let selected = (current.coverColor ?? "indigo") == name
        return Button { setCover(name) } label: {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LWColor.coverGradient(name))
                .frame(width: 34, height: 34)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).inset(by: -3).stroke(Color.white, lineWidth: 2).opacity(selected ? 1 : 0))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).inset(by: -4).stroke(LWColor.accentStart, lineWidth: 2).opacity(selected ? 1 : 0))
                .padding(4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func syncDrafts() {
        titleDraft = current.title
        worldDraft = current.worldSetting ?? ""
    }

    private func commitTitle() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != current.title else { titleDraft = current.title; return }
        Task { await bookStore.patchTitle(trimmed); syncToShelf() }
    }
    private func commitWorld() {
        guard worldDraft != (current.worldSetting ?? "") else { return }
        Task { await bookStore.patchWorldSetting(worldDraft) }
    }
    private func setCover(_ name: String) {
        guard name != current.coverColor else { return }
        Task { await bookStore.patchCoverColor(name); syncToShelf() }
    }

    private func syncToShelf() {
        if let updated = bookStore.book {
            appStore.updateCurrentBook(updated)
            environment.bookshelfStore.upsert(updated)
        }
    }

    private func deleteBook() {
        let target = current
        Task {
            await environment.bookshelfStore.delete(target)
            chaptersStore.reset()
            charactersStore.reset()
            timelineStore.reset()
            appStore.closeBook()
        }
    }
}

// MARK: - Export book sheet (format + include-drafts → GET /books/{id}/export)

/// iOS variant of `MacExportSheet`. `GET /books/{id}/export` (format markdown/txt,
/// include_drafts) → `FileSaver` (the iOS `UIDocumentPicker` path).
struct IOSExportBookSheet: View {
    let book: Book

    @EnvironmentObject var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var format: ExportFormat = .markdown
    @State private var includeDrafts = false
    @State private var isExporting = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("格式").font(.system(size: 12, weight: .semibold)).foregroundStyle(LWColor.secondaryText)
                        Picker("", selection: $format) {
                            ForEach(ExportFormat.allCases, id: \.self) { f in
                                Text(f.displayName).tag(f)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    Toggle(isOn: $includeDrafts) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("包含未定稿章节").font(.system(size: 14)).foregroundStyle(LWColor.bodyText)
                            Text("默认只导出已完成章节").font(.system(size: 12)).foregroundStyle(LWColor.mutedText3)
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.top, 16)
            }
            .background(LWColor.hex(0xF2F2F7))
            .navigationTitle("导出整本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.foregroundStyle(LWColor.accentText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: runExport) {
                        if isExporting { ProgressView() } else { Text("导出").fontWeight(.semibold) }
                    }
                    .foregroundStyle(LWColor.accentText)
                    .disabled(isExporting)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func runExport() {
        guard !isExporting else { return }
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                let (data, suggested) = try await environment.apiClient.exportBook(
                    id: book.id, format: format, includeDrafts: includeDrafts
                )
                try await FileSaver.save(data: data, suggestedFilename: suggested)
                dismiss()
            } catch let error as AppError {
                environment.errorBus.publish(error)
            } catch {
                environment.errorBus.publish(.transport(error.localizedDescription))
            }
        }
    }
}
#endif

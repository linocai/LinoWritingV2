#if os(iOS)
import SwiftUI

/// v1.2.0 (GG, P2) — iPhone "新建作品" sheet.
///
/// Title field + 6-swatch cover-colour picker, then `POST /books`
/// (`BookCreateRequest(title:coverColor:)`). `cover_color` is stored as one of
/// the six author-facing names (`indigo`/`rose`/`green`/`amber`/`teal`/`slate`)
/// so `LWColor.coverGradient(name:)` resolves it on the shelf — matching the
/// handoff's `coverColors` convention. Mirrors `MacNewBookSheet`'s logic; the
/// shell is an iOS form sheet (medium detent) with the new glass look.
///
/// Unlike the old `NewBookSheet`, creating a book here does **not** auto-open
/// it — the shelf simply gains the new card (the handoff library's `newBook`
/// only POSTs; the author taps the card to push into it). iOS-only.
struct IOSNewBookSheet: View {
    @EnvironmentObject var bookshelfStore: BookshelfStore
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var coverColor = LWColor.coverSwatchNames.first ?? "indigo"
    @State private var isSubmitting = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    titleField
                    coverPicker
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .background(LWColor.hex(0xF2F2F7))
            .navigationTitle("新建作品")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(LWColor.accentText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: submitIfReady) {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("创建").fontWeight(.semibold)
                        }
                    }
                    .foregroundStyle(canSubmit ? LWColor.accentText : LWColor.mutedText)
                    .disabled(!canSubmit)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { titleFocused = true }
    }

    // MARK: - Title

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("作品名称")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LWColor.secondaryText)
            TextField("给这部作品起个名字…", text: $title)
                .font(LWFont.songti(16))
                .foregroundStyle(LWColor.bodyText)
                .focused($titleFocused)
                .submitLabel(.done)
                .onSubmit(submitIfReady)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: LWMetrics.controlRadius, style: .continuous)
                        .fill(Color.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: LWMetrics.controlRadius, style: .continuous)
                        .stroke(LWColor.hex(0x282D46, opacity: 0.12), lineWidth: 0.5)
                )
        }
    }

    // MARK: - Cover swatches

    private var coverPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("封面色")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LWColor.secondaryText)
            HStack(spacing: 14) {
                ForEach(LWColor.coverSwatchNames, id: \.self) { name in
                    swatch(name)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func swatch(_ name: String) -> some View {
        let selected = coverColor == name
        return Button { coverColor = name } label: {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LWColor.coverGradient(name))
                .frame(width: 34, height: 34)
                // ring: 0 0 0 2px #fff, 0 0 0 4px #5B7CFF (white inner, accent outer).
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .inset(by: -3)
                        .stroke(Color.white, lineWidth: 2)
                        .opacity(selected ? 1 : 0)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .inset(by: -4)
                        .stroke(LWColor.accentStart, lineWidth: 2)
                        .opacity(selected ? 1 : 0)
                )
                .padding(4)
        }
        .buttonStyle(.plain)
    }

    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && !isSubmitting
    }

    private func submitIfReady() {
        guard canSubmit else { return }
        isSubmitting = true
        Task {
            _ = await bookshelfStore.create(
                title: title.trimmingCharacters(in: .whitespaces),
                coverColor: coverColor
            )
            isSubmitting = false
            dismiss()
        }
    }
}
#endif

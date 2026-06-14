#if os(macOS)
import SwiftUI

/// v1.1.0 (FF) Phase 2 — macOS "新建作品" sheet.
///
/// Title field + 6-swatch cover-colour picker, then
/// `POST /books` (`BookCreateRequest(title:coverColor:)`). `cover_color` is
/// stored as one of the six author-facing names (`indigo`/`rose`/`green`/
/// `amber`/`teal`/`slate`) so `LWColor.coverGradient(name:)` resolves it on the
/// shelf — matching the handoff's `coverColors` convention.
///
/// Swatch style mirrors the handoff (`LinoWriting.dc.html`): 30×30, radius 9,
/// gradient fill, selected ring `0 0 0 2px #fff, 0 0 0 4px #5B7CFF`. macOS-only.
struct MacNewBookSheet: View {
    @EnvironmentObject var bookshelfStore: BookshelfStore
    @EnvironmentObject var appStore: AppStore
    @EnvironmentObject var bookStore: BookStore
    @EnvironmentObject var charactersStore: CharactersStore
    @EnvironmentObject var chaptersStore: ChaptersStore
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var coverColor = LWColor.coverSwatchNames.first ?? "indigo"
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("新建作品")
                .font(LWFont.songti(20, weight: .semibold))
                .foregroundStyle(LWColor.titleText)

            VStack(alignment: .leading, spacing: 8) {
                Text("作品名称")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LWColor.secondaryText)
                TextField("给这部作品起个名字…", text: $title)
                    .textFieldStyle(.plain)
                    .font(LWFont.songti(15))
                    .foregroundStyle(LWColor.bodyText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: LWMetrics.controlRadius, style: .continuous)
                            .fill(Color(.sRGB, red: 252/255, green: 252/255, blue: 254/255, opacity: 0.8))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: LWMetrics.controlRadius, style: .continuous)
                            .stroke(LWColor.hex(0x282D46, opacity: 0.12), lineWidth: 0.5)
                    )
                    .onSubmit(submitIfReady)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("封面色")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LWColor.secondaryText)
                HStack(spacing: 12) {
                    ForEach(LWColor.coverSwatchNames, id: \.self) { name in
                        swatch(name)
                    }
                }
            }

            HStack {
                Button("取消") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LWColor.secondaryText)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(action: submitIfReady) {
                    Group {
                        if isSubmitting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("创建作品")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(height: LWMetrics.primaryButtonHeight)
                    .padding(.horizontal, 20)
                    .background(
                        LWColor.accentGradient.opacity(canSubmit ? 1 : 0.4),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
                    .shadow(color: LWColor.accentStop.opacity(canSubmit ? 0.5 : 0), radius: 10, y: 6)
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 440)
    }

    // MARK: - Swatch

    private func swatch(_ name: String) -> some View {
        let selected = coverColor == name
        return Button { coverColor = name } label: {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LWColor.coverGradient(name))
                .frame(width: 30, height: 30)
                // ring: 0 0 0 2px #fff, 0 0 0 4px #5B7CFF (white inner, accent outer).
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .inset(by: -3)
                        .stroke(Color.white, lineWidth: 2)
                        .opacity(selected ? 1 : 0)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
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
            if let book = await bookshelfStore.create(
                title: title.trimmingCharacters(in: .whitespaces),
                coverColor: coverColor
            ) {
                appStore.openBook(book)
                bookStore.setBook(book)
                async let chs: () = chaptersStore.load(bookId: book.id)
                async let chars: () = charactersStore.load(bookId: book.id)
                _ = await (chs, chars)
                dismiss()
            }
            isSubmitting = false
        }
    }
}
#endif

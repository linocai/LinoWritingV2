import SwiftUI

public struct NewBookSheet: View {
    @EnvironmentObject var bookshelfStore: BookshelfStore
    @EnvironmentObject var appStore: AppStore
    @EnvironmentObject var bookStore: BookStore
    @EnvironmentObject var charactersStore: CharactersStore
    @EnvironmentObject var chaptersStore: ChaptersStore
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var color: String = "#3A86FF"
    @State private var isSubmitting: Bool = false

    private let palette: [String] = [
        "#3A86FF", "#FF006E", "#FB5607", "#FFBE0B",
        "#8338EC", "#06D6A0", "#118AB2", "#073B4C"
    ]

    public init() {}

    public var body: some View {
        VStack(spacing: 18) {
            Text("新建书")
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                Text("书名").font(.callout.weight(.medium))
                TextField("书名", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submitIfReady)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("封面颜色").font(.callout.weight(.medium))
                HStack(spacing: 10) {
                    ForEach(palette, id: \.self) { hex in
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 26, height: 26)
                            .overlay(
                                Circle().strokeBorder(
                                    color == hex ? Color.primary : .clear,
                                    lineWidth: 2
                                )
                            )
                            .onTapGesture { color = hex }
                    }
                }
            }

            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(action: submitIfReady) {
                    if isSubmitting { ProgressView().controlSize(.small) }
                    else { Text("创建") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(28)
        .frame(width: 420)
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
                coverColor: color
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

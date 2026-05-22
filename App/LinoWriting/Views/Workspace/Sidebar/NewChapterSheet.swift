import SwiftUI

public struct NewChapterSheet: View {
    @EnvironmentObject var chaptersStore: ChaptersStore
    @EnvironmentObject var chapterEditorStore: ChapterEditorStore
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var prompt: String = ""
    @State private var isSubmitting: Bool = false

    public init() {}

    public var body: some View {
        VStack(spacing: 18) {
            Text("新建章节")
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                Text("标题（可选）").font(.callout.weight(.medium))
                TextField("例如：山洞夜话", text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("章节想法（约 50 字）").font(.callout.weight(.medium))
                TextEditor(text: $prompt)
                    .frame(height: 120)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.secondary.opacity(0.25))
                    )
                Text("\(prompt.count) 字")
                    .font(.caption)
                    .foregroundStyle(prompt.count > 200 ? .orange : .secondary)
            }

            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(action: submit) {
                    if isSubmitting { ProgressView().controlSize(.small) }
                    else { Text("创建") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSubmitting)
            }
        }
        .padding(28)
        .frame(width: 480)
    }

    private func submit() {
        isSubmitting = true
        let titleValue = title.trimmingCharacters(in: .whitespaces).isEmpty ? nil : title
        let promptValue = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : prompt
        Task {
            if let chapter = await chaptersStore.create(userPrompt: promptValue, title: titleValue) {
                await chapterEditorStore.load(chapterId: chapter.id)
                dismiss()
            }
            isSubmitting = false
        }
    }
}

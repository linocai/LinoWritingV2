import SwiftUI

public struct WorldSettingTabView: View {
    @EnvironmentObject var bookStore: BookStore

    @State private var world: String = ""
    @State private var style: String = ""
    @State private var dirtyWorld: Bool = false
    @State private var dirtyStyle: Bool = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section(
                    title: "世界设定",
                    helper: "200-300 字 markdown，描述背景、规则、风物。",
                    text: $world,
                    dirty: $dirtyWorld,
                    onSave: { value in
                        Task { await bookStore.patchWorldSetting(value); dirtyWorld = false }
                    }
                )
                section(
                    title: "写作风格",
                    helper: "用户手写的全书风格指引，比如「冷硬克制 + 慢节奏 + 第三人称限知」。",
                    text: $style,
                    dirty: $dirtyStyle,
                    onSave: { value in
                        Task { await bookStore.patchStyleDirective(value); dirtyStyle = false }
                    }
                )
            }
            .padding(14)
        }
        .onAppear { syncFromBook() }
        .onChange(of: bookStore.book?.id) { _, _ in syncFromBook() }
    }

    private func syncFromBook() {
        world = bookStore.book?.worldSetting ?? ""
        style = bookStore.book?.styleDirective ?? ""
        dirtyWorld = false
        dirtyStyle = false
    }

    private func section(
        title: String,
        helper: String,
        text: Binding<String>,
        dirty: Binding<Bool>,
        onSave: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(helper).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 160, maxHeight: 400)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.25))
                )
                .onChange(of: text.wrappedValue) { _, _ in dirty.wrappedValue = true }
            HStack {
                Spacer()
                Button("保存") { onSave(text.wrappedValue) }
                    .buttonStyle(.bordered)
                    .disabled(!dirty.wrappedValue)
            }
        }
    }
}

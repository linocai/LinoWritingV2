import SwiftUI

public struct SettingsView: View {
    @EnvironmentObject var appStore: AppStore
    @Environment(\.dismiss) private var dismiss

    public var isFirstRun: Bool = false

    @State private var baseURLString: String = ""
    @State private var token: String = ""
    @State private var error: String?

    public init(isFirstRun: Bool = false) {
        self.isFirstRun = isFirstRun
    }

    public var body: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("配置后端连接")
                    .font(.title2.weight(.semibold))
                Text("请填入后端服务地址与访问 Token。两项都保存在本机 Keychain。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                fieldRow(
                    label: "API Base URL",
                    placeholder: "http://localhost:8787",
                    text: $baseURLString
                )
                fieldRow(
                    label: "API Token",
                    placeholder: "•••••••••",
                    text: $token,
                    secure: true
                )
            }

            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                if !isFirstRun {
                    Button("取消") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                Button("保存", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(28)
        .frame(width: 480)
        .onAppear(perform: loadExisting)
    }

    private var canSave: Bool {
        !baseURLString.trimmingCharacters(in: .whitespaces).isEmpty &&
        !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func loadExisting() {
        baseURLString = KeychainStore.shared.baseURL?.absoluteString ?? ""
        token = KeychainStore.shared.token ?? ""
    }

    private func fieldRow(label: String, placeholder: String, text: Binding<String>, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.callout.weight(.medium))
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        #endif
                }
            }
            .textFieldStyle(.roundedBorder)
        }
    }

    private func save() {
        let urlString = baseURLString.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: urlString), url.scheme != nil else {
            error = "URL 无效，请包含 http(s):// 前缀"
            return
        }
        appStore.saveCredentials(baseURL: url, token: token.trimmingCharacters(in: .whitespaces))
        error = nil
        if !isFirstRun { dismiss() }
    }
}

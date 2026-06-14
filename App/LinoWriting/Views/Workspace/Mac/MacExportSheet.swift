#if os(macOS)
import SwiftUI

/// v1.1.0 (FF) Phase 3 — "导出整本…" sheet. `GET /books/{id}/export`
/// (format=markdown/txt, include_drafts). macOS-only.
struct MacExportSheet: View {
    let book: Book

    @EnvironmentObject var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var format: ExportFormat = .markdown
    @State private var includeDrafts = false
    @State private var isExporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("导出整本")
                .font(LWFont.songti(20, weight: .semibold))
                .foregroundStyle(LWColor.titleText)

            VStack(alignment: .leading, spacing: 8) {
                LWSectionLabel("格式")
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
                    Text("包含未定稿章节").font(.system(size: 13))
                        .foregroundStyle(LWColor.bodyText)
                    Text("默认只导出已完成章节")
                        .font(.system(size: 11))
                        .foregroundStyle(LWColor.mutedText3)
                }
            }
            .toggleStyle(.switch)

            HStack {
                Button("取消") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LWColor.secondaryText)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                LWPrimaryButton(title: isExporting ? "导出中…" : "导出", systemImage: "square.and.arrow.up", enabled: !isExporting) {
                    runExport()
                }
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 420)
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

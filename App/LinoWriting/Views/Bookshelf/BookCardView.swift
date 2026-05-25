import SwiftUI
#if os(macOS)
import AppKit
#endif

public struct BookCardView: View {
    public let book: Book

    @State private var isHovered: Bool = false
    /// True while an export request is in flight. Used to disable the
    /// hover button + show a spinner so a double-click can't fire two
    /// downloads. Per-card local state — keeping it off ``ErrorBus`` /
    /// any store means cards on other rows are unaffected.
    @State private var isExporting: Bool = false

    /// Injected via ``AppEnvironment`` so the export button can call
    /// ``APIClient.exportBook`` without going through a store
    /// (export has no shared model state — it's a download).
    @EnvironmentObject var environment: AppEnvironment

    public init(book: Book) { self.book = book }

    private var coverColor: Color {
        if let hex = book.coverColor { return Color(hex: hex) }
        return Color.accentColor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 8)
                .fill(coverColor)
                .overlay(
                    Text(book.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(12)
                )
                .overlay(alignment: .topTrailing) { exportButton }
                .aspectRatio(3.0/4.0, contentMode: .fit)
                .shadow(
                    color: .black.opacity(isHovered ? 0.25 : 0.15),
                    radius: isHovered ? 8 : 4,
                    y: isHovered ? 3 : 1
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.bottom, 4)
        .offset(y: isHovered ? -2 : 0)
        #if os(macOS)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        #endif
    }

    /// v0.7 §5.F — hover-only "export" pill in the top-right corner of
    /// the book cover. The simplified flow (per plan recommendation):
    /// default to **markdown + finalized only**, no format picker; one
    /// click takes the user straight to the save panel. Power users
    /// who want TXT or include_drafts can do it via the future
    /// Settings → Export Preferences (out of scope for v0.7).
    @ViewBuilder
    private var exportButton: some View {
        if isHovered {
            Button {
                guard !isExporting else { return }
                runExport()
            } label: {
                Group {
                    if isExporting {
                        ProgressView()
                            .controlSize(.small)
                            .progressViewStyle(.circular)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .font(.callout)
                .frame(width: 28, height: 28)
                .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(isExporting)
            .padding(8)
            .help("导出本书为 Markdown（仅含已完成章节）")
        }
    }

    private func runExport() {
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                let (data, suggested) = try await environment.apiClient.exportBook(
                    id: book.id,
                    format: .markdown,
                    includeDrafts: false
                )
                try await FileSaver.save(data: data, suggestedFilename: suggested)
            } catch let error as AppError {
                environment.errorBus.publish(error)
            } catch {
                environment.errorBus.publish(.transport(error.localizedDescription))
            }
        }
    }

    private var footnote: String {
        let chapters = "\(book.chapterCount) 章"
        if let opened = book.lastOpenedAt {
            return "\(chapters) · 上次打开 \(opened.relativeShort)"
        }
        return chapters
    }
}

private extension Date {
    var relativeShort: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}

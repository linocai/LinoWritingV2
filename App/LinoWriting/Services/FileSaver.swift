import Foundation
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#elseif os(iOS)
import UIKit
import UniformTypeIdentifiers
#endif

/// v0.7 §5.F — small helper that takes a `(Data, suggestedFilename)`
/// tuple (what ``APIClient.exportBook`` / ``exportChapter`` return) and
/// drops it on disk through the platform's native save dialog.
///
/// On macOS we drive an ``NSSavePanel`` and write the bytes ourselves
/// once the user confirms. On iOS we write to a temp file and hand it
/// to the share sheet so the user can save / share / AirDrop it (this
/// path is currently a stub; macOS is the primary target for v0.7).
public enum FileSaver {

    /// Show the platform save UI and write the body to disk.
    ///
    /// Resolves silently when the user cancels — cancellation is the
    /// expected exit branch on a save dialog, not an error. Throws
    /// ``AppError.transport`` if the underlying file write fails (disk
    /// full, permission denied, etc.) so the caller can surface it
    /// through ``ErrorBus``.
    @MainActor
    public static func save(data: Data, suggestedFilename: String) async throws {
        #if os(macOS)
        try await saveMac(data: data, suggestedFilename: suggestedFilename)
        #elseif os(iOS)
        try await saveIOS(data: data, suggestedFilename: suggestedFilename)
        #endif
    }

    #if os(macOS)
    @MainActor
    private static func saveMac(data: Data, suggestedFilename: String) async throws {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        // Map the trailing extension to a UTType so macOS surfaces a
        // sensible filter in the save sheet. Defaults to plain text
        // when we don't recognise the suffix.
        let ext = (suggestedFilename as NSString).pathExtension.lowercased()
        let type: UTType
        switch ext {
        case "md", "markdown": type = .text  // no first-party UTType for markdown
        case "txt": type = .plainText
        default: type = .plainText
        }
        panel.allowedContentTypes = [type]

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            // User hit cancel. Treat as a no-op, not an error.
            return
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw AppError.transport("写入文件失败：\(error.localizedDescription)")
        }
    }
    #endif

    #if os(iOS)
    @MainActor
    private static func saveIOS(data: Data, suggestedFilename: String) async throws {
        // iOS path is a minimal stub for v0.7 — the macOS app is the
        // primary export target. We write the body to a temp file and
        // present a ``UIDocumentPickerViewController`` (export mode) so
        // the user can save it into Files / iCloud Drive / share sheet
        // targets. Plan §5.F flags this as "iOS optional" so we keep it
        // working but unpolished.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(suggestedFilename)
        do {
            try data.write(to: tmp, options: .atomic)
        } catch {
            throw AppError.transport("写入临时文件失败：\(error.localizedDescription)")
        }
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first?.rootViewController else {
            throw AppError.transport("无法获取顶层窗口以弹出导出面板")
        }
        let picker = UIDocumentPickerViewController(
            forExporting: [tmp], asCopy: true
        )
        // Fire-and-forget — async/await across UIKit modals would need
        // a continuation dance and the v0.7 plan explicitly calls iOS
        // a stub. Caller's await resolves the moment we present.
        root.present(picker, animated: true)
    }
    #endif
}

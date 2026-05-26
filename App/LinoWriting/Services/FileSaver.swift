import Foundation
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#elseif os(iOS)
import UIKit
import SwiftUI
import UniformTypeIdentifiers
#endif

/// v0.7 §5.F — small helper that takes a `(Data, suggestedFilename)`
/// tuple (what ``APIClient.exportBook`` / ``exportChapter`` return) and
/// drops it on disk through the platform's native save dialog.
///
/// On macOS we drive an ``NSSavePanel`` and write the bytes ourselves
/// once the user confirms. On iOS (v0.8 §5.R.5) we write the body to a
/// temporary file and hand it to ``UIDocumentPickerViewController`` in
/// `forExporting:` mode, then `await` the user's pick via a
/// ``CheckedContinuation`` — so the caller's `await` actually resolves
/// when the file has landed (or the user cancelled), matching the macOS
/// contract instead of the v0.7 fire-and-forget stub.
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
    /// v0.8 §5.R.5 — real iOS export. We:
    ///   1. Write `data` to a temp file under `tmp/` (UIDocumentPicker
    ///      copies from a real URL — it cannot accept raw bytes).
    ///   2. Present `UIDocumentPickerViewController(forExporting: [tmp])`
    ///      so the user can drop it into Files / iCloud Drive / a third
    ///      party storage provider. `asCopy: true` keeps our tmp file
    ///      ours (the picker copies bytes into the destination).
    ///   3. Bridge the UIKit delegate callbacks into Swift Concurrency
    ///      via a `CheckedContinuation` so the caller's `await` resolves
    ///      only after the user picked / cancelled, matching macOS.
    @MainActor
    private static func saveIOS(data: Data, suggestedFilename: String) async throws {
        // 1. Stage bytes on disk. UIDocumentPicker needs a URL it can read.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(suggestedFilename)
        do {
            // Overwrite if a stale tmp from a previous export with the
            // same suggested name is still around.
            if FileManager.default.fileExists(atPath: tmp.path) {
                try FileManager.default.removeItem(at: tmp)
            }
            try data.write(to: tmp, options: .atomic)
        } catch {
            throw AppError.transport("写入临时文件失败：\(error.localizedDescription)")
        }

        // 2. Find the topmost view controller in the active scene. iPadOS
        // multi-scene apps can have several connected scenes; we pick the
        // foreground active one to avoid presenting on a backgrounded
        // window which would silently fail.
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first
        guard let scene,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
                       ?? scene.windows.first?.rootViewController
        else {
            // Clean up the tmp file so we don't leak when we couldn't
            // even present the picker.
            try? FileManager.default.removeItem(at: tmp)
            throw AppError.transport("无法获取顶层窗口以弹出导出面板")
        }

        // Walk modal presentation chain so we present on the actually-
        // visible controller (otherwise UIKit logs a warning and may
        // refuse to present on an already-busy view controller).
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }

        // 3. Bridge the delegate callback into async/await.
        let picker = UIDocumentPickerViewController(forExporting: [tmp], asCopy: true)
        let delegate = DocumentPickerDelegate()
        picker.delegate = delegate
        picker.modalPresentationStyle = .formSheet

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            delegate.onFinish = {
                // Best-effort tmp cleanup. The picker copied bytes by
                // now (or the user cancelled — either way tmp is no
                // longer needed for this export).
                try? FileManager.default.removeItem(at: tmp)
                continuation.resume()
            }
            // Strong-retain the delegate for the lifetime of the
            // continuation by capturing it inside `onFinish`. UIKit
            // holds the delegate weakly.
            picker.presentationController?.delegate = delegate
            presenter.present(picker, animated: true)
        }
    }

    /// Internal UIKit delegate that funnels the three terminal callbacks
    /// (`didPickDocumentsAt`, `didPickDocuments` legacy, and `wasCancelled`)
    /// plus the swipe-to-dismiss `presentationControllerDidDismiss` into
    /// a single `onFinish` closure. Caller resumes its continuation from
    /// inside `onFinish`, regardless of which path the user took.
    private final class DocumentPickerDelegate: NSObject,
        UIDocumentPickerDelegate,
        UIAdaptivePresentationControllerDelegate
    {
        var onFinish: (() -> Void)?

        // Guard against multiple delegate calls firing — UIKit can
        // occasionally invoke both `didPick` and `wasCancelled` during
        // certain dismissal animations; we only resume the continuation
        // once.
        private var fired: Bool = false

        private func fire() {
            guard !fired else { return }
            fired = true
            let cb = onFinish
            onFinish = nil
            cb?()
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            fire()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            fire()
        }

        // Swipe-to-dismiss path on iOS 13+ form sheets — neither
        // `didPick…` nor `wasCancelled` fires in that case, so without
        // this we'd hang the caller's `await` indefinitely.
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            fire()
        }
    }
    #endif
}

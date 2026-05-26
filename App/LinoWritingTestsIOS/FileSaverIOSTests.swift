import XCTest
@testable import LinoWriting

/// R-4 (v0.8) — iOS-runtime invariants for ``FileSaver``.
///
/// ``FileSaver.saveIOS`` is wired to ``UIDocumentPickerViewController`` and
/// can only present from a foreground-active ``UIWindowScene``. In an
/// XCTest logic-bundle, no scene is wired up, so the picker step would
/// either hang on `withCheckedContinuation` or raise the documented
/// `AppError.transport("无法获取顶层窗口以弹出导出面板")`. Either way the
/// end-to-end path can't be exercised here — that branch belongs to the
/// human Simulator pass per §5.R.8.
///
/// What we *can* verify in pure logic tests is the staging contract that
/// `saveIOS` relies on (and that lives inside the same Foundation
/// surface area on iOS Simulator): writing bytes to
/// ``FileManager.default.temporaryDirectory``, overwriting a stale tmp
/// from a previous export, and surfacing a write error.
///
/// 🟡 Not covered here (intentional): the actual
/// ``UIDocumentPickerViewController`` presentation + delegate-bridge
/// continuation resume. Tracking back to §5.R.8 "全流程 simulator" item.
final class FileSaverIOSTests: XCTestCase {

    /// FileSaver.save's public entry point is `@MainActor async throws` and
    /// reachable from this iOS test bundle. The compile-only assertion
    /// catches a class of regression where someone strips `#if os(iOS)`
    /// guards and the symbol disappears from the iOS slice.
    @MainActor
    func test_publicEntryPoint_isReachableOnIOS() async {
        // We don't actually call save() — that would try to present a
        // UIDocumentPicker. We just take a reference to the closure to
        // force the symbol to participate in the iOS binary.
        let entry: (Data, String) async throws -> Void = FileSaver.save(data:suggestedFilename:)
        XCTAssertNotNil(entry as Any)
    }

    /// Mirrors the staging block inside `saveIOS` step 1:
    /// `tmp = temporaryDirectory.appending(suggestedFilename)`,
    /// `data.write(to: tmp, options: .atomic)`.
    /// Confirms Foundation actually writes our bytes on iOS Simulator.
    func test_temporaryDirectoryStaging_writesAndReadsBack() throws {
        let payload = Data("hello iOS".utf8)
        let filename = "fs-staging-\(UUID().uuidString).txt"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(filename)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try payload.write(to: tmp, options: .atomic)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path))
        let readback = try Data(contentsOf: tmp)
        XCTAssertEqual(readback, payload)
    }

    /// `saveIOS` removes a stale tmp file before re-staging the new bytes:
    ///     if FileManager.default.fileExists(atPath: tmp.path) {
    ///         try FileManager.default.removeItem(at: tmp)
    ///     }
    /// Confirms the rename-over-existing semantics on iOS Simulator (which
    /// historically differs from macOS APFS on case sensitivity, though
    /// not on file replacement).
    func test_staleTmpIsReplaced_onSameSuggestedFilename() throws {
        let filename = "fs-stale-\(UUID().uuidString).txt"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(filename)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Stage v1.
        try Data("v1".utf8).write(to: tmp, options: .atomic)
        // FileSaver's stale-file branch: remove then write.
        if FileManager.default.fileExists(atPath: tmp.path) {
            try FileManager.default.removeItem(at: tmp)
        }
        try Data("v2".utf8).write(to: tmp, options: .atomic)

        let readback = try Data(contentsOf: tmp)
        XCTAssertEqual(readback, Data("v2".utf8))
    }

    /// `saveIOS` wraps the write in `do/catch` and maps any error to
    /// `AppError.transport("写入临时文件失败：…")`. Confirm
    /// ``AppError.transport`` round-trips through Equatable on iOS so the
    /// caller (`ExportFlow` etc.) can `if case .transport = err` against
    /// it on this platform too.
    func test_appErrorTransport_isEquatableOnIOS() {
        let a = AppError.transport("写入临时文件失败：disk full")
        let b = AppError.transport("写入临时文件失败：disk full")
        let c = AppError.transport("写入临时文件失败：permission denied")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertTrue(a.retryable)
    }
}

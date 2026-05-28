import Foundation
import SwiftUI

/// v0.9 §5.W (W-2) — backs the macOS Settings → 连接 → 设备管理 sub-section.
///
/// Fronts three of the four `/api/v1/auth/*` endpoints used by the device
/// list + "添加新设备" dialog:
///   - `listDevices()`   → the device list
///   - `revokeDevice()`  → the per-row trash button
///   - `pairInitiate()`  → the short-code + QR generation flow
///
/// (`pairConfirm` is iOS-only / W-3 and lives on the APIClient, not here.)
///
/// Follows the same conservative "reload-after-mutation" + ErrorBus pattern
/// as `ProviderKeysStore`: every failed network call publishes to the bus and
/// leaves prior state untouched.
@MainActor
public final class DeviceStore: ObservableObject {

    @Published public private(set) var devices: [DeviceInfo] = []
    @Published public private(set) var isLoading: Bool = false
    /// True while a revoke / pair-initiate call is in flight; disables the
    /// relevant buttons to avoid double-submits.
    @Published public private(set) var isMutating: Bool = false

    private let api: APIClientProtocol
    private let errorBus: ErrorBus

    public init(api: APIClientProtocol, errorBus: ErrorBus) {
        self.api = api
        self.errorBus = errorBus
    }

    /// Sorted newest-first by creation time so the most-recently-paired
    /// device sits at the top of the list.
    public var sortedDevices: [DeviceInfo] {
        devices.sorted { $0.createdAt > $1.createdAt }
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            devices = try await api.listDevices()
        } catch let error as AppError {
            errorBus.publish(error)
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
        }
    }

    /// Revoke a device. On success the list is reloaded so the row drops out
    /// immediately. NOTE: revoking the device whose token is currently in use
    /// self-401s on the next call — the macOS confirm alert warns the author.
    public func revoke(id: String) async {
        isMutating = true
        defer { isMutating = false }
        do {
            try await api.revokeDevice(id: id)
            devices = try await api.listDevices()
        } catch let error as AppError {
            errorBus.publish(error)
        } catch {
            errorBus.publish(.transport(error.localizedDescription))
        }
    }

    /// Request a fresh 6-digit pairing code from the backend. Returns the
    /// response (code + expiry) so the caller can drive the QR dialog, or
    /// `nil` on failure (already published to ErrorBus).
    public func initiatePairing() async -> PairInitiateResponse? {
        isMutating = true
        defer { isMutating = false }
        do {
            return try await api.pairInitiate()
        } catch let error as AppError {
            errorBus.publish(error); return nil
        } catch {
            errorBus.publish(.transport(error.localizedDescription)); return nil
        }
    }
}

import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Generates QR codes for the v0.9 §5.W device-pairing flow using CoreImage's
/// built-in `CIQRCodeGenerator` — no new SPM dependency (CoreImage ships with
/// every Apple platform).
///
/// The core API returns a platform-neutral `CGImage`; per-platform extensions
/// (`NSImage` on macOS, `UIImage` on iOS) wrap it for SwiftUI. macOS uses the
/// generator now (W-2); iOS only displays QR codes from W-3 onward, but the
/// helper is cross-platform from day one so W-3 doesn't have to touch it.
public enum QRCodeGenerator {

    /// CoreImage context reused across calls. Rasterising a `CIImage` to a
    /// `CGImage` requires a `CIContext`; creating one per call is wasteful
    /// (each spins up GPU/CPU render resources), so we keep a single shared
    /// instance. It's thread-safe for read-only `createCGImage` use.
    private static let context = CIContext()

    /// Render `string` into a crisp QR code `CGImage`.
    ///
    /// - Parameters:
    ///   - string: the payload (for §5.W this is the base64 of
    ///     `PairingPayload`). Encoded as UTF-8.
    ///   - scale: nearest-neighbour upscale factor applied to the raw
    ///     (1 module = 1 pixel) CoreImage output so the code renders sharp
    ///     instead of blurry when SwiftUI stretches it. Default 12 gives a
    ///     comfortably-sized image for the macOS dialog.
    ///   - correctionLevel: QR error-correction level — one of `L` / `M` /
    ///     `Q` / `H`. Default `M` (~15% recovery) balances density against
    ///     robustness to glare / partial occlusion when scanned off a screen.
    /// - Returns: a `CGImage`, or `nil` if the filter produced no output
    ///   (e.g. payload exceeds QR capacity — won't happen for a short
    ///   base64 URL+code, but the optional keeps the call site honest).
    public static func makeCGImage(
        from string: String,
        scale: CGFloat = 12,
        correctionLevel: String = "M"
    ) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = correctionLevel

        guard let output = filter.outputImage else { return nil }

        // Upscale with an integer transform so each QR module stays a solid
        // block of pixels (no anti-aliasing smear at the module edges).
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(scaled, from: scaled.extent)
    }
}

#if os(macOS)
public extension QRCodeGenerator {
    /// macOS: render `string` into an `NSImage` ready to drop into a SwiftUI
    /// `Image(nsImage:)`. Returns `nil` on the same conditions as
    /// `makeCGImage`.
    static func makeNSImage(
        from string: String,
        scale: CGFloat = 12,
        correctionLevel: String = "M"
    ) -> NSImage? {
        guard let cg = makeCGImage(from: string, scale: scale, correctionLevel: correctionLevel) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
#endif

#if os(iOS)
public extension QRCodeGenerator {
    /// iOS (W-3): render `string` into a `UIImage` for `Image(uiImage:)`.
    /// Provided now so W-3 reuses this helper rather than re-deriving it.
    static func makeUIImage(
        from string: String,
        scale: CGFloat = 12,
        correctionLevel: String = "M"
    ) -> UIImage? {
        guard let cg = makeCGImage(from: string, scale: scale, correctionLevel: correctionLevel) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }
}
#endif

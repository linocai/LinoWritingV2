import SwiftUI

#if os(macOS)
import AppKit
public typealias PlatformColor = NSColor
#else
import UIKit
public typealias PlatformColor = UIColor
#endif

public extension Color {
    /// Initialize a SwiftUI Color from a `#RRGGBB` or `#RRGGBBAA` hex string.
    /// Falls back to gray on malformed input.
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        let scanner = Scanner(string: s)
        var raw: UInt64 = 0
        guard scanner.scanHexInt64(&raw) else {
            self = Color.gray
            return
        }
        let r, g, b, a: Double
        switch s.count {
        case 6:
            r = Double((raw >> 16) & 0xff) / 255.0
            g = Double((raw >> 8) & 0xff) / 255.0
            b = Double(raw & 0xff) / 255.0
            a = 1.0
        case 8:
            r = Double((raw >> 24) & 0xff) / 255.0
            g = Double((raw >> 16) & 0xff) / 255.0
            b = Double((raw >> 8) & 0xff) / 255.0
            a = Double(raw & 0xff) / 255.0
        default:
            self = Color.gray
            return
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

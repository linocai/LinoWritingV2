import Foundation
import SwiftUI

/// Editor font design selection for the chapter draft area.
///
/// Per PROJECT_PLAN §5.K.4 (字体): novelists generally prefer a serif body face,
/// so `.serif` is the default. The setting is stored in `UserDefaults` under
/// `editor_font_design` and is also read directly by views via `@AppStorage`
/// (see `Step3_DraftView`) for live updates.
public enum EditorFontDesign: String, Codable, CaseIterable, Sendable {
    case sans = "sans"
    case serif = "serif"

    /// Single source of truth for the default font design.
    /// Use this anywhere a fallback is needed (corrupt UserDefaults value,
    /// fresh install, downgrade from a future enum case).
    /// A-2 reviewer 🟡 #1: avoids three views hardcoding `.serif` separately.
    public static let `default`: EditorFontDesign = .serif

    /// Maps to SwiftUI `Font.Design`. `EditorFontDesign` is the persisted
    /// shape; `Font.Design` is the value views feed to `.font(.system(...))`.
    public var fontDesign: Font.Design {
        switch self {
        case .sans: return .default
        case .serif: return .serif
        }
    }

    public var label: String {
        switch self {
        case .sans: return "无衬线"
        case .serif: return "衬线（推荐）"
        }
    }
}

/// Light wrapper over UserDefaults for non-secret user preferences.
public final class Settings: @unchecked Sendable {
    public static let shared = Settings()

    /// v0.8 §5.U.2: production default backend URL. S-3 brought
    /// `https://lw.linotsai.top` online; this string is the open-the-box
    /// default that LinoI shows on a fresh install. Author can override
    /// via Settings → Connection (e.g. back to `http://localhost:8787`
    /// for dev) and the override persists in Keychain.
    public static let defaultBackendURLString: String = "https://lw.linotsai.top"

    /// v0.8 §5.U.2 DNS sanity check: when the production hostname above
    /// resolves to anything other than this IP we surface a hijack banner
    /// (router / WARP / VPN intercepting DNS). HZ origin IP per
    /// `Backend/deploy/hz_info.md`. Kept as a small array so future
    /// migrations (multi-IP, IPv6) can be added without code changes
    /// to the probe call sites.
    public static let trustedBackendIPs: [String] = ["118.178.122.194"]

    private let defaults: UserDefaults
    private let lastBookKey = "last_opened_book_id"
    private let sidebarWidthKey = "sidebar_width"
    private let rightPanelWidthKey = "right_panel_width"

    /// `UserDefaults` key shared with `@AppStorage("editor_font_design")` in views.
    /// Kept `public static` so views and tests can reference the same key
    /// without re-typing the string.
    public static let editorFontDesignKey = "editor_font_design"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var lastOpenedBookId: String? {
        get { defaults.string(forKey: lastBookKey) }
        set { defaults.set(newValue, forKey: lastBookKey) }
    }

    public var sidebarWidth: CGFloat {
        get { CGFloat(defaults.double(forKey: sidebarWidthKey).nonZero ?? 220.0) }
        set { defaults.set(Double(newValue), forKey: sidebarWidthKey) }
    }

    public var rightPanelWidth: CGFloat {
        get { CGFloat(defaults.double(forKey: rightPanelWidthKey).nonZero ?? 340.0) }
        set { defaults.set(Double(newValue), forKey: rightPanelWidthKey) }
    }

    /// Chapter draft / preview body font design. Default `.serif` (PROJECT_PLAN §5.K.4).
    ///
    /// NOTE (K-3): the UI switch lives in `SettingsView` after the E-3 LLM Providers
    /// rework lands. This service-layer accessor + the `@AppStorage` reads in
    /// `Step3_DraftView` are sufficient for K-3 — the field is wired end-to-end
    /// and persists across launches; the picker UI is a single additional row.
    public var editorFontDesign: EditorFontDesign {
        get {
            guard let raw = defaults.string(forKey: Self.editorFontDesignKey),
                  let parsed = EditorFontDesign(rawValue: raw) else {
                return .default
            }
            return parsed
        }
        set { defaults.set(newValue.rawValue, forKey: Self.editorFontDesignKey) }
    }
}

private extension Double {
    /// Treats 0.0 as "not set" (UserDefaults' default for missing keys).
    var nonZero: Double? { self == 0.0 ? nil : self }
}

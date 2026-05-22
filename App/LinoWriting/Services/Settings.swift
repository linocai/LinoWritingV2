import Foundation

/// Light wrapper over UserDefaults for non-secret user preferences.
public final class Settings: @unchecked Sendable {
    public static let shared = Settings()

    private let defaults: UserDefaults
    private let lastBookKey = "last_opened_book_id"
    private let sidebarWidthKey = "sidebar_width"
    private let rightPanelWidthKey = "right_panel_width"

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
}

private extension Double {
    /// Treats 0.0 as "not set" (UserDefaults' default for missing keys).
    var nonZero: Double? { self == 0.0 ? nil : self }
}

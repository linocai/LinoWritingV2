import Foundation

/// v1.3.0 (II) 审后修复 🟡#1 — shared commit-decision rule for the
/// card-head inline-editable name/role fields (`MacCardHeadField` /
/// `IOSCardHeadField`). Extracted as a pure function (rather than left
/// inline in each platform's private `commit()`) so the "clearing name
/// must cancel, not submit" behavior has a direct unit test independent
/// of SwiftUI view rendering.
public enum CardHeadFieldCommit {
    /// Returns the value that should be sent to `onCommit`, or `nil` if
    /// the commit should be a no-op (unchanged value, or an illegal blank
    /// on a field that doesn't allow empty).
    ///
    /// - Parameters:
    ///   - draft: the raw text field contents at blur/return time.
    ///   - original: the value the field held before this edit began.
    ///   - allowsEmpty: `true` for role (blank is a valid "no role"),
    ///     `false` for name (blank is treated as a cancelled edit —
    ///     reverts to `original`, never reaches `onCommit`/the store/PATCH).
    public static func resolve(draft: String, original: String, allowsEmpty: Bool) -> String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && !allowsEmpty { return nil }
        if trimmed == original { return nil }
        return trimmed
    }
}

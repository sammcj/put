import CryptoKit
import Foundation

/// Renders a captured `[DisplayFingerprint]` set as a human-readable label
/// and a stable short hash. The label is intended for UI; the hash is used as
/// a 6-character disambiguator next to the label so two visually similar
/// configurations stay distinguishable at a glance.
public enum DisplaySetFormatter {
    /// Hash length in hex characters. 6 chars give 24 bits — collisions on
    /// the order of one in 16 million display sets, which is plenty for the
    /// "is this the same arrangement I saved last week" question.
    public static let hashLength = 6

    /// Human-readable label such as "MacBook Pro built-in + LG UltraFine 27".
    /// Primary display is listed first; remaining displays are sorted by
    /// localised name to keep the label stable across reorderings. Displays
    /// without a localised name fall back to "<width>x<height> display".
    public static func label(for displays: [DisplayFingerprint]) -> String {
        guard !displays.isEmpty else { return "No displays" }

        let primaries = displays.filter(\.isPrimary)
        let secondaries = displays.filter { !$0.isPrimary }
            .sorted { name(for: $0).localizedCaseInsensitiveCompare(name(for: $1)) == .orderedAscending }
        let ordered = primaries + secondaries
        return ordered.map(name(for:)).joined(separator: " + ")
    }

    /// Stable short hash over the display identity set. Order-insensitive:
    /// the same set in any order produces the same hash. Independent of
    /// arrangement (`globalOrigin`) and live state (`scaleFactor`,
    /// `pointSize`), so re-plug or `Looks like` changes don't shift the hash.
    public static func shortHash(for displays: [DisplayFingerprint]) -> String {
        let canonical = displays
            .map(\.id)
            .sorted()
            .joined(separator: "|")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let hex = digest.compactMap { String(format: "%02X", $0) }.joined()
        return String(hex.prefix(hashLength))
    }

    /// Convenience for UI: "<label> [<hash>]".
    public static func labelWithHash(for displays: [DisplayFingerprint]) -> String {
        guard !displays.isEmpty else { return "No displays" }
        return "\(label(for: displays)) [\(shortHash(for: displays))]"
    }

    private static func name(for display: DisplayFingerprint) -> String {
        if let localized = display.localizedName, !localized.isEmpty {
            return localized
        }
        let width = Int(display.pointSize.width)
        let height = Int(display.pointSize.height)
        return "\(width)x\(height) display"
    }
}

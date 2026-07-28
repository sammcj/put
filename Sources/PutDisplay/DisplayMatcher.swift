import CoreGraphics
import Foundation
import PutCore

public enum DisplayMatchQuality: Equatable, Sendable, Comparable {
    /// UUID match. Same physical panel, or same virtual display ID.
    case exact
    /// Same vendor, product, and (when present) serial. Very likely same panel.
    case equivalent
    /// No identity match; closest-sized available display.
    case similar
    /// Last-resort primary fallback.
    case primary

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .exact:
            0
        case .equivalent:
            1
        case .similar:
            2
        case .primary:
            3
        }
    }
}

public struct DisplayMatchResult: Equatable, Sendable {
    public var display: DisplayFingerprint
    public var quality: DisplayMatchQuality

    public init(display: DisplayFingerprint, quality: DisplayMatchQuality) {
        self.display = display
        self.quality = quality
    }
}

/// Resolves a stored `DisplayFingerprint` target against the currently
/// connected displays. Pure function; easy to unit test.
public enum DisplayMatcher {
    public static func resolve(
        target: DisplayFingerprint,
        among candidates: [DisplayFingerprint]) -> DisplayMatchResult?
    {
        guard !candidates.isEmpty else { return nil }

        if let uuid = target.uuid,
           let match = candidates.first(where: { $0.uuid == uuid })
        {
            return DisplayMatchResult(display: match, quality: .exact)
        }

        if let vendor = target.vendorID, let product = target.productID {
            if let serial = target.serialNumber,
               let match = candidates.first(where: {
                   $0.vendorID == vendor && $0.productID == product && $0.serialNumber == serial
               })
            {
                return DisplayMatchResult(display: match, quality: .equivalent)
            }
            let vendorProductMatches = candidates.filter {
                $0.vendorID == vendor && $0.productID == product
            }
            if let match = preferGeometry(among: vendorProductMatches, target: target) {
                return DisplayMatchResult(display: match, quality: .equivalent)
            }
        }

        // candidates is non-empty (guarded above), so `min(by:)` never returns
        // nil. The size-distance fallback therefore always yields a .similar
        // match; callers that want a strict "primary" fallback should use
        // `DisplayMatcher.primary(among:)` directly.
        if let closest = candidates.min(by: {
            sizeDistance($0.pointSize, target.pointSize) < sizeDistance($1.pointSize, target.pointSize)
        }) {
            return DisplayMatchResult(display: closest, quality: .similar)
        }

        return nil
    }

    public static func primary(among candidates: [DisplayFingerprint]) -> DisplayFingerprint? {
        candidates.first(where: { $0.isPrimary }) ?? candidates.first
    }

    /// Picks a vendor+product candidate. With a single match, or several with
    /// distinct fingerprint ids, returns the first in order - identical to the
    /// prior `first(where:)`. Only when multiple candidates share one id
    /// (identity-ambiguous twins: same vendor+product, nil serial, nil UUID)
    /// does it break the tie by geometry, preferring the candidate whose origin
    /// and point size match the target. This keeps distinct-display resolution
    /// bit-for-bit unchanged while resolving crosswise twin pairings.
    ///
    /// The geometry compare goes through the shared `liveBoundsMatch`, so
    /// floating-point noise in CG bounds arithmetic can't defeat it. That is the
    /// only slack it has: pairing is still best-effort for serial-less,
    /// UUID-less twins, because any real movement - a replug that also shifts
    /// the arrangement origin - leaves no saved geometry matching, and pairing
    /// falls back to enumeration order, which can swap two identical panels.
    private static func preferGeometry(
        among matches: [DisplayFingerprint],
        target: DisplayFingerprint) -> DisplayFingerprint?
    {
        guard let first = matches.first else { return nil }
        let sharingID = matches.filter { $0.id == first.id }
        guard sharingID.count > 1 else { return first }
        let targetBounds = CGRect(origin: target.globalOrigin, size: target.pointSize)
        let geometryMatch = sharingID.first { DisplayProbe.liveBoundsMatch(targetBounds, $0) }
        return geometryMatch ?? first
    }

    private static func sizeDistance(_ lhs: CGSize, _ rhs: CGSize) -> Double {
        let deltaWidth = Double(lhs.width - rhs.width)
        let deltaHeight = Double(lhs.height - rhs.height)
        return deltaWidth * deltaWidth + deltaHeight * deltaHeight
    }
}

import AppKit
import CoreGraphics
import Foundation
import PutCore

public enum DisplayProbeError: Error, Equatable {
    case enumerationFailed(Int32)
}

/// Enumerates currently connected displays and produces `DisplayFingerprint`
/// snapshots. `@MainActor` because it reads `NSScreen` (backing scale, name)
/// and `NSScreen.screens`, which are main-thread state: reading them off-main
/// during a display reconfiguration returned stale or empty results and
/// defeated geometry matching (C10). Runs synchronously and is cheap enough to
/// call on the main thread; callers that also need an AX window probe detach
/// only that part.
@MainActor
public enum DisplayProbe {
    public static func snapshot() throws -> [DisplayFingerprint] {
        var count: UInt32 = 0
        let countErr = CGGetActiveDisplayList(0, nil, &count)
        guard countErr == .success else {
            throw DisplayProbeError.enumerationFailed(countErr.rawValue)
        }
        guard count > 0 else { return [] }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        var populated: UInt32 = 0
        let listErr = CGGetActiveDisplayList(count, &ids, &populated)
        guard listErr == .success else {
            throw DisplayProbeError.enumerationFailed(listErr.rawValue)
        }

        let mainID = CGMainDisplayID()
        let screensByID = indexedScreens()

        return ids.prefix(Int(populated)).map { id in
            fingerprint(for: id, isPrimary: id == mainID, screensByID: screensByID)
        }
    }

    /// AX-global-space Y of the first row beneath the menu bar on the live
    /// display matching `fingerprint`. macOS clamps any window placed above
    /// this line down to it, so callers use it to keep restore targets
    /// reachable (see `Coordinates.clampingBelowMenuBar`). Matches by global
    /// origin and point size against the current `NSScreen` set; returns nil
    /// when no live screen matches (e.g. the fingerprint is a saved target for
    /// a disconnected display).
    public static func visibleTopY(for fingerprint: DisplayFingerprint) -> CGFloat? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        for screen in NSScreen.screens {
            guard let raw = screen.deviceDescription[key] as? NSNumber else { continue }
            let id = CGDirectDisplayID(raw.uint32Value)
            let bounds = CGDisplayBounds(id)
            guard liveBoundsMatch(bounds, fingerprint) else { continue }
            // Cocoa frames are bottom-left; the menu bar is the gap between the
            // full frame's top and the visible frame's top. The Dock (bottom or
            // side) is intentionally ignored - only the menu bar is a hard clamp.
            let menuBarInset = screen.frame.maxY - screen.visibleFrame.maxY
            return fingerprint.globalOrigin.y + max(0, menuBarInset)
        }
        return nil
    }

    /// Tolerance (in points) for matching a live display's CG bounds against a
    /// saved fingerprint. It absorbs floating-point representation noise in CG
    /// bounds arithmetic - nothing wider. A genuinely fractional offset (say
    /// half a point) is deliberately treated as a real layout difference, not
    /// noise; `genuineOffsetDoesNotMatch` locks that in at one point. The value
    /// matches `DisplayFingerprint.sameGeometry`'s scale epsilon.
    nonisolated static let geometryTolerance: CGFloat = 0.001

    /// True when a live display's `CGDisplayBounds` rect matches the saved
    /// `fingerprint`'s origin and point size within `geometryTolerance`. Pure
    /// and `nonisolated` so it can be unit-tested without reading live
    /// `NSScreen` state or hopping to the main actor.
    nonisolated static func liveBoundsMatch(_ bounds: CGRect, _ fingerprint: DisplayFingerprint) -> Bool {
        abs(bounds.origin.x - fingerprint.globalOrigin.x) <= geometryTolerance
            && abs(bounds.origin.y - fingerprint.globalOrigin.y) <= geometryTolerance
            && abs(bounds.size.width - fingerprint.pointSize.width) <= geometryTolerance
            && abs(bounds.size.height - fingerprint.pointSize.height) <= geometryTolerance
    }

    // MARK: - Private

    /// Lookup from `CGDirectDisplayID` to the matching `NSScreen`, used to pull
    /// `backingScaleFactor` and `localizedName` which aren't exposed via
    /// `CGDirectDisplay*` APIs directly.
    private static func indexedScreens() -> [CGDirectDisplayID: NSScreen] {
        var out: [CGDirectDisplayID: NSScreen] = [:]
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        for screen in NSScreen.screens {
            guard let raw = screen.deviceDescription[key] as? NSNumber else { continue }
            let id = CGDirectDisplayID(raw.uint32Value)
            out[id] = screen
        }
        return out
    }

    private static func fingerprint(
        for id: CGDirectDisplayID,
        isPrimary: Bool,
        screensByID: [CGDirectDisplayID: NSScreen]) -> DisplayFingerprint
    {
        let uuid = uuidForDisplay(id)
        let vendor = CGDisplayVendorNumber(id)
        let model = CGDisplayModelNumber(id)
        let serial = CGDisplaySerialNumber(id)

        let bounds = CGDisplayBounds(id)
        let pointSize = CGSize(width: bounds.width, height: bounds.height)
        let pixelSize = CGSize(
            width: CGFloat(CGDisplayPixelsWide(id)),
            height: CGFloat(CGDisplayPixelsHigh(id)))

        let screen = screensByID[id]
        let scale = Double(screen?.backingScaleFactor ?? 1)
        let localizedName = screen?.localizedName

        return DisplayFingerprint(
            uuid: uuid,
            vendorID: vendor == 0 ? nil : vendor,
            productID: model == 0 ? nil : model,
            serialNumber: serial == 0 ? nil : serial,
            pointSize: pointSize,
            pixelSize: pixelSize,
            scaleFactor: scale,
            globalOrigin: CGPoint(x: bounds.origin.x, y: bounds.origin.y),
            isPrimary: isPrimary,
            localizedName: localizedName)
    }

    private static func uuidForDisplay(_ id: CGDirectDisplayID) -> UUID? {
        guard let ref = CGDisplayCreateUUIDFromDisplayID(id) else { return nil }
        let cfuuid = ref.takeRetainedValue()
        guard let cfString = CFUUIDCreateString(nil, cfuuid) else { return nil }
        let string = cfString as String
        return UUID(uuidString: string)
    }
}

import CoreGraphics
import Foundation

/// Stable, portable description of a display for use in rules. Captured at save
/// time so the placement engine can decide how closely the current arrangement
/// matches.
public struct DisplayFingerprint: Codable, Hashable, Sendable, Identifiable {
    /// UUID returned by `CGDisplayCreateUUIDFromDisplayID`. Persists across
    /// replug and across reboots for the same physical panel; absent for some
    /// virtual displays, in which case fall back to the vendor tuple.
    public var uuid: UUID?

    public var vendorID: UInt32?
    public var productID: UInt32?
    public var serialNumber: UInt32?

    /// Logical (point) size used by AppKit and Accessibility. Depends on the
    /// user's `Looks like` scale setting.
    public var pointSize: CGSize

    /// Native pixel size. Used with `pointSize` to derive effective scale.
    public var pixelSize: CGSize

    /// `NSScreen.backingScaleFactor`. 2.0 for typical Retina; non-integer on
    /// HiDPI scaled modes.
    public var scaleFactor: Double

    /// Origin in the global display arrangement (top-left of this display in
    /// Cocoa coordinates flipped to top-left convention).
    public var globalOrigin: CGPoint

    public var isPrimary: Bool

    /// Optional friendly name captured from `NSScreen.localizedName`.
    public var localizedName: String?

    public init(
        uuid: UUID?,
        vendorID: UInt32?,
        productID: UInt32?,
        serialNumber: UInt32?,
        pointSize: CGSize,
        pixelSize: CGSize,
        scaleFactor: Double,
        globalOrigin: CGPoint,
        isPrimary: Bool,
        localizedName: String? = nil)
    {
        self.uuid = uuid
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.pointSize = pointSize
        self.pixelSize = pixelSize
        self.scaleFactor = scaleFactor
        self.globalOrigin = globalOrigin
        self.isPrimary = isPrimary
        self.localizedName = localizedName
    }

    /// Identity key used for grouping. Prefers UUID; falls back to the vendor
    /// tuple; last resort is the origin plus point size, which is sufficient
    /// within a single running session.
    public var id: String {
        if let uuid {
            return "uuid:\(uuid.uuidString)"
        }
        if let vendorID, let productID {
            let serial = serialNumber.map(String.init) ?? "x"
            return "vps:\(vendorID):\(productID):\(serial)"
        }
        return "geo:\(Int(globalOrigin.x)):\(Int(globalOrigin.y)):\(Int(pointSize.width))x\(Int(pointSize.height))"
    }

    /// True when resolution and scale are indistinguishable; safe to replay
    /// stored absolute coordinates without proportional remapping.
    public func sameGeometry(as other: DisplayFingerprint) -> Bool {
        pointSize == other.pointSize
            && pixelSize == other.pixelSize
            && abs(scaleFactor - other.scaleFactor) < 0.001
    }
}

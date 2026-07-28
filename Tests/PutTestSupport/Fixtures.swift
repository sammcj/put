import ApplicationServices
import CoreGraphics
import Foundation
import PutCore
import PutStorage
import PutWindows

// Shared test fixture builders. Each holds the construction boilerplate once;
// suites keep a thin private wrapper carrying their own defaults and delegate
// here. The builders use distinct names from the wrappers so a suite that both
// imports this module and keeps a same-purpose local does not hit the Swift 6
// same-name overload ambiguity.

/// Whether the host has at least one active display, checked via
/// `CGGetActiveDisplayList` (a nil buffer just returns the count) rather than
/// `NSScreen`/`DisplayProbe`, both `@MainActor` - so it is callable from a
/// nonisolated `.disabled(if:)` autoclosure. Suites that drive a real restore
/// gate on this so they SKIP (not vacuously pass) on a headless runner.
public let hasActiveDisplays: Bool = {
    var count: UInt32 = 0
    return CGGetActiveDisplayList(0, nil, &count) == .success && count > 0
}()

/// A `ConfigStore` rooted in a fresh temp directory, with the paths needed to
/// inspect the on-disk config or tear the directory down afterwards.
public struct TempStore {
    public let store: ConfigStore
    public let url: URL
    public let root: URL

    public init(store: ConfigStore, url: URL, root: URL) {
        self.store = store
        self.url = url
        self.root = root
    }

    /// Removes the backing temp directory; ignores failure.
    public func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// Builds a `ConfigStore` backed by a unique temp directory. `prefix` only
/// names that directory, so it is cosmetic; the UUID guarantees uniqueness.
public func makeTempStore(prefix: String = "put-tests") throws -> TempStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("Put/config.json")
    return TempStore(store: ConfigStore(fileURL: url), url: url, root: root)
}

/// Builds a `WindowHandle` wrapping a live AX element for the current process.
/// The element is real so AX writes have a target, but suites stub the mutator
/// so no AX traffic occurs.
///
/// `processID` also selects the AX element, and `WindowIdentity` compares by
/// `CFEqual` on that element - so handles built with the default pid all share
/// one identity, and a suite needing distinct per-window identities must pass a
/// distinct pid. Creating an element for a pid that isn't running is safe: no
/// IPC happens until an attribute is read.
public func makeWindowHandle(
    bundleID: String,
    title: String = "W",
    frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100),
    processID: pid_t = getpid()) -> WindowHandle
{
    let element = AXUIElementCreateApplication(processID)
    let descriptor = WindowDescriptor(
        bundleID: bundleID,
        processID: processID,
        title: title,
        role: "AXWindow",
        subrole: "AXStandardWindow",
        frame: frame,
        isMinimised: false)
    return WindowHandle(descriptor: descriptor, axElement: element, appElement: element)
}

/// Builds a `DisplayFingerprint`. `pixelSize` defaults to `pointSize` when
/// omitted, matching the same-resolution (unscaled) case.
public func makeDisplayFingerprint(
    uuid: UUID? = nil,
    vendorID: UInt32? = nil,
    productID: UInt32? = nil,
    serialNumber: UInt32? = nil,
    pointSize: CGSize = CGSize(width: 1920, height: 1080),
    pixelSize: CGSize? = nil,
    scaleFactor: Double = 1,
    globalOrigin: CGPoint = .zero,
    isPrimary: Bool = false,
    localizedName: String? = nil) -> DisplayFingerprint
{
    DisplayFingerprint(
        uuid: uuid,
        vendorID: vendorID,
        productID: productID,
        serialNumber: serialNumber,
        pointSize: pointSize,
        pixelSize: pixelSize ?? pointSize,
        scaleFactor: scaleFactor,
        globalOrigin: globalOrigin,
        isPrimary: isPrimary,
        localizedName: localizedName)
}

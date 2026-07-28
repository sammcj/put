import ApplicationServices
import CoreGraphics
import Foundation
import PutCore

/// Pairs a `WindowDescriptor` with the live `AXUIElement` used for mutation.
///
/// `AXUIElement` is a Core Foundation type with retain/release semantics that
/// work across threads when not aliased, so this handle is marked
/// `@unchecked Sendable` and is safe to hand to another actor for a single
/// mutation pass. After a handle has been used it may become invalid if the
/// underlying window has been closed; the `WindowMutator` detects this and
/// reports `AXOperationError.elementGone`.
public final class WindowHandle: @unchecked Sendable {
    public let descriptor: WindowDescriptor
    let axElement: AXUIElement
    let appElement: AXUIElement

    public init(descriptor: WindowDescriptor, axElement: AXUIElement, appElement: AXUIElement) {
        self.descriptor = descriptor
        self.axElement = axElement
        self.appElement = appElement
    }

    /// Opaque, hashable identity for the underlying window. Stable across
    /// probes within the same process lifetime via `CFEqual`/`CFHash`.
    /// Other modules use this to key per-window state without depending on
    /// `ApplicationServices` directly.
    public var identity: WindowIdentity {
        WindowIdentity(element: axElement)
    }
}

/// Hashable wrapper around the live `AXUIElement` for a window. Lives
/// here next to `WindowHandle` so PutAutomation can key dictionaries by
/// window identity without importing ApplicationServices itself.
public struct WindowIdentity: Hashable, @unchecked Sendable {
    let element: AXUIElement

    public static func == (lhs: WindowIdentity, rhs: WindowIdentity) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

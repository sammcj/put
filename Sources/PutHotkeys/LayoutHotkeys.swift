import Foundation
import KeyboardShortcuts
import PutCore

public extension KeyboardShortcuts.Name {
    /// Dynamic per-layout activation shortcut. The raw name is stable across
    /// runs as long as the `Layout.id` is stable, which means a user-recorded
    /// binding persists.
    static func layoutActivation(layoutID: UUID) -> Self {
        Self("layout.\(layoutID.uuidString)")
    }
}

/// Narrow injection seam over the subset of `KeyboardShortcuts` API that
/// `LayoutHotkeys` uses. The upstream package dispatches through a
/// module-global registry that can't be introspected from tests; this
/// protocol lets test hosts capture calls instead.
@MainActor
public protocol KeyboardShortcutsRegistering {
    func enable(_ name: KeyboardShortcuts.Name)
    func disable(_ name: KeyboardShortcuts.Name)
    func removeHandler(for name: KeyboardShortcuts.Name)
    func onKeyUp(for name: KeyboardShortcuts.Name, action: @escaping () -> Void)
}

@MainActor
public struct DefaultKeyboardShortcutsRegistry: KeyboardShortcutsRegistering {
    public init() {}
    public func enable(_ name: KeyboardShortcuts.Name) {
        KeyboardShortcuts.enable(name)
    }

    public func disable(_ name: KeyboardShortcuts.Name) {
        KeyboardShortcuts.disable(name)
    }

    public func removeHandler(for name: KeyboardShortcuts.Name) {
        KeyboardShortcuts.removeHandler(for: name)
    }

    public func onKeyUp(for name: KeyboardShortcuts.Name, action: @escaping () -> Void) {
        KeyboardShortcuts.onKeyUp(for: name, action: action)
    }
}

/// Registers and unregisters activation hotkeys for each `Layout` at runtime.
///
/// The `KeyboardShortcuts` package stores the chosen binding (if any) in
/// `UserDefaults` keyed by the `Name`'s raw value, so users see their
/// existing shortcut reappear whenever the layout list is rebuilt.
@MainActor
public final class LayoutHotkeys {
    public typealias Activator = (UUID) -> Void

    private var activator: Activator?
    private var knownLayoutIDs: Set<UUID> = []
    private let registry: any KeyboardShortcutsRegistering

    public init(registry: any KeyboardShortcutsRegistering = DefaultKeyboardShortcutsRegistry()) {
        self.registry = registry
    }

    public func bind(activator: @escaping Activator) {
        self.activator = activator
    }

    /// Call whenever the layout list changes. Registers handlers for any new
    /// layouts and removes handlers for ones that have disappeared.
    public func syncRegistrations(layoutIDs: [UUID]) {
        let current = Set(layoutIDs)
        let added = current.subtracting(knownLayoutIDs)
        let removed = knownLayoutIDs.subtracting(current)

        // Fully tear down removed layouts: disable stops the hotkey from
        // firing, removeHandler detaches the closure so it can't leak or
        // fire stale if the UUID is ever reused.
        for id in removed {
            let name = KeyboardShortcuts.Name.layoutActivation(layoutID: id)
            registry.disable(name)
            registry.removeHandler(for: name)
        }

        for id in added {
            let name = KeyboardShortcuts.Name.layoutActivation(layoutID: id)
            registry.enable(name)
            registry.onKeyUp(for: name) { [weak self] in
                MainActor.assumeIsolated {
                    self?.activator?(id)
                }
            }
        }

        knownLayoutIDs = current
    }

    public func removeAll() {
        for id in knownLayoutIDs {
            let name = KeyboardShortcuts.Name.layoutActivation(layoutID: id)
            registry.disable(name)
            registry.removeHandler(for: name)
        }
        knownLayoutIDs.removeAll()
    }
}

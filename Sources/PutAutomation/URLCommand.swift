import Foundation
import PutCore

/// A `put://` command, for launchers and scripts (Raycast, Alfred, Shortcuts,
/// Stream Deck, `open put://restore-all`). Each maps onto an action that
/// already has a hotkey or menu item, with the same restore source, so a URL
/// can't do anything the user couldn't do by hand.
public enum URLCommand: Equatable, Sendable {
    case saveFocusedWindow
    case saveFocusedWindowTitleOnly
    case saveAllWindows
    case restoreActiveWindow
    case restoreAllWindows
    case activateLayout(LayoutReference)
    /// `tab` is the raw tab name; the UI layer owns the mapping onto its tabs.
    case openSettings(tab: String?)

    public enum LayoutReference: Equatable, Sendable {
        case id(UUID)
        case name(String)

        /// `id` wins when both are given. A malformed id is rejected rather
        /// than falling back to `name`, which could pick a different layout.
        init?(id: String?, name: String?) {
            if let id {
                guard let uuid = UUID(uuidString: id) else { return nil }
                self = .id(uuid)
            } else if let name {
                self = .name(name)
            } else {
                return nil
            }
        }

        /// The layout this reference names. Names compare case-insensitively
        /// since they're typed by hand into launcher configs; the first match
        /// wins when two layouts share a name.
        public func resolve(in layouts: [PutCore.Layout]) -> PutCore.Layout? {
            switch self {
            case let .id(id):
                layouts.first { $0.id == id }
            case let .name(name):
                layouts.first { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
            }
        }
    }

    public static let scheme = "put"

    /// Nil for any other scheme, an unknown command, or a layout command that
    /// names no layout. Unknown commands fail rather than falling back to a
    /// default, since a typo should not move windows.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let host = url.host(percentEncoded: false)?.lowercased()
        else { return nil }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            query.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }

        switch host {
        case "save-active":
            self = .saveFocusedWindow
        case "save-active-title":
            self = .saveFocusedWindowTitleOnly
        case "save-all":
            self = .saveAllWindows
        case "restore-active":
            self = .restoreActiveWindow
        case "restore-all":
            self = .restoreAllWindows
        case "layout":
            guard let reference = LayoutReference(id: value("id"), name: value("name")) else { return nil }
            self = .activateLayout(reference)
        case "settings":
            self = .openSettings(tab: value("tab")?.lowercased())
        default:
            return nil
        }
    }
}

import ApplicationServices
import Foundation

public enum AXOperationError: Error, Equatable, CustomStringConvertible {
    case accessDenied
    case elementGone
    case attributeUnsupported(String)
    case operationFailed(AXError, String)
    /// The AX writes all returned `.success` but the actual window frame
    /// still differs from the requested target beyond the tolerance. Happens
    /// with apps that accept `kAXSizeAttribute` writes then silently ignore
    /// them (Firefox post-wake, some Electron apps, Terminal with char-grid
    /// constraints).
    case drifted(target: CGRect, actual: CGRect, attempts: Int)

    public init(_ error: AXError, context: String) {
        switch error {
        case .success:
            self = .operationFailed(.success, context)
        case .apiDisabled:
            self = .accessDenied
        case .invalidUIElement, .invalidUIElementObserver:
            self = .elementGone
        case .attributeUnsupported, .actionUnsupported, .notificationUnsupported:
            self = .attributeUnsupported(context)
        default:
            self = .operationFailed(error, context)
        }
    }

    public var description: String {
        switch self {
        case .accessDenied:
            "Accessibility permission not granted"
        case .elementGone:
            "Accessibility element no longer valid"
        case let .attributeUnsupported(ctx):
            "Accessibility attribute unsupported: \(ctx)"
        case let .operationFailed(error, ctx):
            "Accessibility operation failed (\(error.rawValue)) during \(ctx)"
        case let .drifted(target, actual, attempts):
            "Window frame drifted after \(attempts) attempts: target=\(target) actual=\(actual)"
        }
    }
}

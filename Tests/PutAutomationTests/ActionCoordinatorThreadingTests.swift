import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
@testable import PutAutomation
@testable import PutCore
@testable import PutStorage
import PutTestSupport
@testable import PutWindows
import Testing

// MARK: - Restore write threading (C5)

/// Guards that restore routes its blocking AX writes off the main actor.
/// `WindowMutator.setFrame`/`setSize` sleep up to ~0.7s per drifting window; on
/// the main actor that freezes the menu bar and stalls the debounce timers
/// during display storms. The recording mutator captures `Thread.isMainThread`
/// per call so a regression that runs the write loop on the main thread fails
/// here. Lives in its own file so the main ActionCoordinator suite stays under
/// the type-body and file-length caps.
@MainActor
@Suite("ActionCoordinator write threading")
struct ActionCoordinatorThreadingTests {
    /// Records the executing thread and write kind for every call. Access is
    /// lock-guarded because the calls land on a background thread once the fix
    /// is in place, while the assertions read from the main actor.
    private final class ThreadRecordingMutator: WindowMutating, @unchecked Sendable {
        struct Call {
            let kind: String
            let onMain: Bool
        }

        private let lock = NSLock()
        private var storage: [Call] = []

        var calls: [Call] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func setFrame(_: WindowHandle, to _: CGRect) throws {
            record("setFrame")
        }

        func setSize(_: WindowHandle, to _: CGSize) throws {
            record("setSize")
        }

        func setPosition(_: WindowHandle, to _: CGPoint) throws {
            record("setPosition")
        }

        func raise(_: WindowHandle) {}

        private func record(_ kind: String) {
            let onMain = Thread.isMainThread
            lock.lock()
            storage.append(Call(kind: kind, onMain: onMain))
            lock.unlock()
        }
    }

    /// A display the live host can never match, forcing the proportional
    /// fallback so a placement (and therefore a write) reliably fires on any
    /// host that has at least one real display.
    private func absentDisplay() -> DisplayFingerprint {
        DisplayFingerprint(
            uuid: UUID(),
            vendorID: 60001,
            productID: 60002,
            serialNumber: 60003,
            pointSize: CGSize(width: 5120, height: 2880),
            pixelSize: CGSize(width: 5120, height: 2880),
            scaleFactor: 1,
            globalOrigin: CGPoint(x: 99999, y: 99999),
            isPrimary: false)
    }

    private func dummyFrame() -> WindowFrame {
        WindowFrame(
            absolute: CGRect(x: 0, y: 0, width: 100, height: 100),
            normalised: UnitRect(x: 0, y: 0, width: 0.1, height: 0.1))
    }

    private func rule(bundleID: String, restoreComponents: RestoreComponents) -> Rule {
        Rule(
            matchCriteria: MatchCriteria(bundleID: bundleID, applyToAllWindows: true),
            targetDisplay: absentDisplay(),
            frame: dummyFrame(),
            restoreComponents: restoreComponents)
    }

    @Test(.disabled(if: !hasActiveDisplays, "requires at least one active display"))
    func restoreRunsWritesOffMainThreadPreservingOrder() async throws {
        // Two windows: a position rule (routes to setFrame) then a size-only
        // rule (routes to setSize). Restore visits them in array order, so the
        // recorded kinds must stay [setFrame, setSize] and both must run off the
        // main thread.
        let ruleA = rule(bundleID: "com.example.aaa", restoreComponents: .sizeAndPosition)
        let ruleB = rule(bundleID: "com.example.bbb", restoreComponents: .sizeOnly)
        let layout = Layout(id: UUID(), name: "L", rules: [ruleA, ruleB])
        let state = AppState(config: Config(layouts: [layout], activeLayoutID: layout.id))
        let store = try makeTempStore(prefix: "put-threading").store
        let handleA = makeWindowHandle(
            bundleID: "com.example.aaa",
            frame: CGRect(x: 100, y: 100, width: 600, height: 400))
        let handleB = makeWindowHandle(
            bundleID: "com.example.bbb",
            frame: CGRect(x: 100, y: 100, width: 600, height: 400))
        let mutator = ThreadRecordingMutator()
        let coordinator = ActionCoordinator(
            state: state,
            store: store,
            probe: StubWindowProbe(handles: [handleA, handleB]),
            mutator: mutator,
            gate: StubAccessibilityGate())

        await coordinator.restore(windowsForUI: [handleA, handleB], source: .explicit)

        // The trait guarantees a display is present, so writes must have fired;
        // an empty set here is a genuine regression (restore stopped writing),
        // not a headless skip.
        let calls = mutator.calls
        try #require(!calls.isEmpty)
        #expect(calls.allSatisfy { !$0.onMain }, "AX writes must run off the main thread")
        #expect(calls.map(\.kind) == ["setFrame", "setSize"], "write order must be preserved")
    }
}

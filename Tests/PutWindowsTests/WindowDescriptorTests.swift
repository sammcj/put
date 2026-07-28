import CoreGraphics
import Foundation
@testable import PutWindows
import Testing

@Suite("WindowDescriptor")
struct WindowDescriptorTests {
    @Test
    func equalityIgnoresNothing() {
        let original = WindowDescriptor(
            bundleID: "com.apple.Safari",
            processID: 123,
            title: "GitHub",
            role: "AXWindow",
            subrole: "AXStandardWindow",
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            isMinimised: false)
        var mutated = original
        #expect(original == mutated)
        mutated.title = "different"
        #expect(original != mutated)
    }

    @Test
    func axOperationErrorSurfacesReadableDescription() {
        let error = AXOperationError.accessDenied
        #expect(error.description.contains("Accessibility"))
    }

    @Test
    func driftErrorDescriptionIncludesFrames() {
        let error = AXOperationError.drifted(
            target: CGRect(x: 0, y: 0, width: 1000, height: 800),
            actual: CGRect(x: 0, y: 0, width: 600, height: 800),
            attempts: 3)
        #expect(error.description.contains("drifted"))
        #expect(error.description.contains("3"))
    }

    @Test
    func frameMatchesTreatsSubPointDifferenceAsEqual() {
        // Sub-point float noise from AX readback must not trigger retry.
        let target = CGRect(x: 100, y: 100, width: 1000, height: 800)
        let actual = CGRect(x: 100.5, y: 99.5, width: 1000.5, height: 799.5)
        #expect(WindowMutator.frameMatches(target: target, actual: actual))
    }

    @Test
    func frameMatchesRejectsSizeDrift() {
        // Firefox-class "size ignored" symptom: origin lands but size still
        // off by tens of points.
        let target = CGRect(x: 100, y: 100, width: 1000, height: 800)
        let actual = CGRect(x: 100, y: 100, width: 900, height: 800)
        #expect(!WindowMutator.frameMatches(target: target, actual: actual))
    }

    @Test
    func frameMatchesRejectsAsymmetricSizeDrift() {
        // Width holds, height drifted — common when a sidebar/tab-bar is
        // pinned and vertical grows but horizontal doesn't.
        let target = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let actual = CGRect(x: 0, y: 0, width: 1000, height: 650)
        #expect(!WindowMutator.frameMatches(target: target, actual: actual))
    }

    @Test
    func frameMatchesRejectsOriginDrift() {
        // App accepted size but ignored position — used to be invisible to
        // the size-only tolerance check; now caught.
        let target = CGRect(x: 1500, y: 795, width: 1000, height: 800)
        let actual = CGRect(x: 200, y: 795, width: 1000, height: 800)
        #expect(!WindowMutator.frameMatches(target: target, actual: actual))
    }
}

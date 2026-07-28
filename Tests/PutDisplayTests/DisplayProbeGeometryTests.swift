import CoreGraphics
import Foundation
@testable import PutCore
@testable import PutDisplay
import PutTestSupport
import Testing

@Suite("DisplayProbe geometry matching")
struct DisplayProbeGeometryTests {
    @Test
    func subIntegerOriginStillMatches() {
        // Some virtual and mirrored displays report a fractional CG origin.
        // Exact == would reject it and silently defeat the menu-bar clamp; the
        // tolerant comparison must treat a sub-epsilon offset as a match.
        let fingerprint = makeDisplayFingerprint(
            pointSize: CGSize(width: 1920, height: 1080),
            globalOrigin: .zero)
        let liveBounds = CGRect(x: 0.0005, y: -0.0005, width: 1920.0005, height: 1079.9995)
        #expect(DisplayProbe.liveBoundsMatch(liveBounds, fingerprint))
    }

    @Test
    func exactBoundsStillMatch() {
        let fingerprint = makeDisplayFingerprint(
            pointSize: CGSize(width: 2560, height: 1440),
            globalOrigin: CGPoint(x: 1920, y: 0))
        let liveBounds = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        #expect(DisplayProbe.liveBoundsMatch(liveBounds, fingerprint))
    }

    @Test
    func genuineOffsetDoesNotMatch() {
        // A one-point offset is a real layout difference, not float noise.
        let fingerprint = makeDisplayFingerprint(
            pointSize: CGSize(width: 1920, height: 1080),
            globalOrigin: .zero)
        let liveBounds = CGRect(x: 1, y: 0, width: 1920, height: 1080)
        #expect(!DisplayProbe.liveBoundsMatch(liveBounds, fingerprint))
    }
}

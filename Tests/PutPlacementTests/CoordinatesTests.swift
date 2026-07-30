import CoreGraphics
import Foundation
@testable import PutCore
@testable import PutPlacement
import Testing

@Suite("Coordinates")
struct CoordinatesTests {
    private func makeDisplay(
        origin: CGPoint = .zero,
        point: CGSize = CGSize(width: 1920, height: 1080),
        primary: Bool = true) -> DisplayFingerprint
    {
        DisplayFingerprint(
            uuid: UUID(),
            vendorID: nil,
            productID: nil,
            serialNumber: nil,
            pointSize: point,
            pixelSize: CGSize(width: point.width * 2, height: point.height * 2),
            scaleFactor: 2,
            globalOrigin: origin,
            isPrimary: primary)
    }

    @Test
    func toLocalAndBackIsIdentity() {
        let display = makeDisplay(origin: CGPoint(x: 1920, y: 100))
        let global = CGRect(x: 2020, y: 150, width: 800, height: 600)
        let local = Coordinates.toLocal(global, onDisplay: display)
        let back = Coordinates.toGlobal(local, onDisplay: display)
        #expect(back == global)
    }

    @Test
    func normalisedRectIsIndependentOfDisplayOrigin() {
        let atOrigin = makeDisplay(origin: .zero)
        let shifted = makeDisplay(origin: CGPoint(x: -5000, y: 3000))
        let rect = CGRect(x: 192, y: 216, width: 960, height: 540)
        let unitAtOrigin = Coordinates.normalise(rect, onDisplay: atOrigin)
        let unitShifted = Coordinates.normalise(rect, onDisplay: shifted)
        #expect(unitAtOrigin == unitShifted)
        #expect(abs(unitAtOrigin.x - 0.1) < 1e-9)
        #expect(abs(unitAtOrigin.y - 0.2) < 1e-9)
        #expect(abs(unitAtOrigin.width - 0.5) < 1e-9)
        #expect(abs(unitAtOrigin.height - 0.5) < 1e-9)
    }

    @Test
    func normaliseDenormaliseRoundtrip() {
        let display = makeDisplay(point: CGSize(width: 2560, height: 1440))
        let local = CGRect(x: 128, y: 72, width: 1280, height: 720)
        let unit = Coordinates.normalise(local, onDisplay: display)
        let back = Coordinates.denormalise(unit, onDisplay: display)
        #expect(abs(back.origin.x - local.origin.x) < 1e-6)
        #expect(abs(back.origin.y - local.origin.y) < 1e-6)
        #expect(abs(back.size.width - local.size.width) < 1e-6)
        #expect(abs(back.size.height - local.size.height) < 1e-6)
    }

    @Test
    func denormaliseGuardsZeroPointSize() {
        // A display reporting a zero point-size during transient post-wake
        // enumeration must not collapse every saved rule to a 0x0 frame at the
        // origin. The guard mirrors normalise's max(..., 1).
        let display = makeDisplay(point: .zero)
        let unit = UnitRect(x: 0.5, y: 0.25, width: 0.5, height: 0.5)
        let frame = Coordinates.denormalise(unit, onDisplay: display)
        #expect(frame != .zero)
        #expect(frame == CGRect(x: 0.5, y: 0.25, width: 0.5, height: 0.5))
    }

    @Test
    func denormalisingOntoDifferentDisplayGivesProportionalSize() {
        let source = makeDisplay(point: CGSize(width: 3840, height: 2160))
        let target = makeDisplay(point: CGSize(width: 1920, height: 1080))
        let local = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let unit = Coordinates.normalise(local, onDisplay: source)
        let projected = Coordinates.denormalise(unit, onDisplay: target)
        #expect(projected == CGRect(x: 0, y: 0, width: 960, height: 540))
    }

    @Test
    func displayContainingPicksMaxOverlap() {
        let laptop = makeDisplay(origin: CGPoint(x: -1728, y: 720), point: CGSize(width: 1728, height: 1117))
        let external = makeDisplay(origin: .zero, point: CGSize(width: 3840, height: 2160), primary: true)
        let windowOnExternal = CGRect(x: 100, y: 100, width: 800, height: 600)
        let windowOnLaptop = CGRect(x: -1500, y: 900, width: 800, height: 400)
        #expect(Coordinates.displayContaining(windowOnExternal, among: [laptop, external])?.isPrimary == true)
        #expect(Coordinates.displayContaining(windowOnLaptop, among: [laptop, external])?.globalOrigin == laptop
            .globalOrigin)
    }

    @Test
    func displayContainingFallsBackToPrimaryWhenNoOverlap() {
        let laptop = makeDisplay(origin: CGPoint(x: -10000, y: 0), point: CGSize(width: 100, height: 100))
        let primary = makeDisplay(origin: .zero, point: CGSize(width: 1920, height: 1080), primary: true)
        let orphan = CGRect(x: 20000, y: 0, width: 10, height: 10)
        #expect(Coordinates.displayContaining(orphan, among: [laptop, primary])?.isPrimary == true)
    }

    @Test
    func displayContainingReturnsNilForNullRect() {
        let primary = makeDisplay(origin: .zero, point: CGSize(width: 1920, height: 1080), primary: true)
        #expect(Coordinates.displayContaining(.null, among: [primary]) == nil)
    }

    @Test
    func displayContainingReturnsNilForInfiniteRect() {
        let primary = makeDisplay(origin: .zero, point: CGSize(width: 1920, height: 1080), primary: true)
        #expect(Coordinates.displayContaining(.infinite, among: [primary]) == nil)
    }

    @Test
    func displayContainingReturnsNilForNaNComponentRect() {
        let primary = makeDisplay(origin: .zero, point: CGSize(width: 1920, height: 1080), primary: true)
        let garbage = CGRect(x: CGFloat.nan, y: 0, width: 800, height: 600)
        #expect(Coordinates.displayContaining(garbage, among: [primary]) == nil)
    }

    @Test
    func clampBelowMenuBarShiftsAboveLineDownPreservingSize() {
        // A proportional remap landing the top under the menu bar (the Messages
        // bug): origin Y above the visible top must shift to exactly the line.
        let frame = CGRect(x: 954, y: 34, width: 1102, height: 722)
        let clamped = Coordinates.clampingBelowMenuBar(frame, visibleTopY: 40)
        #expect(clamped == CGRect(x: 954, y: 40, width: 1102, height: 722))
    }

    @Test
    func clampBelowMenuBarLeavesReachableFrameUntouched() {
        let frame = CGRect(x: 100, y: 200, width: 800, height: 600)
        #expect(Coordinates.clampingBelowMenuBar(frame, visibleTopY: 40) == frame)
        // Exactly on the line is already reachable - no shift.
        let onLine = CGRect(x: 0, y: 40, width: 400, height: 300)
        #expect(Coordinates.clampingBelowMenuBar(onLine, visibleTopY: 40) == onLine)
    }

    @Test
    func clampBelowMenuBarHonoursNonZeroDisplayOrigin() {
        // Secondary display stacked below the primary: visible top is its
        // global origin Y plus that display's own menu-bar inset.
        let frame = CGRect(x: 200, y: 2160, width: 600, height: 400)
        let clamped = Coordinates.clampingBelowMenuBar(frame, visibleTopY: 2185)
        #expect(clamped == CGRect(x: 200, y: 2185, width: 600, height: 400))
    }

    // MARK: - Moving between displays

    @Test
    func movingBetweenDisplaysKeepsSizeAndProportionalCentre() {
        let source = makeDisplay(origin: .zero, point: CGSize(width: 1600, height: 1000))
        let target = makeDisplay(
            origin: CGPoint(x: 1600, y: -200),
            point: CGSize(width: 3200, height: 2000),
            primary: false)
        let window = CGRect(x: 160, y: 100, width: 800, height: 600)

        let moved = Coordinates.moving(window, onto: target, from: source)

        #expect(moved.size == window.size)
        // Centre (560, 400) is 35% across and 40% down the source, so it lands
        // 35%/40% into the target at (1120, 800); the origin is that less half
        // the (unchanged) window size, offset by the target's global origin.
        #expect(moved.origin == CGPoint(x: 1600 + 720, y: -200 + 500))
    }

    @Test
    func movingAMaximisedWindowOntoALargerDisplayCentresIt() {
        // A window filling its display has its origin at (0, 0), which maps to
        // (0, 0) on any target - origin-mapping left it stranded in the corner
        // at its old size. Mapping the centre puts it in the middle instead.
        let source = makeDisplay(origin: .zero, point: CGSize(width: 1600, height: 1000))
        let target = makeDisplay(
            origin: CGPoint(x: 1600, y: 0),
            point: CGSize(width: 3200, height: 2000),
            primary: false)
        let maximised = CGRect(x: 0, y: 0, width: 1600, height: 1000)

        let moved = Coordinates.moving(maximised, onto: target, from: source)

        #expect(moved.size == maximised.size)
        // Exactly centred: (3200 - 1600) / 2, (2000 - 1000) / 2.
        #expect(moved.origin == CGPoint(x: 1600 + 800, y: 500))
    }

    @Test
    func movingOntoTheSameDisplayIsIdentity() {
        let display = makeDisplay(origin: CGPoint(x: -1600, y: 0), point: CGSize(width: 1600, height: 1000))
        let window = CGRect(x: -1200, y: 300, width: 700, height: 500)
        #expect(Coordinates.moving(window, onto: display, from: display) == window)
    }

    @Test
    func movingOntoTheSameDisplayLeavesAnOverhangingWindowAlone() {
        // The identity has to hold for a window hanging off an edge too, or a
        // display-only rule would drag a deliberately-parked window back
        // on-screen on every auto trigger.
        let display = makeDisplay(origin: .zero, point: CGSize(width: 1600, height: 1000))
        let offLeft = CGRect(x: -200, y: 100, width: 900, height: 700)
        let offBottom = CGRect(x: 100, y: 800, width: 900, height: 700)
        #expect(Coordinates.moving(offLeft, onto: display, from: display) == offLeft)
        #expect(Coordinates.moving(offBottom, onto: display, from: display) == offBottom)
    }

    @Test
    func movingClampsWindowInsideTheTargetDisplay() {
        // Near the right edge of a wide panel, moving onto a narrow one would
        // hang the window off the edge; clamp it back on.
        let source = makeDisplay(origin: .zero, point: CGSize(width: 3200, height: 2000))
        let target = makeDisplay(
            origin: CGPoint(x: 3200, y: 0),
            point: CGSize(width: 1600, height: 1000),
            primary: false)
        let window = CGRect(x: 3000, y: 1900, width: 800, height: 600)

        let moved = Coordinates.moving(window, onto: target, from: source)

        #expect(moved.size == window.size)
        // Mapped centre puts it past the target's bottom-right, so both axes
        // clamp to the far edge: (1600 - 800, 1000 - 600).
        #expect(moved.origin == CGPoint(x: 3200 + 800, y: 400))
    }

    @Test
    func movingPinsAWindowLargerThanTheTargetToTheTopLeft() {
        // Not resizing is the point of the scope, so an oversized window is
        // pinned rather than shrunk.
        let source = makeDisplay(origin: .zero, point: CGSize(width: 3200, height: 2000))
        let target = makeDisplay(
            origin: CGPoint(x: 3200, y: 0),
            point: CGSize(width: 1600, height: 1000),
            primary: false)
        let window = CGRect(x: 400, y: 300, width: 2400, height: 1600)

        let moved = Coordinates.moving(window, onto: target, from: source)

        #expect(moved == CGRect(x: 3200, y: 0, width: 2400, height: 1600))
    }
}

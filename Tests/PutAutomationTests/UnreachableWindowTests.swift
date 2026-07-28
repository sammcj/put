import ApplicationServices
import CoreGraphics
import Foundation
@testable import PutAutomation
@testable import PutCore
@testable import PutWindows
import Testing

/// Pure detection of windows stranded on another Space: a rule whose app is
/// running and has a window on some other Space (in `offSpaceBundleIDs`) but no
/// reachable window in the current snapshot. The off-Space set is what tells an
/// exiled window apart from a closed one. Exercises
/// `ActionCoordinator.unreachableRules` without the live Accessibility API.
@MainActor
@Suite("Unreachable window detection")
struct UnreachableWindowTests {
    private func handle(bundleID: String) -> WindowHandle {
        let element = AXUIElementCreateApplication(getpid())
        let descriptor = WindowDescriptor(
            bundleID: bundleID,
            processID: getpid(),
            title: "Doc",
            role: "AXWindow",
            subrole: "AXStandardWindow",
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            isMinimised: false)
        return WindowHandle(descriptor: descriptor, axElement: element, appElement: element)
    }

    private func rule(
        bundleID: String,
        label: String = "",
        isEnabled: Bool = true,
        restoresPosition: Bool = true) -> Rule
    {
        Rule(
            descriptiveLabel: label,
            matchCriteria: MatchCriteria(bundleID: bundleID, applyToAllWindows: true),
            targetDisplay: DisplayFingerprint(
                uuid: nil,
                vendorID: nil,
                productID: nil,
                serialNumber: nil,
                pointSize: CGSize(width: 1440, height: 900),
                pixelSize: CGSize(width: 2880, height: 1800),
                scaleFactor: 2,
                globalOrigin: .zero,
                isPrimary: true,
                localizedName: "Built-in"),
            frame: WindowFrame(
                absolute: CGRect(x: 0, y: 0, width: 400, height: 300),
                normalised: UnitRect(x: 0, y: 0, width: 0.3, height: 0.3)),
            isEnabled: isEnabled,
            restoresPosition: restoresPosition)
    }

    private func layout(_ rules: [Rule]) -> Layout {
        Layout(id: UUID(), name: "Test", rules: rules)
    }

    @Test("App running with an off-Space window, none reachable -> flagged")
    func strandedWindowFlagged() {
        let subject = rule(bundleID: "com.apple.iCal", label: "Calendar")
        let result = ActionCoordinator.unreachableRules(
            in: layout([subject]),
            snapshot: [handle(bundleID: "com.apple.Music")],
            runningBundleIDs: ["com.apple.iCal", "com.apple.Music"],
            offSpaceBundleIDs: ["com.apple.iCal"])
        #expect(result.count == 1)
        #expect(result.first?.ruleID == subject.id)
        #expect(result.first?.label == "Calendar")
        #expect(result.first?.displayName == "Built-in")
    }

    @Test("Closed window (no window on any Space) is not flagged")
    func closedWindowNotFlagged() {
        // App running, no reachable window, but also no off-Space window: the
        // window was closed, not exiled. This is the false positive the
        // off-Space gate exists to prevent.
        let subject = rule(bundleID: "com.apple.iCal")
        let result = ActionCoordinator.unreachableRules(
            in: layout([subject]),
            snapshot: [],
            runningBundleIDs: ["com.apple.iCal"],
            offSpaceBundleIDs: [])
        #expect(result.isEmpty)
    }

    @Test("Reachable window is not flagged")
    func reachableNotFlagged() {
        let subject = rule(bundleID: "com.apple.iCal")
        let result = ActionCoordinator.unreachableRules(
            in: layout([subject]),
            snapshot: [handle(bundleID: "com.apple.iCal")],
            runningBundleIDs: ["com.apple.iCal"],
            offSpaceBundleIDs: ["com.apple.iCal"])
        #expect(result.isEmpty)
    }

    @Test("App not running is not flagged")
    func notRunningNotFlagged() {
        let subject = rule(bundleID: "com.apple.iCal")
        let result = ActionCoordinator.unreachableRules(
            in: layout([subject]),
            snapshot: [],
            runningBundleIDs: [],
            offSpaceBundleIDs: ["com.apple.iCal"])
        #expect(result.isEmpty)
    }

    @Test("Disabled or size-only rules are not flagged")
    func disabledAndSizeOnlyIgnored() {
        let disabled = rule(bundleID: "com.apple.iCal", isEnabled: false)
        let sizeOnly = rule(bundleID: "com.apple.Music", restoresPosition: false)
        let result = ActionCoordinator.unreachableRules(
            in: layout([disabled, sizeOnly]),
            snapshot: [],
            runningBundleIDs: ["com.apple.iCal", "com.apple.Music"],
            offSpaceBundleIDs: ["com.apple.iCal", "com.apple.Music"])
        #expect(result.isEmpty)
    }

    @Test("Two rules for the same app collapse to one entry")
    func dedupByBundle() {
        let ruleA = rule(bundleID: "com.apple.iCal", label: "Calendar A")
        let ruleB = rule(bundleID: "com.apple.iCal", label: "Calendar B")
        let result = ActionCoordinator.unreachableRules(
            in: layout([ruleA, ruleB]),
            snapshot: [],
            runningBundleIDs: ["com.apple.iCal"],
            offSpaceBundleIDs: ["com.apple.iCal"])
        #expect(result.count == 1)
        #expect(result.first?.ruleID == ruleA.id)
    }

    @Test("Detection is stable: identical inputs flag identically across passes")
    func stableAcrossPasses() {
        // The pre-fix bug flagged on pass 1 then vanished on pass 2 because the
        // signal was pruned. Detection now depends only on the current pass, so
        // a window still stranded stays flagged.
        let subject = rule(bundleID: "com.apple.iCal", label: "Calendar")
        let inputs = layout([subject])
        let pass1 = ActionCoordinator.unreachableRules(
            in: inputs, snapshot: [], runningBundleIDs: ["com.apple.iCal"],
            offSpaceBundleIDs: ["com.apple.iCal"])
        let pass2 = ActionCoordinator.unreachableRules(
            in: inputs, snapshot: [], runningBundleIDs: ["com.apple.iCal"],
            offSpaceBundleIDs: ["com.apple.iCal"])
        #expect(pass1.map(\.ruleID) == pass2.map(\.ruleID))
        #expect(pass1.count == 1)
    }
}

import CoreGraphics
import Foundation
@testable import PutAutomation
@testable import PutCore
import Testing

@Suite("LayoutTriggerEvaluator")
struct LayoutTriggerEvaluatorTests {
    private func display(uuid: UUID = UUID(), origin: CGPoint = .zero) -> DisplayFingerprint {
        // Vendor tuple deliberately nil so identity matching falls back to
        // UUID alone — these tests compare layouts via UUID, and a shared
        // vendor tuple would silently let any display match any other.
        DisplayFingerprint(
            uuid: uuid,
            vendorID: nil,
            productID: nil,
            serialNumber: nil,
            pointSize: CGSize(width: 1920, height: 1080),
            pixelSize: CGSize(width: 1920, height: 1080),
            scaleFactor: 1,
            globalOrigin: origin,
            isPrimary: false)
    }

    @Test
    func returnsNilWhenNoLayoutHasTrigger() {
        let layouts = [Layout(name: "A"), Layout(name: "B")]
        #expect(LayoutTriggerEvaluator.evaluate(layouts: layouts, currentDisplays: [display()]) == nil)
    }

    @Test
    func returnsFirstMatchingLayout() {
        let displayUUID = UUID()
        let target = display(uuid: displayUUID)
        let layoutA = Layout(name: "A", screenConfigs: [ScreenConfigTrigger(displays: [target])])
        let layoutB = Layout(
            name: "B",
            screenConfigs: [ScreenConfigTrigger(displays: [display(uuid: UUID())])])
        let result = LayoutTriggerEvaluator.evaluate(
            layouts: [layoutB, layoutA],
            currentDisplays: [target])
        #expect(result?.layoutID == layoutA.id)
        #expect(result?.autoActivate == true)
    }

    @Test
    func returnsNilWhenTriggerDoesNotMatch() {
        let layout = Layout(
            name: "Office",
            screenConfigs: [ScreenConfigTrigger(displays: [display(uuid: UUID())])])
        let unrelated = display(uuid: UUID())
        #expect(LayoutTriggerEvaluator.evaluate(layouts: [layout], currentDisplays: [unrelated]) == nil)
    }

    @Test
    func capturesAutoActivateFlag() {
        let target = display(uuid: UUID())
        let trigger = ScreenConfigTrigger(displays: [target], autoActivate: false)
        let layout = Layout(name: "Manual", screenConfigs: [trigger])
        let result = LayoutTriggerEvaluator.evaluate(
            layouts: [layout],
            currentDisplays: [target])
        #expect(result?.autoActivate == false)
    }

    @Test
    func matchesAnyOfALayoutsTriggers() {
        // A layout with several captured arrangements should fire on the
        // second one too, carrying that trigger's own autoActivate flag.
        let deskUUID = UUID()
        let dockUUID = UUID()
        let desk = display(uuid: deskUUID)
        let dock = display(uuid: dockUUID)
        let layout = Layout(
            name: "Work",
            screenConfigs: [
                ScreenConfigTrigger(displays: [desk]),
                ScreenConfigTrigger(displays: [dock], autoActivate: false)
            ])
        let result = LayoutTriggerEvaluator.evaluate(
            layouts: [layout],
            currentDisplays: [dock])
        #expect(result?.layoutID == layout.id)
        #expect(result?.autoActivate == false)
    }

    @Test
    func rearrangedDisplaysStillActivateAndReportMisalignment() {
        // macOS gives the built-in display a new offset on every replug. The
        // layout must still fire on identity; the flag only feeds a log line.
        let externalUUID = UUID()
        let builtInUUID = UUID()
        let captured = [
            display(uuid: externalUUID),
            display(uuid: builtInUUID, origin: CGPoint(x: -2056, y: 602))
        ]
        let live = [
            display(uuid: externalUUID),
            display(uuid: builtInUUID, origin: CGPoint(x: -2056, y: 513))
        ]
        let layout = Layout(name: "Home", screenConfigs: [ScreenConfigTrigger(displays: captured)])
        let result = LayoutTriggerEvaluator.evaluate(layouts: [layout], currentDisplays: live)
        #expect(result?.layoutID == layout.id)
        #expect(result?.autoActivate == true)
        #expect(result?.arrangementAligned == false)
    }
}

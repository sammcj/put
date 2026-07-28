import CoreGraphics
import Foundation
@testable import PutAutomation
import Testing

@Suite("Drift frame formatting")
struct DriftFrameFormatTests {
    @Test
    func formatsFourComponentsToOneDecimalPlace() {
        let rect = CGRect(x: 120.24, y: 80.46, width: 1440.03, height: 900.97)
        #expect(ActionCoordinator.formatDriftFrame(rect) == "120.2,80.5,1440.0,901.0")
    }

    @Test
    func formatIsCommaSeparatedAndParseableBackToTheOriginal() {
        let rect = CGRect(x: -12.0, y: 0.0, width: 640.0, height: 480.0)
        let formatted = ActionCoordinator.formatDriftFrame(rect)
        let components = formatted.split(separator: ",")
        #expect(components.count == 4)
        let values = components.compactMap { Double($0) }
        #expect(values == [-12.0, 0.0, 640.0, 480.0])
    }

    @Test
    func formatContainsNoWhitespaceSoItSurvivesTheSpaceDelimitedLogLine() {
        let formatted = ActionCoordinator.formatDriftFrame(CGRect(x: 1, y: 2, width: 3, height: 4))
        #expect(!formatted.contains(" "))
        #expect(formatted == "1.0,2.0,3.0,4.0")
    }
}

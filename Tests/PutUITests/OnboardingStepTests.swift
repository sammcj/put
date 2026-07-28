@testable import PutUI
import Testing

@MainActor
@Suite("OnboardingWizardController.Step progression")
struct OnboardingStepTests {
    typealias Step = OnboardingWizardController.Step

    @Test
    func welcomeAdvancesToAccessibilityRegardlessOfTrust() {
        #expect(Step.welcome.advance(accessibilityGranted: false) == .move(.accessibility))
        #expect(Step.welcome.advance(accessibilityGranted: true) == .move(.accessibility))
    }

    @Test
    func accessibilityWaitsUntilTrustIsGranted() {
        #expect(Step.accessibility.advance(accessibilityGranted: false) == .stay)
        #expect(Step.accessibility.advance(accessibilityGranted: true) == .move(.defaults))
    }

    @Test
    func defaultsFinishesTheWizard() {
        #expect(Step.defaults.advance(accessibilityGranted: true) == .finish)
    }

    @Test
    func backStepsThroughInReverse() {
        #expect(Step.welcome.back() == .welcome)
        #expect(Step.accessibility.back() == .welcome)
        #expect(Step.defaults.back() == .accessibility)
    }
}

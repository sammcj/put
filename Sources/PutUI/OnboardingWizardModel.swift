import Foundation
import Observation
import PutAutomation
import PutWindows

extension OnboardingWizardController.Step {
    /// Outcome of pressing the primary button on a step.
    enum Advance: Equatable {
        case move(OnboardingWizardController.Step)
        case stay
        case finish
    }

    /// Where "Continue"/"Done" leads. `accessibility` only advances once trust
    /// is granted; `defaults` finishes the wizard. Pure, so the progression is
    /// unit-tested directly.
    func advance(accessibilityGranted: Bool) -> Advance {
        switch self {
        case .welcome:
            .move(.accessibility)
        case .accessibility:
            accessibilityGranted ? .move(.defaults) : .stay
        case .defaults:
            .finish
        }
    }

    /// Where "Back" leads. The first step has nowhere to go, so it stays.
    func back() -> OnboardingWizardController.Step {
        switch self {
        case .welcome:
            .welcome
        case .accessibility:
            .welcome
        case .defaults:
            .accessibility
        }
    }
}

@MainActor
@Observable
final class OnboardingWizardViewModel {
    typealias Step = OnboardingWizardController.Step

    let reason: OnboardingReason
    private let state: AppState
    private let persister: ConfigPersister
    private let loginItem: LoginItemController

    var step: Step = .welcome
    var lastCheckedAt: Date?
    var launchAtLoginError: String?

    var onOpenSystemSettings: () -> Void = {}
    var onRecheckTrust: () -> Void = {}
    var onFinish: () -> Void = {}

    init(
        reason: OnboardingReason,
        state: AppState,
        persister: ConfigPersister,
        loginItem: LoginItemController)
    {
        self.reason = reason
        self.state = state
        self.persister = persister
        self.loginItem = loginItem
    }

    var accessibilityGranted: Bool {
        AccessibilityTrust.isTrusted
    }

    func advance() {
        switch step.advance(accessibilityGranted: accessibilityGranted) {
        case let .move(next):
            step = next
        case .stay:
            break
        case .finish:
            onFinish()
        }
    }

    func goBack() {
        step = step.back()
    }

    /// Called by the controller when the polling check transitions from
    /// waiting to granted. Briefly leaves the green tick visible before
    /// auto-advancing so the user sees confirmation.
    func handleAccessibilityGranted() {
        guard step == .accessibility else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            if step == .accessibility {
                step = .defaults
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = state.applyLaunchAtLogin(
            enabled,
            loginItem: loginItem,
            onChange: { [persister] in persister.scheduleWrite() })
    }
}

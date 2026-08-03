import AppKit
import CoreGraphics
import Foundation
@testable import PutAutomation
@testable import PutCore
@testable import PutDisplay
@testable import PutStorage
import PutTestSupport
@testable import PutWindows
import Testing

/// The `onAppLaunch` trigger and its retry backoff. Split out of
/// `AutoTriggerControllerTests` to keep both suites under the type-body cap.
@MainActor
@Suite("App launch trigger")
struct AppLaunchTriggerTests {
    @Test
    func appLaunchIgnoredWhenFlagOff() async throws {
        var config = Config.bootstrap()
        config.autoTriggers = AutoTriggerSettings(onDisplayChange: true, onAppLaunch: false, onWake: true)
        let probe = StubWindowProbe(handles: [makeWindowHandle(bundleID: "com.example.one")])
        let triggers = try controller(config: config, probe: probe)

        // Post a synthesised app-launch notification with the user-info shape
        // the real NSWorkspace notification uses.
        triggers.start()
        defer { triggers.stop() }

        let fakeApp = NSRunningApplication.current
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didLaunchApplicationNotification,
            object: NSWorkspace.shared,
            userInfo: [NSWorkspace.applicationUserInfoKey: fakeApp])
        // The handler spawns a detached Task that sleeps 500 ms; give it a
        // window to run. With the flag off we expect bundleCalls to stay at 0.
        try await Task.sleep(for: .milliseconds(750))
        #expect(probe.bundleCalls.isEmpty)
    }

    @Test
    func appLaunchRunsProbeWhenFlagOn() async throws {
        // This test confirms the probe wiring. NSRunningApplication.current
        // has a known bundleIdentifier that we can filter on.
        var config = Config.bootstrap()
        config.autoTriggers = AutoTriggerSettings(onDisplayChange: true, onAppLaunch: true, onWake: true)
        let probe = StubWindowProbe()
        let triggers = try controller(config: config, probe: probe)

        triggers.start()
        defer { triggers.stop() }

        guard let bundleID = NSRunningApplication.current.bundleIdentifier else {
            // Test host without a bundleIdentifier (ephemeral xctest). Skip
            // the probe assertion; the important part is the dispatch path
            // compiles and start/stop is stable.
            return
        }
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didLaunchApplicationNotification,
            object: NSWorkspace.shared,
            userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        try await Task.sleep(for: .milliseconds(750))
        #expect(probe.bundleCalls.contains(bundleID))
    }

    @Test
    func appLaunchRetriesUntilBudgetExhausted() async throws {
        // Regression guard for "Messages didn't move on launch": a one-shot
        // 500 ms probe is too short for cold-launched apps. The retry loop
        // re-probes on every backoff step until something applies or the
        // budget runs out.
        let bundleID = NSRunningApplication.current.bundleIdentifier ?? "com.example.test"
        let probe = StubWindowProbe()
        let triggers = try controller(
            config: launchConfig(rules: [rule(bundleID: bundleID)]),
            probe: probe,
            retries: 3)

        triggers.start()
        defer { triggers.stop() }

        triggers.onAppLaunched(bundleID: bundleID)
        try await Task.sleep(for: .milliseconds(200))
        #expect(probe.bundleCalls.count(where: { $0 == bundleID }) == 3)
    }

    /// The launch pre-check exists so an app with no rule doesn't burn a whole
    /// retry backoff on window probes that can only ever report no-match. A rule
    /// that is disabled, or opted out of automatic placement, is the same story:
    /// the loop must never start. Probing for the app's windows is the first
    /// thing an attempt does, which makes `bundleCalls` the proxy.
    @Test(arguments: [
        (autoPlace: false, isEnabled: true),
        (autoPlace: true, isEnabled: false)
    ])
    func appLaunchSchedulesNothingForARuleThatCannotApply(
        flags: (autoPlace: Bool, isEnabled: Bool)) async throws
    {
        let bundleID = "com.example.optedout"
        var optedOut = rule(bundleID: bundleID)
        optedOut.autoPlace = flags.autoPlace
        optedOut.isEnabled = flags.isEnabled

        let probe = StubWindowProbe()
        let triggers = try controller(
            config: launchConfig(rules: [optedOut]),
            probe: probe,
            retries: 3)

        triggers.start()
        defer { triggers.stop() }

        triggers.onAppLaunched(bundleID: bundleID)
        try await Task.sleep(for: .milliseconds(150))

        #expect(probe.bundleCalls.isEmpty)
    }

    @Test
    func appLaunchStillSchedulesForARuleThatCanApply() async throws {
        // Counterpart to the gating test above: a pre-check that rejected
        // everything outright would pass that one just as happily.
        let bundleID = "com.example.optedin"
        let probe = StubWindowProbe()
        let triggers = try controller(
            config: launchConfig(rules: [rule(bundleID: bundleID)]),
            probe: probe,
            retries: 3)

        triggers.start()
        defer { triggers.stop() }

        triggers.onAppLaunched(bundleID: bundleID)
        try await Task.sleep(for: .milliseconds(150))

        #expect(probe.bundleCalls.contains(bundleID))
    }

    @Test
    func appLaunchRetryCancelsOnRelaunch() async throws {
        // A second launch of the same bundleID before the first retry loop
        // finishes must cancel the in-flight task. Otherwise stacked tasks
        // would each fire a restore long after the user has moved the new
        // window.
        let bundleID = NSRunningApplication.current.bundleIdentifier ?? "com.example.test"
        let probe = StubWindowProbe()
        let triggers = try controller(
            config: launchConfig(rules: [rule(bundleID: bundleID)]),
            probe: probe,
            retries: 6,
            retryDelay: .milliseconds(50))

        triggers.start()
        defer { triggers.stop() }

        triggers.onAppLaunched(bundleID: bundleID)
        try await Task.sleep(for: .milliseconds(75))
        let countAfterFirstLaunch = probe.bundleCalls.count(where: { $0 == bundleID })

        triggers.onAppLaunched(bundleID: bundleID)
        try await Task.sleep(for: .milliseconds(400))
        let total = probe.bundleCalls.count(where: { $0 == bundleID })
        // Without cancellation, two stacked schedules of 6 attempts each
        // would compound to 12+. Cancellation caps the total near one full
        // schedule plus the partial first run.
        //
        // The upper bound carries slack because the split between "attempt
        // belongs to the cancelled schedule" and "cancellation has taken
        // effect" is not observable: a 50ms tick can land between sampling
        // countAfterFirstLaunch and the relaunch that cancels it, counting an
        // attempt this arithmetic attributes to neither run. One full schedule
        // plus two straddling attempts still separates cancelled (<= 8) from
        // uncancelled (12+), which is the whole point of the test. Tightening
        // this to +6 makes it fail roughly one run in six.
        #expect(total >= countAfterFirstLaunch + 4)
        #expect(total <= countAfterFirstLaunch + 8)
    }

    // MARK: - Fixtures

    private func controller(
        config: Config,
        probe: StubWindowProbe,
        retries: Int? = nil,
        retryDelay: Duration = .milliseconds(20)) throws -> AutoTriggerController
    {
        let state = AppState(config: config)
        let store = try makeTempStore(prefix: "put-launch").store
        let coordinator = ActionCoordinator(
            state: state,
            store: store,
            probe: probe,
            mutator: RecordingWindowMutator(),
            gate: StubAccessibilityGate(trusted: true))
        guard let retries else {
            return AutoTriggerController(
                state: state,
                coordinator: coordinator,
                probe: probe,
                debounceInterval: 0)
        }
        return AutoTriggerController(
            state: state,
            coordinator: coordinator,
            probe: probe,
            debounceInterval: 0,
            launchRetryDelays: Array(repeating: retryDelay, count: retries))
    }

    private func launchConfig(rules: [Rule]) -> Config {
        var config = Config.bootstrap()
        config.autoTriggers = AutoTriggerSettings(onDisplayChange: false, onAppLaunch: true, onWake: false)
        config.layouts = [PutCore.Layout(name: "Test", rules: rules)]
        config.activeLayoutID = config.layouts[0].id
        return config
    }

    private func rule(bundleID: String) -> Rule {
        Rule(
            descriptiveLabel: "test",
            matchCriteria: MatchCriteria(bundleID: bundleID, applyToAllWindows: true),
            targetDisplay: DisplayFingerprint(
                uuid: nil,
                vendorID: nil,
                productID: nil,
                serialNumber: nil,
                pointSize: CGSize(width: 1000, height: 800),
                pixelSize: CGSize(width: 1000, height: 800),
                scaleFactor: 1,
                globalOrigin: .zero,
                isPrimary: true,
                localizedName: "Stub"),
            frame: WindowFrame(
                absolute: CGRect(x: 0, y: 0, width: 100, height: 100),
                normalised: UnitRect(x: 0, y: 0, width: 0.1, height: 0.1)))
    }
}

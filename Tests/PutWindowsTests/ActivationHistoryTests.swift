import AppKit
import Foundation
@testable import PutWindows
import Testing

/// Hermetic tests for the activation history that resolves which app the user
/// was in before a Put window became frontmost. The notification plumbing is
/// isolated behind an injected `NotificationCenter` and extractor, so no test
/// touches the real `NSWorkspace`.
@MainActor
@Suite("ActivationHistory")
struct ActivationHistoryTests {
    private let putBundleID = "net.smcleod.put"

    private func makeHistory(
        center: NotificationCenter = NotificationCenter(),
        name: Notification.Name = .init("test.activate"),
        extract: @escaping ActivationHistory.Extractor = { _ in nil }) -> ActivationHistory
    {
        ActivationHistory(
            ownBundleID: putBundleID,
            center: center,
            notificationName: name,
            extract: extract)
    }

    @Test
    func emptyHistoryReportsNoTarget() {
        let history = makeHistory()
        #expect(history.previousActiveApp == nil)
    }

    @Test
    func recordsMostRecentNonPutActivation() {
        let history = makeHistory()
        history.record(.init(processID: 10, bundleID: "com.apple.Safari"))
        #expect(history.previousActiveApp?.bundleID == "com.apple.Safari")
        #expect(history.previousActiveApp?.processID == 10)

        history.record(.init(processID: 20, bundleID: "com.apple.finder"))
        #expect(history.previousActiveApp?.bundleID == "com.apple.finder")
        #expect(history.previousActiveApp?.processID == 20)
    }

    @Test
    func putFrontmostResolvesPriorAppNotPut() {
        // Reproduces the Rules tab "+" defect: Safari was active, then the user
        // opened Settings (Put activates). The prior app must stay resolved as
        // Safari, never Put.
        let history = makeHistory()
        history.record(.init(processID: 10, bundleID: "com.apple.Safari"))
        history.record(.init(processID: 99, bundleID: putBundleID))
        #expect(history.previousActiveApp?.bundleID == "com.apple.Safari")
    }

    @Test
    func ignoresPutOwnActivations() {
        let history = makeHistory()
        history.record(.init(processID: 99, bundleID: putBundleID))
        #expect(history.previousActiveApp == nil)
    }

    @Test
    func observesInjectedNotificationCenter() async {
        let center = NotificationCenter()
        let name = Notification.Name("test.activate")
        let history = makeHistory(center: center, name: name, extract: { note in
            guard let pid = note.userInfo?["pid"] as? Int,
                  let bundleID = note.userInfo?["bundle"] as? String
            else { return nil }
            return ActivationHistory.Activation(processID: pid_t(pid), bundleID: bundleID)
        })
        history.start()
        defer { history.stop() }

        center.post(name: name, object: nil, userInfo: ["pid": 321, "bundle": "com.apple.Safari"])
        await drainUntilRecorded(history)
        #expect(history.previousActiveApp?.bundleID == "com.apple.Safari")
        #expect(history.previousActiveApp?.processID == 321)

        // After stop() the observer is detached, so a later activation is ignored.
        history.stop()
        center.post(name: name, object: nil, userInfo: ["pid": 654, "bundle": "com.apple.finder"])
        await drainUntilRecorded(history)
        #expect(history.previousActiveApp?.bundleID == "com.apple.Safari")
    }

    /// Let the main-queue notification delivery and the actor hop run. Bounded
    /// so a wiring regression surfaces as a failed `#expect`, not a hang.
    private func drainUntilRecorded(_ history: ActivationHistory) async {
        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

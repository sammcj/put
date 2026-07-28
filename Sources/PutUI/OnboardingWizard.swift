import AppKit
import Foundation
import KeyboardShortcuts
import Observation
import PutAutomation
import PutCore
import PutHotkeys
import PutWindows
import SwiftUI

/// Why the wizard is being shown. Determines whether finishing stamps the
/// `Config.firstRunCompletedAt` field. The re-run path leaves it untouched
/// so the original first-run timestamp survives.
@MainActor
public enum OnboardingReason {
    case firstRun
    case userRequested
}

/// Multi-step welcome wizard: introduces Put, drives the Accessibility
/// permission grant, and surfaces the two opt-in defaults (launch at login,
/// restore-on-Put-launch). Toggles initialise from current state and only
/// write on user interaction, so re-running from Settings never clobbers
/// existing settings.
@MainActor
public final class OnboardingWizardController: NSObject, NSWindowDelegate {
    public enum Step: Int, CaseIterable, Sendable {
        case welcome
        case accessibility
        case defaults
    }

    /// Called when the user clicks Done on the final step.
    public var onCompleted: () -> Void = {}
    /// Called whenever the window is closed (Done or X). The owner uses this
    /// to clear its strong reference.
    public var onWindowClosed: () -> Void = {}

    private let viewModel: OnboardingWizardViewModel
    private let window: NSWindow
    private var pollTimer: DispatchSourceTimer?
    private var activationObserver: NSObjectProtocol?
    private weak var lifecycle: AppWindowLifecycle?
    private var didReportOpen = false

    public init(
        reason: OnboardingReason,
        startAt: Step = .welcome,
        state: AppState,
        persister: ConfigPersister,
        loginItem: LoginItemController,
        lifecycle: AppWindowLifecycle? = nil)
    {
        let viewModel = OnboardingWizardViewModel(
            reason: reason,
            state: state,
            persister: persister,
            loginItem: loginItem)
        viewModel.step = startAt
        self.viewModel = viewModel
        self.lifecycle = lifecycle
        let controller = NSHostingController(
            rootView: OnboardingWizardView(
                model: viewModel,
                state: state,
                persister: persister,
                loginItem: loginItem))
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable]
        window.title = reason == .firstRun ? "Welcome to Put" : "Put Setup"
        window.setContentSize(NSSize(width: 560, height: 480))
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        super.init()
        window.delegate = self
        viewModel.onOpenSystemSettings = {
            NSWorkspace.shared.open(AccessibilityTrust.systemSettingsURL)
        }
        viewModel.onRecheckTrust = { [weak self] in self?.runTrustCheck() }
        viewModel.onFinish = { [weak self] in self?.handleFinish() }
    }

    public func show() {
        if !didReportOpen {
            lifecycle?.didOpenUserFacingWindow()
            didReportOpen = true
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if !AccessibilityTrust.isTrusted {
            startPolling()
            subscribeToAppActivation()
        }
    }

    public func dismiss() {
        window.close()
    }

    public func windowWillClose(_ notification: Notification) {
        stopPolling()
        unsubscribeFromAppActivation()
        if didReportOpen {
            lifecycle?.didCloseUserFacingWindow()
            didReportOpen = false
        }
        onWindowClosed()
    }

    // MARK: - Trust handling

    private func handleFinish() {
        onCompleted()
        dismiss()
    }

    private func runTrustCheck() {
        if AccessibilityTrust.isTrusted {
            stopPolling()
            unsubscribeFromAppActivation()
            viewModel.handleAccessibilityGranted()
        } else {
            viewModel.lastCheckedAt = Date()
        }
    }

    /// `DispatchSourceTimer` is more robust than `Timer.scheduledTimer` when
    /// run loop modes change (sheet or picker interactions can swap modes)
    /// and avoids Swift 6 Timer closure isolation quirks.
    private func startPolling() {
        stopPolling()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.runTrustCheck()
        }
        timer.resume()
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    private func subscribeToAppActivation() {
        unsubscribeFromAppActivation()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main)
        { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier == ProcessInfo.processInfo.processIdentifier
            else { return }
            Task { @MainActor in self?.runTrustCheck() }
        }
    }

    private func unsubscribeFromAppActivation() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }
}

private struct OnboardingWizardView: View {
    @Bindable var model: OnboardingWizardViewModel
    @Bindable var state: AppState
    let persister: ConfigPersister
    @Bindable var loginItem: LoginItemController

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 560, height: 480)
    }

    private var content: some View {
        Group {
            switch model.step {
            case .welcome:
                OnboardingWelcomeView()
            case .accessibility:
                OnboardingAccessibilityStepView(model: model)
            case .defaults:
                OnboardingDefaultsView(
                    model: model,
                    state: state,
                    persister: persister,
                    loginItem: loginItem)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            stepBadge(.welcome, label: "Welcome")
            connector
            stepBadge(.accessibility, label: "Permission")
            connector
            stepBadge(.defaults, label: "Defaults")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func stepBadge(_ step: OnboardingWizardViewModel.Step, label: String) -> some View {
        let active = model.step == step
        let done = model.step.rawValue > step.rawValue
        return HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(done
                        ? Color.accentColor
                        : (active ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.15)))
                    .frame(width: 22, height: 22)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(step.rawValue + 1)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(active ? Color.accentColor : .secondary)
                }
            }
            Text(label)
                .font(.subheadline.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? .primary : .secondary)
        }
    }

    private var connector: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.2))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            if model.step != .welcome {
                Button("Back") { model.goBack() }
            }
            Spacer()
            primaryAction
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    @ViewBuilder private var primaryAction: some View {
        switch model.step {
        case .welcome:
            Button("Continue") { model.advance() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        case .accessibility:
            if model.accessibilityGranted {
                Button("Continue") { model.advance() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            } else {
                Button("Open System Settings") { model.onOpenSystemSettings() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        case .defaults:
            Button("Done") { model.onFinish() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
    }
}

private struct OnboardingWelcomeView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Put")
                        .font(.title2.weight(.semibold))
                    Text(
                        """
                        Put lives in your menu bar. It remembers and restores the screen, \
                        desktop, size and placement of windows when triggered by a hotkey or \
                        configurable events such as changing monitors.
                        """)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Worth knowing")
                    .font(.subheadline.weight(.semibold))
                glossaryRow(
                    "Rule",
                    "A saved window placement: which app, optional title pattern, target display, and frame.")
                glossaryRow(
                    "Layout",
                    "A named bundle of rules. Switch layouts to apply different placements (e.g. Coding, Meetings).")
                glossaryRow(
                    "Save / Restore",
                    "Save captures current windows into rules. Restore replays rules onto current windows.")
                glossaryRow(
                    "Auto-triggers",
                    "Optional automatic restores on display change, app launch, wake, or Put launch.")
            }
            Spacer(minLength: 0)
        }
        .padding(24)
    }

    private func glossaryRow(_ term: String, _ description: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(term)
                .font(.subheadline.weight(.semibold))
                .frame(width: 110, alignment: .leading)
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OnboardingAccessibilityStepView: View {
    @Bindable var model: OnboardingWizardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: model.accessibilityGranted ? "checkmark.seal.fill" : "lock.shield")
                    .font(.system(size: 40))
                    .foregroundStyle(model.accessibilityGranted ? Color.green : Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.accessibilityGranted ? "Accessibility granted" : "Put needs Accessibility")
                        .font(.title2.weight(.semibold))
                    Text(model.accessibilityGranted
                        ? "Put can now query and move windows."
                        : "macOS requires explicit consent to let Put query and move windows in other applications.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.accessibilityGranted {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        "Save and restore window placements across all running apps.",
                        systemImage: "rectangle.on.rectangle")
                    Label(
                        "Re-apply rules automatically when displays change or apps launch.",
                        systemImage: "display.2")
                }
                .labelStyle(.titleAndIcon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                Text(
                    "Manage or revoke this permission at any time under System Settings → Privacy & Security → Accessibility.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Label("Click Open System Settings below.", systemImage: "1.circle.fill")
                    Label("Find Put in the list. Add it with the + button if missing.", systemImage: "2.circle.fill")
                    Label("Toggle its switch on.", systemImage: "3.circle.fill")
                    Label("Return here; Put checks automatically.", systemImage: "4.circle.fill")
                }
                .labelStyle(.titleAndIcon)
                Text(
                    """
                    If the switch was already on, toggle off then on again. \
                    Development builds using ad-hoc signing can have their trust \
                    silently invalidated when the binary is rebuilt; if nothing \
                    else works, run `tccutil reset Accessibility net.smcleod.put` \
                    in Terminal and grant again.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if let checked = model.lastCheckedAt {
                        Text("Last checked \(checked, style: .time)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Re-check now") { model.onRecheckTrust() }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
    }
}

private struct OnboardingDefaultsView: View {
    @Bindable var model: OnboardingWizardViewModel
    @Bindable var state: AppState
    let persister: ConfigPersister
    @Bindable var loginItem: LoginItemController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Hotkeys & startup")
                .font(.title2.weight(.semibold))
            Text("Your current keyboard shortcuts. Edit any of them in Settings → Hotkeys.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                hotkeyRow("Save the focused window for this app", .saveFocusedWindowAllApp)
                hotkeyRow("Save the focused window (this title only)", .saveFocusedWindowTitleOnly)
                hotkeyRow("Save all windows across all apps", .saveAllWindows)
                hotkeyRow("Restore the active window", .restoreActiveWindow)
                hotkeyRow("Restore all windows", .restoreAllWindows)
            }
            Divider()
            Toggle("Launch Put at login", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { model.setLaunchAtLogin($0) }))
            if let err = model.launchAtLoginError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Toggle("Restore windows when Put launches", isOn: Binding(
                get: { state.config.autoTriggers.onPutLaunch },
                set: { newValue in
                    state.config.autoTriggers.onPutLaunch = newValue
                    persister.scheduleWrite()
                }))
            Spacer(minLength: 0)
        }
        .padding(24)
    }

    private func hotkeyRow(_ label: String, _ name: KeyboardShortcuts.Name) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.subheadline)
            Spacer()
            Text(KeyboardShortcuts.getShortcut(for: name).map(String.init(describing:)) ?? "—")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

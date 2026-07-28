import CoreGraphics
import Foundation
import PutCore
import PutTestSupport

/// Builds a `Rule` with sensible defaults so each test overrides only the
/// field under test. `targetDisplay` defaults to a shared fingerprint from
/// `PutTestSupport`.
func makeRule(
    id: UUID = UUID(),
    descriptiveLabel: String = "",
    bundleID: String = "com.example.app",
    titlePattern: String = "",
    titleMatchMode: TitleMatchMode = .literal,
    useTitlePatternExclusively: Bool = false,
    axRole: String? = nil,
    applyToAllWindows: Bool = false,
    isEnabled: Bool = true,
    restoresPosition: Bool = true,
    missingDisplayPolicy: MissingDisplayPolicy = .primaryProportional,
    targetDisplay: DisplayFingerprint = makeDisplayFingerprint(),
    absolute: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600),
    normalised: UnitRect = .full) -> Rule
{
    Rule(
        id: id,
        descriptiveLabel: descriptiveLabel,
        matchCriteria: MatchCriteria(
            bundleID: bundleID,
            titlePattern: titlePattern,
            titleMatchMode: titleMatchMode,
            useTitlePatternExclusively: useTitlePatternExclusively,
            axRole: axRole,
            applyToAllWindows: applyToAllWindows),
        targetDisplay: targetDisplay,
        frame: WindowFrame(absolute: absolute, normalised: normalised),
        missingDisplayPolicy: missingDisplayPolicy,
        isEnabled: isEnabled,
        restoresPosition: restoresPosition)
}

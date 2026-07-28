import PutAutomation
import PutDisplay
import SwiftUI

extension View {
    /// Runs `action` once per display reconfiguration for as long as the view
    /// is on screen. Owns a `DisplayChangeObserver` for the backing `.task`'s
    /// lifetime; teardown always calls `stop()` (via
    /// `forEachDisplayConfigurationChange`) so the CG callback can't leak.
    func onDisplayConfigurationChange(perform action: @escaping @MainActor () -> Void) -> some View {
        task {
            await forEachDisplayConfigurationChange(observer: DisplayChangeObserver(), perform: action)
        }
    }
}

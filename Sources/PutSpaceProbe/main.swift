import AppKit
import CoreGraphics
import Foundation

// Phase 0 probe for Space-fingerprint signals. On an interval it prints the
// per-screen desktop-picture URL and the set of apps owning on-screen windows.
// Run it, switch Spaces by hand, and watch which lines flip to CHANGED: that
// tells us whether the wallpaper URL tracks per-Space on this macOS build and
// how stable the on-screen app set is as a Space fingerprint. Ctrl-C to stop.
//
//   swift run PutSpaceProbe
//
// Neither signal needs Accessibility; owner-level CGWindowList info works
// without Screen Recording permission.

func wallpaperLines() -> [String] {
    NSScreen.screens.enumerated().map { index, screen in
        let url = NSWorkspace.shared.desktopImageURL(for: screen)
        // Last path component is enough to spot a per-Space wallpaper change
        // without dumping the full Library path each poll.
        let value = url?.lastPathComponent ?? "(none)"
        return "  screen[\(index)] \(screen.localizedName): \(value)"
    }
}

func onScreenApps() -> [String] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    // Layer 0 is the normal window layer. Higher layers are the Dock, menus,
    // status items and other chrome that span Spaces and would be noise in a
    // fingerprint.
    let owners = info.compactMap { entry -> String? in
        let layer = entry[kCGWindowLayer as String] as? Int ?? 0
        guard layer == 0 else { return nil }
        return entry[kCGWindowOwnerName as String] as? String
    }
    return Array(Set(owners)).sorted()
}

func snapshot() -> String {
    var lines = ["wallpaper:"]
    lines.append(contentsOf: wallpaperLines())
    let apps = onScreenApps()
    lines.append("on-screen apps (layer 0), \(apps.count) unique:")
    lines.append("  " + (apps.isEmpty ? "(none)" : apps.joined(separator: ", ")))
    return lines.joined(separator: "\n")
}

let clock = DateFormatter()
clock.dateFormat = "HH:mm:ss"

print("Put Space probe. Switch Spaces by hand and watch for CHANGED markers. Ctrl-C to stop.\n")

var previous = ""
while true {
    let current = snapshot()
    let marker = current == previous ? "(no change)" : "*** CHANGED ***"
    print("[\(clock.string(from: Date()))] \(marker)")
    print(current)
    print("")
    fflush(stdout)
    previous = current
    Thread.sleep(forTimeInterval: 2)
}

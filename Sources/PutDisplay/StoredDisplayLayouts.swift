import CoreGraphics
import Foundation
import PutCore

public enum StoredLayoutError: Error, Equatable {
    /// The undocumented prefs format isn't what Put understands.
    case unexpectedFormat
    /// macOS has no stored layout for exactly the connected displays.
    case noStoredLayoutForCurrentDisplays
    case mirroring
    /// macOS hasn't stored the display's live mode yet.
    case storedModeOutOfDate
}

/// Pure edits to the layouts WindowServer stores per set of connected
/// displays. A display that wakes before its neighbours uses the layout stored
/// for that smaller set, so a stale entry changes the resolution until the
/// remaining displays appear. Works on raw plist dictionaries because the
/// format is undocumented: a typed model would drop keys Put doesn't know.
enum StoredDisplayLayouts {
    typealias Plist = [String: Any]

    struct Update {
        var configs: [Plist]
        var changed = 0
    }

    /// A connected display as the edits need it, with `frame` in global space.
    struct LiveDisplay {
        let uuid: String
        let frame: CGRect
        let isPrimary: Bool

        init?(_ fingerprint: DisplayFingerprint) {
            guard let uuid = fingerprint.uuid else { return nil }
            self.uuid = uuid.uuidString
            frame = CGRect(origin: fingerprint.globalOrigin, size: fingerprint.pointSize)
            isPrimary = fingerprint.isPrimary
        }
    }

    /// Every `CurrentInfo` key describing the mode, leaving out the origin.
    /// Copying them from WindowServer's own entry avoids mapping `CGDisplayMode`
    /// onto fields such as `IsVRR`.
    private static let modeKeys = ["Wide", "High", "Hz", "Scale", "Depth", "IsVRR", "IsGenlock", "IsLink"]

    /// Point sizes in the plist are whole numbers, and live bounds should match.
    private static let sizeTolerance = 0.5

    /// Entries from the layout for exactly the connected displays, keyed by
    /// UUID. These are the source for every other layout, so this throws rather
    /// than spreading a size that doesn't match what's on screen.
    static func currentEntries(
        in configs: [Plist],
        displays: [LiveDisplay],
        pinning: Set<String>) throws -> [String: Plist]
    {
        try validate(configs)
        let connected = Set(displays.map(\.uuid))
        guard let current = configs.first(where: { displaySet(of: $0) == connected }) else {
            throw StoredLayoutError.noStoredLayoutForCurrentDisplays
        }
        guard !isMirrored(current) else { throw StoredLayoutError.mirroring }

        let entries = Dictionary(
            entries(of: current).compactMap { entry in uuid(of: entry).map { ($0, entry) } },
            uniquingKeysWith: { first, _ in first })
        for display in displays where pinning.contains(display.uuid) {
            guard let size = entries[display.uuid].flatMap(storedSize),
                  abs(size.width - display.frame.width) <= sizeTolerance,
                  abs(size.height - display.frame.height) <= sizeTolerance
            else { throw StoredLayoutError.storedModeOutOfDate }
        }
        return entries
    }

    /// Applies the pinned displays' modes to every combination of the connected
    /// displays that includes one of them, adding combinations macOS hasn't
    /// stored yet. Layouts involving any other display are left alone.
    static func updating(
        _ configs: [Plist],
        with current: [String: Plist],
        displays: [LiveDisplay],
        pinning: Set<String>) throws -> Update
    {
        try validate(configs)
        var update = Update(configs: configs)
        for combination in combinations(of: displays) {
            let members = Set(combination.map(\.uuid))
            guard !members.isDisjoint(with: pinning) else { continue }

            let index = update.configs.firstIndex { displaySet(of: $0) == members }
            let stored = index.map { update.configs[$0] }
            if let stored, isMirrored(stored) { continue }
            let base = stored ?? newConfig(for: combination, current: current)
            let rewritten = rewrite(base, displays: combination, current: current, pinning: pinning)
            if let index {
                guard !NSDictionary(dictionary: rewritten).isEqual(to: update.configs[index]) else { continue }
                update.configs[index] = rewritten
            } else {
                update.configs.append(rewritten)
            }
            update.changed += 1
        }
        return update
    }

    /// Start positions along one axis for displays whose lengths may differ
    /// from their live lengths. A display clear of everything before it butts
    /// against the new end, which closes the gap a missing display leaves. One
    /// overlapping on this axis (a neighbour on the other axis) keeps its offset.
    /// Each axis is packed alone, which is exact for a single row or column. A
    /// multi-row set can end up with a gap, or an overlap if an unpinned display
    /// has a stale stored size.
    static func packed(starts: [Double], liveLengths: [Double], lengths: [Double]) -> [Double] {
        var result = starts
        var liveEnd: Double?
        var newEnd = -Double.infinity
        var shift = 0.0
        for index in starts.indices.sorted(by: { starts[$0] < starts[$1] }) {
            let start: Double = if let liveEnd, starts[index] >= liveEnd {
                newEnd
            } else {
                starts[index] + shift
            }
            shift = start - starts[index]
            result[index] = start
            liveEnd = max(liveEnd ?? -.infinity, starts[index] + liveLengths[index])
            newEnd = max(newEnd, start + lengths[index])
        }
        return result
    }

    // MARK: - Private

    private static func validate(_ configs: [Plist]) throws {
        for config in configs {
            guard let entries = config["DisplayConfig"] as? [Plist], !entries.isEmpty else {
                throw StoredLayoutError.unexpectedFormat
            }
            for entry in entries where uuid(of: entry) == nil || entry["CurrentInfo"] as? Plist == nil {
                throw StoredLayoutError.unexpectedFormat
            }
        }
    }

    private static func entries(of config: Plist) -> [Plist] {
        config["DisplayConfig"] as? [Plist] ?? []
    }

    private static func uuid(of entry: Plist) -> String? {
        (entry["UUID"] as? String)?.uppercased()
    }

    private static func displaySet(of config: Plist) -> Set<String> {
        Set(entries(of: config).compactMap(uuid))
    }

    private static func number(_ key: String, in info: Plist?) -> Double? {
        (info?[key] as? NSNumber)?.doubleValue
    }

    private static func storedSize(of entry: Plist) -> CGSize? {
        let info = entry["CurrentInfo"] as? Plist
        guard let width = number("Wide", in: info), let height = number("High", in: info) else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Mirrored layouts carry a `MasterUUID`. Their geometry follows other
    /// rules, so they're never edited. A 1x1 `UnmirrorInfo` proves nothing: it's
    /// a placeholder that ordinary extended layouts have too.
    private static func isMirrored(_ config: Plist) -> Bool {
        entries(of: config).contains { $0["MasterUUID"] != nil }
    }

    private static func combinations(of displays: [LiveDisplay]) -> [[LiveDisplay]] {
        (1..<(1 << displays.count)).map { mask in
            displays.indices.filter { mask & (1 << $0) != 0 }.map { displays[$0] }
        }
    }

    private static func newConfig(for displays: [LiveDisplay], current: [String: Plist]) -> Plist {
        ["ConfigVersion": 1, "DisplayConfig": displays.compactMap { current[$0.uuid] }]
    }

    private static func rewrite(
        _ config: Plist,
        displays: [LiveDisplay],
        current: [String: Plist],
        pinning: Set<String>) -> Plist
    {
        var entries = entries(of: config).map { entry in
            guard let id = uuid(of: entry), pinning.contains(id), let source = current[id] else { return entry }
            return copyingMode(from: source, to: entry)
        }

        let origins = origins(for: displays, entries: entries)
        for index in entries.indices {
            guard let id = uuid(of: entries[index]), let origin = origins[id],
                  var info = entries[index]["CurrentInfo"] as? Plist
            else { continue }
            info["OriginX"] = Double(origin.x)
            info["OriginY"] = Double(origin.y)
            entries[index]["CurrentInfo"] = info
        }

        var rewritten = config
        rewritten["DisplayConfig"] = entries
        return rewritten
    }

    private static func copyingMode(from source: Plist, to entry: Plist) -> Plist {
        guard let mode = source["CurrentInfo"] as? Plist else { return entry }
        var updated = entry
        for key in ["CurrentInfo", "UnmirrorInfo"] {
            guard var info = entry[key] as? Plist else { continue }
            for modeKey in modeKeys {
                info[modeKey] = mode[modeKey] ?? info[modeKey]
            }
            updated[key] = info
        }
        return updated
    }

    /// Keeps the live arrangement with gaps closed, relative to the display
    /// that holds the menu bar, which macOS always puts at (0, 0).
    private static func origins(for displays: [LiveDisplay], entries: [Plist]) -> [String: CGPoint] {
        let sizes = displays.map { display in
            entries.first { uuid(of: $0) == display.uuid }.flatMap(storedSize) ?? display.frame.size
        }
        let xs = packed(
            starts: displays.map { Double($0.frame.minX) },
            liveLengths: displays.map { Double($0.frame.width) },
            lengths: sizes.map { Double($0.width) })
        let ys = packed(
            starts: displays.map { Double($0.frame.minY) },
            liveLengths: displays.map { Double($0.frame.height) },
            lengths: sizes.map { Double($0.height) })

        let main = mainIndex(in: displays, entries: entries)
        return Dictionary(
            displays.indices.map { index in
                (displays[index].uuid, CGPoint(x: xs[index] - xs[main], y: ys[index] - ys[main]))
            },
            uniquingKeysWith: { first, _ in first })
    }

    /// The live primary when it's in the set, then whichever display the layout
    /// already stores at the origin, then the display closest to the primary.
    private static func mainIndex(in displays: [LiveDisplay], entries: [Plist]) -> Int {
        if let primary = displays.firstIndex(where: \.isPrimary) { return primary }
        let storedMain = entries.first { entry in
            let info = entry["CurrentInfo"] as? Plist
            return number("OriginX", in: info) == 0 && number("OriginY", in: info) == 0
        }
        if let id = storedMain.flatMap(uuid), let index = displays.firstIndex(where: { $0.uuid == id }) {
            return index
        }
        // Live coordinates put the primary at the origin, so distance from
        // (0, 0) is distance from the primary.
        return displays.indices.min { lhs, rhs in
            hypot(displays[lhs].frame.midX, displays[lhs].frame.midY)
                < hypot(displays[rhs].frame.midX, displays[rhs].frame.midY)
        } ?? 0
    }
}

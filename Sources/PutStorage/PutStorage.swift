import Foundation
import PutCore

public enum PutStorage {
    /// Default on-disk location: `~/Library/Application Support/Put/config.json`.
    public static var defaultConfigURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("Put", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
    }
}

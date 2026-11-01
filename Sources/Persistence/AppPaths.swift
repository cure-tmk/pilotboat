import Foundation

public enum AppPaths {
    public static let bundleID = "io.github.cure-tmk.pilotboat"

    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
    }
    public static var configURL: URL { supportDirectory.appendingPathComponent("config.json") }
    public static var stateURL: URL { supportDirectory.appendingPathComponent("state.sqlite") }
}

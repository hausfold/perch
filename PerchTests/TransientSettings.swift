import Foundation

@testable import Perch

/// A settings store on a throwaway path, for the tests that need an
/// `AppSettings` and don't care what is in it.
///
/// The point is what it avoids. `AppSettings()` and `AppSettings(defaults:)`
/// both fall back to `ConfigFileStore.shared`, which reads the *real*
/// `…/Application Support/Perch/settings.json` and the *real*
/// `~/.config/perch/config.json` of whichever Mac is running the suite — so a
/// shelf test would quietly pass or fail on somebody's desktop, and an
/// `xcodebuild test` would arm file watchers on the live install's settings.
/// That is the same reason `ScreenshotsFolder` has no defaulted `riceValue`
/// overload.
///
/// Nothing is created on disk and there is nothing to clean up: a store only
/// writes when something asks it to, these never do, and a watcher over a file
/// that isn't there (in a directory that isn't there either) arms nothing.
enum TransientSettings {
    static func store() -> ConfigFileStore {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "PerchSettings-\(UUID().uuidString)", directoryHint: .isDirectory)
        return ConfigFileStore(file: root.appending(path: "settings.json"), declaration: nil)
    }
}

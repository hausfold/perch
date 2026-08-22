import Foundation

/// Where this Mac saves screenshots — as well as a sandboxed app can know it.
///
/// macOS keeps the real answer in `com.apple.screencapture`'s `location` key,
/// and perch cannot read it: the sandbox only hands an app its own defaults
/// (plus `NSGlobalDomain`), and reading another domain would cost a
/// `temporary-exception.shared-preference.read-only` entitlement — a wider
/// hole than this feature is worth, for a value that is the Desktop on the
/// overwhelming majority of Macs.
///
/// So the answer comes from two places, in order:
///
/// 1. `screenshotsFolder` in the rice config drop (`~/.config/perch/config.json`,
///    the same file the theme keys arrive in). haus writes it from
///    `haus.screenshots.location`, which is where a haus machine's screenshots
///    go BECAUSE haus put them there — no guessing on either side. It is
///    absent when haus does not own that setting, precisely so nobody has to
///    guess in the first place.
/// 2. `~/Desktop`, which is macOS's own default.
///
/// Neither is a permission. Everything this answers is "which folder should
/// the picker open at" — the grant still comes from the panel the person
/// clicks, and a wrong guess here costs one navigation, never access.
enum ScreenshotsFolder {
    /// The rice's half of the answer, decoded on its own rather than folded
    /// into `RiceThemeDefaults`: that struct is the theme contract, and this
    /// key is a machine fact that has nothing to do with colour.
    private struct RiceScreenshots: Decodable {
        let screenshotsFolder: String?
    }

    static func riceValue(from url: URL = RiceFiles.configFile) -> String? {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(RiceScreenshots.self, from: data)
        else {
            return nil
        }
        return decoded.screenshotsFolder
    }

    /// The folder to open the picker at. `home` is injectable so the tests
    /// never depend on the machine they run on.
    static func resolve(riceValue: String? = nil, home: URL = RiceFiles.home) -> URL {
        let value = riceValue ?? Self.riceValue()
        guard let value, !value.isEmpty else {
            return home.appendingPathComponent("Desktop", isDirectory: true)
        }
        return expand(value, home: home)
    }

    /// haus writes an absolute path (it expands `~/` before the plist write),
    /// but a standalone install may write this file by hand, and `~/Pictures`
    /// is what a person types.
    private static func expand(_ path: String, home: URL) -> URL {
        if path == "~" {
            return home
        }
        if path.hasPrefix("~/") {
            return home.appendingPathComponent(String(path.dropFirst(2)), isDirectory: true)
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        // Not absolute and not home-relative: treat it as home-relative rather
        // than as relative to whatever directory perch happens to be running
        // in, which is never what a config file means.
        return home.appendingPathComponent(path, isDirectory: true)
    }
}

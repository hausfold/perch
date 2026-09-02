import Foundation

/// Where this Mac saves screenshots.
///
/// macOS keeps the real answer in `com.apple.screencapture`'s `location` key,
/// and perch reads it — the same handle `MissionControlCheck` uses on the
/// Dock's domain, and pinned in `Perch.entitlements` the same way: one domain,
/// read-only, no filesystem widening, nothing written back. An absent key is
/// macOS's own default, the Desktop.
///
/// This file used to guess instead, and the guess was load-bearing in a way it
/// should never have been: Settings decided a watched folder was "the
/// screenshots one" by comparing it against whatever this answered, so a wrong
/// guess silently attached the screenshots row to a folder someone had added
/// for another reason. Nothing compares against it now — the suggestion in
/// Settings ▸ Watched Folders only ever offers a folder to add — but being right is
/// still what makes that suggestion worth showing at all.
///
/// So the answer comes from three places, in order:
///
/// 1. `com.apple.screencapture`'s `location`: what macOS itself uses. Absent on
///    a stock Mac, and absent is not silence — it means the Desktop.
/// 2. `screenshotsFolder` in the haus config drop (`~/.config/perch/config.json`,
///    the same file the theme keys arrive in). haus writes it from
///    `haus.screenshots.location` when `haus.shelf.watchScreenshots` is on. It
///    is a fallback rather than the answer because macOS's own key is the thing
///    haus is *setting* — if the two ever disagree, someone changed it after
///    haus did, and they win.
/// 3. `~/Desktop`, which is macOS's default.
///
/// None of this is a permission. Everything it answers is "which folder should
/// the picker open at" — the grant still comes from the panel the person
/// clicks, and a wrong answer costs one navigation, never access.
enum ScreenshotsFolder {
    /// macOS's own domain and key. The value is a POSIX path; the key is simply
    /// absent until someone changes the location, which is the common case.
    nonisolated static let captureDomain = "com.apple.screencapture"
    nonisolated static let captureKey = "location"

    /// haus's half of the answer, decoded on its own rather than folded
    /// into `RiceThemeDefaults`: that struct is the theme contract, and this
    /// key is a machine fact that has nothing to do with colour.
    private struct RiceScreenshots: Decodable {
        let screenshotsFolder: String?
    }

    /// What macOS says. `CFPreferencesAppSynchronize` first for the same reason
    /// `MissionControlCheck` does it: without it this process keeps the value it
    /// cached at first read, and a location changed in the Screenshot app would
    /// not land until relaunch.
    ///
    /// Nil covers both "never set" and "the read was denied", which are
    /// indistinguishable — and both land on the Desktop by way of the fallbacks,
    /// which is the right answer for the first and the old behaviour for the
    /// second.
    static func systemValue() -> String? {
        CFPreferencesAppSynchronize(captureDomain as CFString)
        let value = CFPreferencesCopyAppValue(captureKey as CFString, captureDomain as CFString)
        return value as? String
    }

    static func riceValue(from url: URL = RiceFiles.configFile) -> String? {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(RiceScreenshots.self, from: data)
        else {
            return nil
        }
        return decoded.screenshotsFolder
    }

    /// The folder to open the picker at, reading the drop. `systemValue`
    /// defaults to the real one and is a parameter so a test can hand in
    /// nothing and still exercise the drop's path through here — on a Mac that
    /// sets a screenshot location, which outranks the drop, there is otherwise
    /// no way to reach it. The pure overload below takes both and defaults
    /// neither, so no test's answer can depend on the machine running it.
    static func resolve(
        configURL: URL = RiceFiles.configFile,
        home: URL = RiceFiles.home,
        systemValue: String? = systemValue()
    ) -> URL {
        resolve(systemValue: systemValue, riceValue: riceValue(from: configURL), home: home)
    }

    /// The same decision with the reading already done — pure, and the one
    /// the tests pin.
    static func resolve(systemValue: String?, riceValue: String?, home: URL) -> URL {
        for candidate in [systemValue, riceValue] {
            guard let candidate, !candidate.isEmpty else { continue }
            return expand(candidate, home: home)
        }
        return home.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// macOS writes an absolute path and so does haus (it expands `~/` before
    /// the plist write), but both of these keys get set by hand — `defaults
    /// write`, a text editor — and `~/Pictures` is what a person types.
    private static func expand(_ path: String, home: URL) -> URL {
        // Some scripts set `location` to a file URL. Taking one as a path would
        // make a folder literally named "file:" under the home.
        //
        // Unwrapped by hand rather than through `URL(string:)`: a value with an
        // unencoded space is not a legal URL, the parse fails, and the fall
        // through to the home-relative branch below produces exactly the
        // `<home>/file:/Users/…` this is here to prevent.
        if path.hasPrefix("file://") {
            let body = String(path.dropFirst("file://".count))
            let decoded = body.removingPercentEncoding ?? body
            // `file://localhost/…` names the only host a file URL can name.
            let posix = decoded.hasPrefix("/") ? decoded[...] : decoded.drop(while: { $0 != "/" })
            if posix.hasPrefix("/") {
                return URL(fileURLWithPath: String(posix), isDirectory: true)
            }
        }
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

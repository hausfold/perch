import AppKit
import Foundation
import SwiftUI

/// The colors the shelf paints with — one nebelung variant, or any palette
/// dropped in `~/.config/perch/themes/`.
///
/// **Why this exists.** The shelf used to be white-on-black with one sage
/// literal, so `nebelhaus.theme.flavor` was a lie for perch: a latte rice still
/// got a black glass panel. The four nebelung variants are now compiled in (a
/// perch installed without the rice still has them all) and the rice names the
/// dark/light pair in `~/.config/perch/config.json`. Same model as trill
/// (`Trill/DesignSystem/RicePalette.swift`) and pounce (`Theme.swift`).
///
/// Only the seven roles the shelf actually paints with are carried. A nebelung
/// `*.hex.json` file has all twenty-three; the rest are ignored, which is what
/// lets the rice write those files here verbatim.
struct RicePalette: Equatable {
    let name: String

    /// Panel fill (`base`), the wash under the remove badge (`crust`), the
    /// dashed drop outline at rest (`overlay0`), labels (`text`, `subtext0`),
    /// the ember (`green`), and the destructive accents (`red`).
    let crust, base, overlay0, text, subtext0, green, red: Color

    /// Is this a LIGHT palette? Relative luminance of `base`, the panel fill.
    /// Precomputed rather than derived per read: polarity decides
    /// `preferredColorScheme`, the tint alpha, and every shadow, all of which
    /// are read inside view bodies.
    let isLight: Bool

    /// The roles a palette file must carry. A subset of the catppuccin names
    /// nebelung uses, so its variant files parse here unchanged.
    static let roles = ["crust", "base", "overlay0", "text", "subtext0", "green", "red"]

    /// Build a palette from a flat `role → hex` map — the shape of both the
    /// compiled-in tables below and nebelung's `*.hex.json` files. Fails (so the
    /// caller can fall back) if any role is missing or unparseable, which is
    /// also what makes a truncated or hand-mangled theme file harmless.
    init?(name: String, hex map: [String: String]) {
        var rgb: [String: (Double, Double, Double)] = [:]
        for role in Self.roles {
            guard let raw = map[role], let components = Self.components(raw) else { return nil }
            rgb[role] = components
        }
        func color(_ role: String) -> Color {
            let (r, g, b) = rgb[role]!
            return Color(.sRGB, red: r, green: g, blue: b)
        }

        self.name = name
        crust = color("crust")
        base = color("base")
        overlay0 = color("overlay0")
        text = color("text")
        subtext0 = color("subtext0")
        green = color("green")
        red = color("red")

        let (r, g, b) = rgb["base"]!
        isLight = 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.5
    }

    /// `"#d7d7d7"` / `"d7d7d7"` → components. Anything else is a malformed file.
    private static func components(_ raw: String) -> (Double, Double, Double)? {
        let digits = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }

    // MARK: - Painting helpers

    /// Label color for text sitting on a filled `green`/`red` — the accents are
    /// pastel on a dark palette and saturated on a light one, so the contrast
    /// color flips with the polarity, not with the accent.
    var onAccent: Color { isLight ? base : crust }

    /// A drop shadow that works in both polarities. `alpha` is the dark-palette
    /// value; on a light palette the same black at the same weight reads as
    /// dirt, so it is pulled back to a third — light UI separates by hairline
    /// and fill, not by depth.
    func shadow(_ alpha: Double) -> Color {
        .black.opacity(isLight ? alpha * 0.35 : alpha)
    }

    /// A translucent wash of the label color: hover fills, hairlines, the
    /// placeholder tile. Keyed to `text` rather than to a fixed white so it
    /// stays a *contrasting* wash on a latte panel instead of vanishing.
    func wash(_ alpha: Double) -> Color {
        text.opacity(alpha)
    }

    /// How opaque the panel tint sits over the glass. A light palette needs more
    /// body than a dark one to read as a surface rather than as haze.
    var panelTintOpacity: Double { isLight ? 0.58 : 0.42 }

    // MARK: - Resolution

    static let defaultDarkName = "nebelung"
    static let defaultLightName = "nebelung-latte"

    /// Resolve a theme name to a palette. A **user file shadows a built-in of
    /// the same name**: `~/.config/perch/themes/nebelung.json` (what the rice
    /// installs) wins over the tables below, so a nebelung palette bump reaches
    /// a perch that hasn't been rebuilt. Built-ins are the floor, not the
    /// ceiling. An unknown name or malformed file falls back to nebelung.
    static func named(_ name: String, themesDirectory: URL = RiceFiles.themesDirectory) -> RicePalette {
        if let file = loaded(name, in: themesDirectory) { return file }
        switch name {
        case "nebelung-high-contrast": return .nebelungHighContrast
        case defaultLightName: return .nebelungLatte
        case "nebelung-latte-high-contrast": return .nebelungLatteHighContrast
        default: return .nebelung
        }
    }

    /// A runtime palette: `<themes>/<name>.json`, a flat catppuccin-style
    /// `role → "#hex"` map — i.e. nebelung's `*.hex.json` files verbatim, so any
    /// nebelung variant or stock Catppuccin flavor drops in without a rebuild.
    /// Read when the theme is resolved (launch, appearance flip, shelf open),
    /// never per frame.
    static func loaded(_ name: String, in directory: URL) -> RicePalette? {
        // Refuse anything that could walk out of the themes directory; the name
        // arrives from a config file, not from a file picker.
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/") else { return nil }
        let url = directory.appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return RicePalette(name: name, hex: map)
    }
}

// MARK: - Compiled-in nebelung variants

// Hand-copied from `nebelung/palette/<variant>.hex.json` (perch builds outside
// Nix, so it cannot consume nebelung's generated palette output). Keep the
// values verbatim so a diff against nebelung stays a one-glance check.
extension RicePalette {
    static let nebelung = RicePalette(name: "nebelung", hex: [
        "text": "d7d7d7",
        "subtext0": "aeaeae",
        "overlay0": "717171",
        "base": "202020",
        "crust": "121212",
        "red": "ed8fa9",
        "green": "abe1a6",
    ])!

    static let nebelungHighContrast = RicePalette(name: "nebelung-high-contrast", hex: [
        "text": "ffffff",
        "subtext0": "c6c6c6",
        "overlay0": "737373",
        "base": "090909",
        "crust": "010101",
        "red": "ed8fa9",
        "green": "abe1a6",
    ])!

    static let nebelungLatte = RicePalette(name: "nebelung-latte", hex: [
        "text": "515151",
        "subtext0": "717171",
        "overlay0": "a1a1a1",
        "base": "f1f1f1",
        "crust": "e0e0e0",
        "red": "ca2a40",
        "green": "4a9e3a",
    ])!

    static let nebelungLatteHighContrast = RicePalette(name: "nebelung-latte-high-contrast", hex: [
        "text": "434343",
        "subtext0": "686868",
        "overlay0": "a1a1a1",
        "base": "ffffff",
        "crust": "eeeeee",
        "red": "ca2a40",
        "green": "4a9e3a",
    ])!
}

// MARK: - Where the rice writes

/// The rice-owned theme files. `~/.config/perch/` is outside the app sandbox
/// container, which costs perch one `temporary-exception.files
/// .home-relative-path.read-only` entitlement (see `Config/Perch.entitlements`)
/// — read-only, one directory, and the only path perch reaches for that a file
/// picker didn't hand it.
enum RiceFiles {
    /// The **real** home directory. Inside the sandbox `NSHomeDirectory()` and
    /// `homeDirectoryForCurrentUser` both answer with the container, so the
    /// passwd entry is the only way to name `~/.config`.
    static var home: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var directory: URL {
        home.appendingPathComponent(".config/perch", isDirectory: true)
    }

    static var themesDirectory: URL {
        directory.appendingPathComponent("themes", isDirectory: true)
    }

    static var configFile: URL {
        directory.appendingPathComponent("config.json")
    }
}

/// Machine-managed theme defaults from `~/.config/perch/config.json`:
///
/// ```json
/// { "themeDark": "nebelung-high-contrast",
///   "themeLight": "nebelung-latte-high-contrast" }
/// ```
///
/// The rice writes this (nebelhaus `modules/perch`) so `nebelhaus.theme.flavor`
/// and `.contrast` reach perch declaratively. Perch's own settings live in
/// `UserDefaults`, which Nix has no business writing — this file carries only
/// what the rice owns. Delete it (or the rice's `theme` option) and the
/// compiled-in nebelung pair applies.
struct RiceThemeDefaults: Decodable, Equatable {
    let themeDark: String?
    let themeLight: String?

    static func load(from url: URL = RiceFiles.configFile) -> RiceThemeDefaults? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RiceThemeDefaults.self, from: data)
    }
}

/// Turns the two inputs perch has — the macOS appearance and whatever the rice
/// wrote — into one palette. Precedence: **config.json › compiled-in nebelung**,
/// with the system appearance choosing which half of the pair applies.
///
/// There is deliberately no in-app theme picker: the shelf is a five-second
/// surface with no room for one, and "follow the rice" is the whole feature.
enum RiceTheme {
    /// Is macOS itself in Light Mode? `NSApp.appearance` is nil unless something
    /// forced an app-wide appearance, so while it is nil `effectiveAppearance`
    /// is the system setting. The `UserDefaults` read is the launch path, before
    /// there is an `NSApplication` at all.
    @MainActor
    static var systemIsLight: Bool {
        if let app = NSApp, app.appearance == nil {
            return app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != .darkAqua
        }
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") != "Dark"
    }

    /// Posted by macOS when the light/dark switch flips.
    static let systemAppearanceChanged = Notification.Name("AppleInterfaceThemeChangedNotification")

    static func name(
        systemIsLight: Bool,
        defaults: RiceThemeDefaults?
    ) -> String {
        if let managed = systemIsLight ? defaults?.themeLight : defaults?.themeDark, !managed.isEmpty {
            return managed
        }
        return systemIsLight ? RicePalette.defaultLightName : RicePalette.defaultDarkName
    }

    static func palette(
        systemIsLight: Bool,
        defaults: RiceThemeDefaults?,
        themesDirectory: URL = RiceFiles.themesDirectory
    ) -> RicePalette {
        RicePalette.named(
            name(systemIsLight: systemIsLight, defaults: defaults),
            themesDirectory: themesDirectory
        )
    }
}

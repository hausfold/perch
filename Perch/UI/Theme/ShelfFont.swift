import AppKit
import SwiftUI

/// The family perch sets its text in — the typographic half of what
/// `~/.config/perch/config.json` carries, beside the two palette names and the
/// accent.
///
/// **The desktop names it and there is no picker**, exactly as there is none
/// for the accent: the shelf is a five-second surface, and "follow haus" is the
/// feature. A standalone install writes `"fontFamily"` into that file by hand.
/// Absent — the default — every call here resolves to SwiftUI's `.system(…)`
/// and perch draws exactly as it always has.
///
/// Three things it deliberately does not cover.
///
/// **A symbol is not text.** `Image(systemName:)` is sized with `.font(…)` all
/// over the shelf, and an SF Symbol handed a text face is scaled by that face's
/// metrics rather than Apple's — a pin that grows when you change your reading
/// font. Those call sites keep `.system`; this type is for `Text`.
///
/// **Monospaced runs stay monospaced.** The pairing code and the encoded offer
/// are `.monospaced()` because six digits read across two screens have to line
/// up, which is a different job from reading a sentence.
///
/// **A family that isn't installed falls back silently**, because that is what
/// CoreText does with a name it can't resolve, and perch installs no fonts.
enum ShelfFont {
    /// The family in force, or nil for the system font.
    ///
    /// Written by `ShelfTheme` and by nothing else: resolution touches a file,
    /// so it happens on the events that can change it — launch, the appearance
    /// flip, opening the shelf — never inside a view body. Read here rather
    /// than through the environment because the alternative is an
    /// `@Environment` property on all fifteen view structs that set a font.
    @MainActor private(set) static var family: String?

    @MainActor
    static func adopt(_ configured: String?) {
        family = resolve(configured)
    }

    /// Pure, so what counts as "the system font" is a test rather than a
    /// render: absent, empty, blank, and the names macOS's own UI family
    /// answers to.
    ///
    /// That last case is the one that matters. A desktop generating this file
    /// writes the family it was told to use, and the usual default is macOS's
    /// own — `Font.custom(".AppleSystemUIFont", …)` *works*, and freezes the
    /// weight and optical size SwiftUI picks per text style, so "I left it at
    /// the default" would render subtly unlike leaving the key out.
    static func resolve(_ configured: String?) -> String? {
        guard let trimmed = configured?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !systemNames.contains(trimmed.lowercased())
        else { return nil }
        return trimmed
    }

    private static let systemNames: Set<String> = [
        ".applesystemuifont",
        "applesystemuifont",
        ".sf ns",
        "system",
        "system font",
        "-apple-system",
    ]

    // MARK: - Text styles

    /// One of SwiftUI's semantic styles, in perch's family. The point size is
    /// macOS's own for that style rather than a table written down here — a
    /// table would be right until Apple moved one — and `relativeTo:` keeps a
    /// custom face scaling the way `.system(_:)` does.
    @MainActor
    static func style(_ textStyle: Font.TextStyle) -> Font {
        style(textStyle, family: family)
    }

    /// The same decision with the family handed in, so a test can prove the one
    /// claim that matters most: with nobody's family named, every call is *the
    /// same `Font`* perch drew before this key existed.
    static func style(_ textStyle: Font.TextStyle, family: String?) -> Font {
        guard let family else { return .system(textStyle) }
        return .custom(family, size: pointSize(of: textStyle), relativeTo: textStyle)
            .weight(weight(of: textStyle))
    }

    /// A fixed point size, the analogue of `.system(size:weight:)`.
    ///
    /// The weight is optional rather than defaulted to `.regular` because
    /// SwiftUI's own is: `.system(size: 11)` and `.system(size: 11, weight:
    /// .regular)` are two different `Font`s, and only one of them is what the
    /// call site being replaced here asked for.
    @MainActor
    static func size(_ points: CGFloat, weight: Font.Weight? = nil) -> Font {
        size(points, weight: weight, family: family)
    }

    static func size(_ points: CGFloat, weight: Font.Weight? = nil, family: String?) -> Font {
        guard let family else { return .system(size: points, weight: weight) }
        let sized = Font.custom(family, fixedSize: points)
        return weight.map(sized.weight) ?? sized
    }

    @MainActor static var caption2: Font { style(.caption2) }
    @MainActor static var caption: Font { style(.caption) }
    @MainActor static var footnote: Font { style(.footnote) }
    @MainActor static var subheadline: Font { style(.subheadline) }
    @MainActor static var callout: Font { style(.callout) }
    @MainActor static var body: Font { style(.body) }
    @MainActor static var headline: Font { style(.headline) }
    @MainActor static var title3: Font { style(.title3) }
    @MainActor static var title2: Font { style(.title2) }

    /// The weight macOS gives a style in the system face, which a custom face
    /// has to be *asked* for — every family ships a regular, and only
    /// `.headline` is anything else.
    static func weight(of textStyle: Font.TextStyle) -> Font.Weight {
        textStyle == .headline ? .semibold : .regular
    }

    static func pointSize(of textStyle: Font.TextStyle) -> CGFloat {
        NSFont.preferredFont(forTextStyle: appKitStyle(of: textStyle)).pointSize
    }

    /// SwiftUI and AppKit spell the same eleven styles differently and offer no
    /// bridge between them.
    private static func appKitStyle(of textStyle: Font.TextStyle) -> NSFont.TextStyle {
        switch textStyle {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        default: return .body
        }
    }
}

extension View {
    /// Set perch's family as the default for everything underneath, so a label
    /// nobody gave an explicit font to is in it too — a sidebar row, a toggle's
    /// title, a button.
    ///
    /// A no-op while no family is named: `EnvironmentValues.font` is optional,
    /// and pushing `.body` into it would flatten the per-control defaults
    /// SwiftUI picks for a settings window nobody asked to restyle.
    ///
    /// When somebody *has* named one, that flattening is the deal rather than
    /// an oversight: a `Toggle`'s label or a `.controlSize(.small)` button's
    /// title is unreachable any other way, and it renders at body size as the
    /// price. Naming a family means everything is in it.
    @MainActor
    func perchType() -> some View {
        environment(\.font, ShelfFont.family == nil ? nil : ShelfFont.body)
    }
}

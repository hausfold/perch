import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// A file's visual: a QuickLook content thumbnail (image/PDF/video/…) when one
/// is available, otherwise the standard file icon. Reads the staged file
/// read-only; never touches original source URLs.
///
/// Both images are memoized process-wide and read back *synchronously* while
/// the view builds. A tile is a fresh value type every time the shelf expands
/// — and, on a lazy strip, every time it scrolls back into view — so `@State`
/// starts `nil` each time. Deriving from `.task` alone would show the
/// placeholder for a frame on every one of those rebuilds, and re-enter
/// LaunchServices for an icon the process is already holding.
struct FilePreview: View {
    let fileURL: URL?
    let kind: ShelfItem.Kind
    let contentType: UTType?
    let size: CGFloat

    @Environment(\.rice) private var rice
    @State private var thumbnail: NSImage?
    @State private var icon: NSImage?

    private var resolvedThumbnail: NSImage? {
        thumbnail ?? fileURL.flatMap { ThumbnailCache.shared.cached(for: $0) }
    }

    private var resolvedIcon: NSImage? {
        icon ?? fileURL.flatMap { IconCache.shared.cached(for: $0) }
    }

    var body: some View {
        Group {
            if let thumbnail = resolvedThumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(rice.wash(0.14), lineWidth: 1)
                    }
            } else {
                fileIcon
            }
        }
        .frame(width: size, height: size)
        .shadow(color: rice.shadow(0.28), radius: 3, y: 1)
        .accessibilityHidden(true)
        .task(id: fileURL?.path) { await loadPreview() }
    }

    private var fileIcon: some View {
        Group {
            if let resolvedIcon {
                Image(nsImage: resolvedIcon)
                    .resizable()
                    .scaledToFit()
            } else {
                // Also the placeholder for the frame or two before a cold
                // `icon(forFile:)` answers, not just for a missing URL.
                Image(systemName: "doc")
                    .resizable()
                    .scaledToFit()
            }
        }
    }

    // Restrict content previews to types QuickLook renders as real content, so
    // a generic file keeps its recognizable icon instead of a bland card.
    private var wantsContentPreview: Bool {
        guard let contentType else { return kind == .image }
        return contentType.conforms(to: .image)
            || contentType.conforms(to: .pdf)
            || contentType.conforms(to: .movie)
            || contentType.conforms(to: .audiovisualContent)
    }

    private func loadPreview() async {
        guard let fileURL else { return }
        // The icon comes first when there is nothing cached to show yet, even
        // for a file QuickLook will render: the thumbnail can take a while, and
        // waiting for it before asking for an icon leaves a generic `doc` glyph
        // on the tile for the whole render. The real icon goes up immediately
        // and QuickLook swaps over it — which is what the old synchronous
        // lookup in `body` did, minus the round trip per rebuild.
        if resolvedThumbnail == nil, resolvedIcon == nil {
            icon = await IconCache.shared.icon(for: fileURL)
        }
        guard wantsContentPreview else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        thumbnail = await ThumbnailCache.shared.thumbnail(
            for: fileURL,
            size: CGSize(width: size, height: size),
            scale: scale
        )
    }
}

/// Memoizes generated QuickLook thumbnails by staged path so re-expanding the
/// shelf doesn't re-render every preview. An `NSCache`, not a dictionary:
/// perch runs for weeks, and an unbounded map of every path ever previewed
/// would only ever grow.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()
    private let generator = QLThumbnailGenerator.shared

    /// The already-generated thumbnail, or nil. Cheap enough to call from
    /// `body`: a dictionary probe, never a render.
    func cached(for url: URL) -> NSImage? {
        cache.object(forKey: url.path as NSString)
    }

    func thumbnail(for url: URL, size: CGSize, scale: CGFloat) async -> NSImage? {
        if let hit = cached(for: url) { return hit }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )
        let image: NSImage? = await withCheckedContinuation { continuation in
            generator.generateBestRepresentation(for: request) { representation, _ in
                if let representation {
                    let cg = representation.cgImage
                    continuation.resume(returning: NSImage(
                        cgImage: cg,
                        size: NSSize(width: cg.width, height: cg.height)
                    ))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
        if let image { cache.setObject(image, forKey: url.path as NSString) }
        return image
    }
}

/// Memoizes `NSWorkspace.icon(forFile:)` — a synchronous LaunchServices round
/// trip that used to run inside `FilePreview.body`, once per tile, on every
/// expand.
///
/// Keyed **by path, not by content type**: `icon(forFile:)` is genuinely
/// per-file for `.app` bundles, Finder custom icons and alias badges, so a
/// type-keyed cache would hand two different apps the same icon.
@MainActor
final class IconCache {
    static let shared = IconCache()

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 512
        return cache
    }()

    /// The already-fetched icon, or nil. Safe to call from `body`.
    func cached(for url: URL) -> NSImage? {
        cache.object(forKey: url.path as NSString)
    }

    /// Fetches and memoizes. Stays on the main actor — `NSWorkspace`'s icon
    /// lookup is not documented as thread-safe — but is only ever reached from
    /// a `.task`, so the round trip lands after the layout pass rather than
    /// inside it, and a lazy strip bounds it to the tiles actually on screen.
    func icon(for url: URL) async -> NSImage? {
        if let hit = cached(for: url) { return hit }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(image, forKey: url.path as NSString)
        return image
    }
}

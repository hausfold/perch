import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// A file's visual: a QuickLook content thumbnail (image/PDF/video/…) when one
/// is available, otherwise the standard file icon. Reads the staged file
/// read-only; never touches original source URLs.
struct FilePreview: View {
    let fileURL: URL?
    let kind: ShelfItem.Kind
    let contentType: UTType?
    let size: CGFloat

    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                    }
            } else {
                fileIcon
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.28), radius: 3, y: 1)
        .accessibilityHidden(true)
        .task(id: fileURL?.path) { await loadThumbnail() }
    }

    private var fileIcon: some View {
        Group {
            if let fileURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: fileURL.path))
                    .resizable()
                    .scaledToFit()
            } else {
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

    private func loadThumbnail() async {
        guard wantsContentPreview, let fileURL else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        thumbnail = await ThumbnailCache.shared.thumbnail(
            for: fileURL,
            size: CGSize(width: size, height: size),
            scale: scale
        )
    }
}

/// Memoizes generated QuickLook thumbnails by staged path so re-expanding the
/// shelf doesn't re-render every preview.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private var cache: [String: NSImage] = [:]
    private let generator = QLThumbnailGenerator.shared

    func thumbnail(for url: URL, size: CGSize, scale: CGFloat) async -> NSImage? {
        if let hit = cache[url.path] { return hit }
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
        if let image { cache[url.path] = image }
        return image
    }
}

import Foundation
import UniformTypeIdentifiers

enum StagingRepositoryError: LocalizedError {
    case unsafePath
    case sourceMissing

    var errorDescription: String? {
        switch self {
        case .unsafePath:
            "Perch rejected an unsafe staged-file path."
        case .sourceMissing:
            "The dropped item disappeared before it could be staged."
        }
    }
}

final class StagingRepository: @unchecked Sendable {
    let rootURL: URL

    private let fileManager: FileManager
    private let manifestURL: URL
    private let lock = NSLock()

    /// Marks a container whose bytes outlive its shelf item — see `detach`.
    private static let detachedMarker = ".detached"
    /// How long detached bytes are kept before a sweep may drop them. Whatever
    /// received the drop holds a path into them and reads it on its own
    /// schedule — a pasted path may sit in a terminal for a while before anyone
    /// hits return.
    private static let detachedGrace: TimeInterval = 10 * 60

    init(rootURL: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager

        let selectedRoot: URL
        if let rootURL {
            selectedRoot = rootURL
        } else {
            let support = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            selectedRoot = support
                .appending(path: "Perch", directoryHint: .isDirectory)
                .appending(path: "ActiveShelf", directoryHint: .isDirectory)
        }

        self.rootURL = selectedRoot.standardizedFileURL.resolvingSymlinksInPath()
        manifestURL = self.rootURL.appending(path: "manifest.json")
        try fileManager.createDirectory(
            at: self.rootURL,
            withIntermediateDirectories: true
        )
    }

    func load() -> [ShelfItem] {
        lock.withLock {
            cleanupUnusableContainers()
            let read = readManifest()
            let decoded: [ShelfItem]
            switch read {
            case let .items(items): decoded = items
            case .absent, .unreadable: decoded = []
            }

            let existing = decoded.filter { item in
                guard let url = item.fileURL(inside: rootURL) else { return false }
                // Detach is authoritative even if the manifest was never
                // rewritten (a crash between the two): those bytes belong to
                // whatever took the drop, not to the shelf.
                return fileManager.fileExists(atPath: url.path)
                    && !isDetached(url.deletingLastPathComponent())
            }
            let recovered = recoverUntrackedFiles(excluding: Set(existing.map(\.relativePath)))
            let result = (existing + recovered).sorted { $0.addedAt < $1.addedAt }

            // A manifest we could not read is the one case where recovery must
            // NOT write back. Recovery invents a fresh UUID, a fresh `addedAt`
            // and an unpinned item for every file it adopts, so rewriting here
            // would replace a manifest that is merely unreadable *right now*
            // with a strictly worse one — losing pins and identities that are
            // still perfectly intact on disk. Better a shelf that rebuilt
            // itself for one launch than a manifest destroyed forever.
            guard case .unreadable = read else {
                if result != decoded {
                    try? persistUnlocked(result)
                }
                return result
            }
            return result
        }
    }

    func persist(_ items: [ShelfItem]) throws {
        try lock.withLock {
            try persistUnlocked(items)
        }
    }

    func allocateImportDirectory(id: UUID = UUID()) throws -> URL {
        let directory = rootURL
            .appending(path: id.uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    func item(forStagedURL url: URL, id: UUID = UUID()) throws -> ShelfItem {
        let standardizedRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let standardized = url.standardizedFileURL.resolvingSymlinksInPath()
        let rootComponents = standardizedRoot.pathComponents
        let itemComponents = standardized.pathComponents
        guard itemComponents.count > rootComponents.count,
              itemComponents.starts(with: rootComponents)
        else {
            throw StagingRepositoryError.unsafePath
        }
        guard fileManager.fileExists(atPath: standardized.path) else {
            throw StagingRepositoryError.sourceMissing
        }

        let values = try? standardized.resourceValues(forKeys: [
            .contentTypeKey,
            .fileSizeKey,
            .isDirectoryKey,
        ])
        let relativePath = itemComponents
            .dropFirst(rootComponents.count)
            .joined(separator: "/")
        let kind: ShelfItem.Kind
        if values?.isDirectory == true {
            kind = .folder
        } else if values?.contentType?.conforms(to: .image) == true {
            kind = .image
        } else if values?.contentType?.conforms(to: .url) == true {
            kind = .link
        } else if values?.contentType?.conforms(to: .plainText) == true {
            kind = .text
        } else {
            kind = .file
        }

        return ShelfItem(
            id: id,
            displayName: standardized.lastPathComponent,
            relativePath: relativePath,
            kind: kind,
            contentTypeIdentifier: values?.contentType?.identifier,
            byteCount: values?.fileSize.map(Int64.init)
        )
    }

    func remove(_ item: ShelfItem) throws {
        guard let url = item.fileURL(inside: rootURL) else {
            throw StagingRepositoryError.unsafePath
        }
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }

        var candidate = url.deletingLastPathComponent()
        // Compare paths, not URLs: one side of this walk carries a trailing
        // slash the other may not, and a comparison that never turns true here
        // would keep climbing past the staging root.
        while candidate.path != rootURL.path {
            let contents = try fileManager.contentsOfDirectory(atPath: candidate.path)
            guard contents.isEmpty else { break }
            try fileManager.removeItem(at: candidate)
            candidate.deleteLastPathComponent()
        }
    }

    /// Takes a staged container off the shelf *without* deleting its bytes.
    ///
    /// A destination that read the plain file URL rather than asking for the
    /// promise (a terminal that pasted the path, an editor that opened it) holds
    /// a path into the staging root and nothing says when it stops needing it.
    /// The item leaves the shelf like any other drag-out; the file stays behind,
    /// marked so it is never re-adopted as an item, and the next launch sweeps
    /// it.
    func detach(_ item: ShelfItem) throws {
        guard let url = item.fileURL(inside: rootURL) else {
            throw StagingRepositoryError.unsafePath
        }
        let container = url.deletingLastPathComponent()
        // Every import allocates its own container; a bare file directly in the
        // root has none to mark — and recovery only ever scans directories, so
        // it can't come back regardless.
        guard container != rootURL else { return }
        try Data().write(to: container.appending(path: Self.detachedMarker))
    }

    func removeAll() throws {
        let children = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        )
        for child in children where child != manifestURL {
            try fileManager.removeItem(at: child)
        }
        try persist([])
    }

    /// Drops items older than `cutoff`, **except pinned ones**.
    ///
    /// A pin means "this one stays" everywhere else in the app — `liftForExport`
    /// spares pinned items, the tile drag spares them, the take-everything
    /// handle spares them. Expiry honouring it too is what keeps that word
    /// meaning one thing; without it the timer takes exactly the tiles someone
    /// pinned because they mattered.
    func prune(olderThan cutoff: Date, items: [ShelfItem]) throws -> [ShelfItem] {
        let retained = items.filter { $0.addedAt >= cutoff || $0.isPinned }
        let removed = items.filter { $0.addedAt < cutoff && !$0.isPinned }
        for item in removed {
            try? remove(item)
        }
        try persist(retained)
        return retained
    }

    /// How the manifest hits the disk.
    ///
    /// **Not `.completeFileProtectionUnlessOpen`.** That class makes a file
    /// unreadable once it has been closed until the Mac is next unlocked — and
    /// perch is an accessory app that stays running for weeks and reloads its
    /// shelf on restore. A manifest written before a lock and read after one
    /// came back as "no manifest", which sent `load()` down the recovery path:
    /// every staged file re-adopted with a brand-new UUID, no pin state, a new
    /// `addedAt` — and then written back over the real manifest. The shelf
    /// silently forgot what was pinned and re-dated everything on it.
    ///
    /// `.completeFileProtectionUntilFirstUserAuthentication` keeps the manifest
    /// encrypted at rest (a powered-off Mac, before the first unlock after
    /// boot) while guaranteeing it is readable for the whole of a login
    /// session — which is exactly the window in which perch runs.
    static let manifestWriteOptions: Data.WritingOptions = [
        .atomic,
        .completeFileProtectionUntilFirstUserAuthentication,
    ]

    /// The three outcomes of reading the manifest. "Unreadable" is deliberately
    /// distinct from "absent": an absent manifest means a fresh shelf and
    /// recovery may write one, while an unreadable one means the truth is still
    /// on disk and must not be overwritten by a guess. Collapsing the two is
    /// what turned a transient read failure into permanent data loss.
    private enum ManifestRead {
        case items([ShelfItem])
        case absent
        case unreadable
    }

    private func readManifest() -> ManifestRead {
        guard fileManager.fileExists(atPath: manifestURL.path) else { return .absent }
        guard let data = try? Data(contentsOf: manifestURL) else { return .unreadable }
        guard let manifest = try? JSONDecoder.perch.decode(ShelfManifest.self, from: data),
              manifest.version <= ShelfManifest.currentVersion
        else {
            return .unreadable
        }
        return .items(manifest.items)
    }

    private func persistUnlocked(_ items: [ShelfItem]) throws {
        let data = try JSONEncoder.perch.encode(ShelfManifest(items: items))
        try data.write(to: manifestURL, options: Self.manifestWriteOptions)
    }

    private func recoverUntrackedFiles(excluding knownPaths: Set<String>) -> [ShelfItem] {
        var recovered: [ShelfItem] = []
        let containers = (try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for container in containers {
            guard container.lastPathComponent != manifestURL.lastPathComponent,
                  (try? container.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  !isDetached(container)
            else {
                continue
            }

            let stagedItems = (try? fileManager.contentsOfDirectory(
                at: container,
                includingPropertiesForKeys: [.contentTypeKey, .fileSizeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in stagedItems {
                if let item = try? item(forStagedURL: url),
                   !knownPaths.contains(item.relativePath) {
                    recovered.append(item)
                }
            }
        }
        return recovered
    }

    /// A display name that is safe as a single path component. Shared by every
    /// import path — drags on the Mac, shares on the phone, wire arrivals
    /// (where the name comes from another device and gets no benefit of the
    /// doubt: "." and ".." are names only a path traversal wants).
    ///
    /// A leading dot is stripped, not honored: a hidden staged file is
    /// invisible to recovery, and dot-names are how the staging sentinels
    /// (`.detached`, `.receiving`, `.<uuid>.partial`) stay out of a container's
    /// content — a peer-chosen name must not be able to impersonate one and
    /// get its own container swept.
    ///
    /// `FinderActionProtocol.safeFilename` is a byte-identical twin (the
    /// Finder targets don't compile PerchWire) — change both together.
    static func safeFilename(_ candidate: String) -> String {
        var cleaned = candidate
            .replacingOccurrences(of: "/", with: "∕")
            .replacingOccurrences(of: ":", with: "꞉")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    private func isDetached(_ container: URL) -> Bool {
        fileManager.fileExists(
            atPath: container.appending(path: Self.detachedMarker).path
        )
    }

    /// A detached container whose grace has run out — safe to drop.
    private func isExpiredDetachment(_ container: URL) -> Bool {
        let marker = container.appending(path: Self.detachedMarker)
        guard let marked = try? marker.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate else {
            // An unreadable marker date must not mean "expired now" — that
            // would delete bytes the grace period exists to protect. Wait for
            // a pass that can read it.
            return false
        }
        return Date().timeIntervalSince(marked) >= Self.detachedGrace
    }

    /// Drops containers the shelf can never show again: an import killed
    /// mid-copy (partial bytes) and one detached by a drag-out whose
    /// destination read the file URL directly (see `detach`) — by now whatever
    /// held that path has had its chance.
    private func cleanupUnusableContainers() {
        let containers = (try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for container in containers {
            guard (try? container.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else {
                continue
            }
            let children = (try? fileManager.contentsOfDirectory(
                at: container,
                includingPropertiesForKeys: nil,
                options: []
            )) ?? []
            // Sentinels are always dot-named (`.receiving`, `.<uuid>.partial`)
            // and `safeFilename` strips leading dots, so a staged item can
            // never look like one — a visible file merely *ending* in
            // ".partial" is content, not an interrupted import.
            let isInterrupted = children.contains {
                $0.lastPathComponent == ".receiving"
                    || ($0.lastPathComponent.hasPrefix(".")
                        && $0.lastPathComponent.hasSuffix(".partial"))
            }
            if isInterrupted || isExpiredDetachment(container) {
                try? fileManager.removeItem(at: container)
            }
        }
    }
}

private extension JSONEncoder {
    static var perch: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var perch: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

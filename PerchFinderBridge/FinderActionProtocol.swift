import Foundation

/// The Finder extension and the containing app never call each other directly.
/// They exchange a tiny, relative-path-only transaction in a Mac-only App Group.
/// A request contains names and attachment indexes but never source URLs; Perch
/// answers with the IDs it admitted before the extension asks Finder for bytes.
enum FinderActionProtocol {
    static let appGroupIdentifier = "88M28542LQ.com.hausfold.perch"
    /// Only the `perch` tool needs this — to ask Launch Services where the
    /// installed app lives so it can launch one. Liveness is never judged by
    /// it: the mailbox answering is the only test that a shelf is listening.
    static let appBundleIdentifier = "com.hausfold.perch"
    static let requestsDirectoryName = "FinderActionRequests"
    static let requestFilename = "request.json"
    static let responseFilename = "response.json"
    static let completionFilename = "completion.json"
    static let stagedDirectoryName = "Staged"
    static let abandonedAfter: TimeInterval = 10 * 60

    /// Byte-identical twin of `StagingRepository.safeFilename` (the Finder
    /// targets don't compile PerchWire) — change both together. Leading dots
    /// are stripped so a name can never impersonate a staging sentinel or
    /// stage a file recovery can't see.
    static func safeFilename(_ candidate: String) -> String {
        var cleaned = candidate
            .replacingOccurrences(of: "/", with: "∕")
            .replacingOccurrences(of: ":", with: "꞉")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? "Untitled" : cleaned
    }
}

struct FinderActionRequest: Codable, Sendable, Identifiable {
    let id: UUID
    let createdAt: Date
    let items: [FinderActionItem]
}

struct FinderActionItem: Codable, Sendable, Identifiable, Equatable {
    let id: UUID
    let displayName: String
    /// Index into the extension context's in-memory attachments. It is useful
    /// only while that invocation is alive and reveals no source location.
    let attachmentIndex: Int
}

struct FinderActionResponse: Codable, Sendable, Equatable {
    let acceptedItemIDs: [UUID]
}

struct FinderActionCompletion: Codable, Sendable, Equatable {
    let stagedItems: [FinderActionStagedItem]
    let failedItemIDs: [UUID]
}

struct FinderActionStagedItem: Codable, Sendable, Equatable {
    let id: UUID
    /// Relative to the request directory inside the App Group. Source paths
    /// never cross the process boundary or hit disk.
    let relativePath: String
}

struct FinderActionSnapshot: Sendable {
    let request: FinderActionRequest
    let response: FinderActionResponse?
    let completion: FinderActionCompletion?
}

enum FinderActionMailboxError: LocalizedError, Equatable {
    case appGroupUnavailable
    case unsafeRelativePath

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            "Perch's Finder handoff container is unavailable."
        case .unsafeRelativePath:
            "Perch rejected an unsafe Finder handoff path."
        }
    }
}

/// Synchronous filesystem mechanics. Callers keep these methods off their main
/// actor/thread; the type is immutable apart from files protected by atomic
/// writes, and each transaction owns a UUID directory.
final class FinderActionMailbox: @unchecked Sendable {
    let rootURL: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootURL: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            guard let group = fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: FinderActionProtocol.appGroupIdentifier
            ) else {
                throw FinderActionMailboxError.appGroupUnavailable
            }
            self.rootURL = group.appending(
                path: FinderActionProtocol.requestsDirectoryName,
                directoryHint: .isDirectory
            )
        }
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        try fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
    }

    func createRequest(_ request: FinderActionRequest) throws {
        let directory = requestDirectory(for: request.id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        try write(request, to: directory.appending(path: FinderActionProtocol.requestFilename))
    }

    func writeResponse(_ response: FinderActionResponse, for requestID: UUID) throws {
        try write(
            response,
            to: requestDirectory(for: requestID)
                .appending(path: FinderActionProtocol.responseFilename)
        )
    }

    func readResponse(for requestID: UUID) throws -> FinderActionResponse? {
        try readIfPresent(
            FinderActionResponse.self,
            from: requestDirectory(for: requestID)
                .appending(path: FinderActionProtocol.responseFilename)
        )
    }

    func writeCompletion(_ completion: FinderActionCompletion, for requestID: UUID) throws {
        try write(
            completion,
            to: requestDirectory(for: requestID)
                .appending(path: FinderActionProtocol.completionFilename)
        )
    }

    func snapshots() throws -> [FinderActionSnapshot] {
        let directories = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return try directories.compactMap { directory in
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let request = try readIfPresent(
                      FinderActionRequest.self,
                      from: directory.appending(path: FinderActionProtocol.requestFilename)
                  )
            else {
                return nil
            }
            return try FinderActionSnapshot(
                request: request,
                response: readIfPresent(
                    FinderActionResponse.self,
                    from: directory.appending(path: FinderActionProtocol.responseFilename)
                ),
                completion: readIfPresent(
                    FinderActionCompletion.self,
                    from: directory.appending(path: FinderActionProtocol.completionFilename)
                )
            )
        }
        .sorted { $0.request.createdAt < $1.request.createdAt }
    }

    func stagedDirectory(for requestID: UUID, itemID: UUID) throws -> URL {
        let directory = requestDirectory(for: requestID)
            .appending(path: FinderActionProtocol.stagedDirectoryName, directoryHint: .isDirectory)
            .appending(path: itemID.uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func relativePath(for url: URL, requestID: UUID) throws -> String {
        let root = requestDirectory(for: requestID)
            .standardizedFileURL.resolvingSymlinksInPath()
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.pathComponents.count > root.pathComponents.count,
              candidate.pathComponents.starts(with: root.pathComponents)
        else {
            throw FinderActionMailboxError.unsafeRelativePath
        }
        return candidate.pathComponents
            .dropFirst(root.pathComponents.count)
            .joined(separator: "/")
    }

    func stagedURL(relativePath: String, requestID: UUID) throws -> URL {
        guard !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains("..")
        else {
            throw FinderActionMailboxError.unsafeRelativePath
        }
        let root = requestDirectory(for: requestID)
            .standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appending(path: relativePath)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.pathComponents.count > root.pathComponents.count,
              candidate.pathComponents.starts(with: root.pathComponents)
        else {
            throw FinderActionMailboxError.unsafeRelativePath
        }
        return candidate
    }

    func removeRequest(_ requestID: UUID) throws {
        let directory = requestDirectory(for: requestID)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    private func requestDirectory(for requestID: UUID) -> URL {
        rootURL.appending(path: requestID.uuidString, directoryHint: .isDirectory)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try encoder.encode(value).write(to: url, options: [.atomic])
    }

    private func readIfPresent<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(type, from: Data(contentsOf: url))
    }
}

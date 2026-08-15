import Foundation

/// The *sender's* half of the App Group mailbox, shared by everything that
/// hands bytes to a running Perch: the Finder Action and the `perch` command
/// line tool. `FinderActionMailbox` is the filesystem mechanics; this is the
/// protocol played out in order — publish names, wait for Perch's admission
/// receipt, copy only what it reserved, then publish the relative paths.
///
/// The ordering is the point. Perch decides the free-tier cap *before* a
/// single byte is copied, and a source URL never crosses into the App Group:
/// only display names go in the request, only relative staged paths come back.
struct HandoffClient: Sendable {
    let mailbox: FinderActionMailbox

    init(mailbox: FinderActionMailbox) {
        self.mailbox = mailbox
    }

    /// Sandboxed senders (the Finder Action) reach the group container through
    /// their entitlement.
    init() throws {
        self.init(mailbox: try FinderActionMailbox())
    }

    /// Unsandboxed senders (the `perch` tool) have no App Group entitlement, so
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` answers nil for
    /// them. The container's path is stable and they run as the same user, so
    /// they address it directly.
    ///
    /// Deliberately fails when the container is missing rather than creating
    /// it: an absent container means Perch has never run on this account, and
    /// the app — not a CLI — should be the one to make its own container.
    static func unsandboxed(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> HandoffClient {
        let container = groupContainerURL(home: home)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: container.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw FinderActionMailboxError.appGroupUnavailable
        }
        return HandoffClient(
            mailbox: try FinderActionMailbox(
                rootURL: container.appending(
                    path: FinderActionProtocol.requestsDirectoryName,
                    directoryHint: .isDirectory
                ),
                fileManager: fileManager
            )
        )
    }

    static func groupContainerURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Group Containers", directoryHint: .isDirectory)
            .appending(
                path: FinderActionProtocol.appGroupIdentifier,
                directoryHint: .isDirectory
            )
    }

    /// Publish the batch Perch is being asked to admit. Names only — the caller
    /// keeps its own mapping from each item to whatever it will read bytes from.
    func openRequest(displayNames: [String], now: Date = Date()) throws -> FinderActionRequest {
        let request = FinderActionRequest(
            id: UUID(),
            createdAt: now,
            items: displayNames.enumerated().map { index, name in
                FinderActionItem(
                    id: UUID(),
                    displayName: FinderActionProtocol.safeFilename(name),
                    attachmentIndex: index
                )
            }
        )
        try mailbox.createRequest(request)
        return request
    }

    /// Block until Perch answers with the slots it reserved, or the deadline
    /// passes. A nil answer means no Perch is listening on this account.
    func waitForAdmission(
        _ requestID: UUID,
        deadline: Date,
        poll: TimeInterval = 0.1
    ) throws -> FinderActionResponse? {
        while Date() < deadline {
            if let response = try mailbox.readResponse(for: requestID) {
                return response
            }
            Thread.sleep(forTimeInterval: poll)
        }
        return nil
    }

    func acceptedItems(
        in request: FinderActionRequest,
        response: FinderActionResponse
    ) -> [FinderActionItem] {
        let ids = Set(response.acceptedItemIDs)
        return request.items.filter { ids.contains($0.id) }
    }

    /// Copy one admitted item's bytes into its own staged directory, finishing
    /// through a hidden `.partial` so a half-written file can never be adopted.
    /// The source is only read — never moved, renamed, or touched.
    func stage(
        sourceURL: URL,
        item: FinderActionItem,
        requestID: UUID
    ) throws -> FinderActionStagedItem {
        let fileManager = FileManager()
        let directory = try mailbox.stagedDirectory(for: requestID, itemID: item.id)
        let destination = directory.appending(path: item.displayName)
        let partial = directory.appending(path: ".\(item.id.uuidString).partial")
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped { sourceURL.stopAccessingSecurityScopedResource() }
        }

        var coordinationError: NSError?
        var copyResult: Result<Void, Error> = .success(())
        NSFileCoordinator().coordinate(
            readingItemAt: sourceURL,
            options: [.withoutChanges],
            error: &coordinationError
        ) { coordinatedURL in
            copyResult = Result {
                if fileManager.fileExists(atPath: partial.path) {
                    try fileManager.removeItem(at: partial)
                }
                try fileManager.copyItem(at: coordinatedURL, to: partial)
                try fileManager.moveItem(at: partial, to: destination)
            }
        }
        if let coordinationError { throw coordinationError }
        try copyResult.get()

        return FinderActionStagedItem(
            id: item.id,
            relativePath: try mailbox.relativePath(for: destination, requestID: requestID)
        )
    }

    func finish(_ completion: FinderActionCompletion, for requestID: UUID) throws {
        try mailbox.writeCompletion(completion, for: requestID)
    }

    /// Give up on a request without leaving Perch holding reservations. The
    /// request directory is deliberately left in place: Perch may have written
    /// its response while we were timing out, and an empty completion is what
    /// releases those slots on its next scan.
    func abandon(_ requestID: UUID) {
        try? mailbox.writeCompletion(
            FinderActionCompletion(stagedItems: [], failedItemIDs: []),
            for: requestID
        )
    }
}

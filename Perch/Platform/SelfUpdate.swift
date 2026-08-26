import AppKit
import Foundation
import os

// MARK: - SelfUpdate (the drag-install cohort's one click)
//
// Three of perch's four install doors are owned by something that already knows
// how to update: `haus update`, `brew upgrade`, a flake input. The fourth — a
// ZIP dragged into /Applications — used to be told to download it again and
// drag it again, which is the whole reason this file exists.
//
// The sandbox splits the job in two, and the split is the design:
//
//   here (sandboxed)   ask GitHub which asset belongs to the tag, download it
//                      into the container, unzip it there, check it is signed
//                      by us. Everything so far is inside the container, which
//                      is exactly what the app sandbox permits — including the
//                      part that ISN'T possible here: notarization, which only
//                      the updater can settle.
//   PerchUpdater.app   the swap into /Applications and the relaunch. It is a
//                      separate, un-sandboxed bundle nested in ours, launched
//                      through LaunchServices — which does NOT pass our sandbox
//                      on, where a spawned child would inherit it.
//
// Nothing here writes outside the container, and nothing here runs with more
// authority than the shelf does. The handoff — what to install, what to replace
// — is `UpdateHandoff.swift`, compiled into both halves.
//
// Cohort-gated at the door: `InstallKind.canSelfUpdate`. A rice or cask install
// that took this path would replace a bundle its package manager owns and be
// silently reverted by the next `haus update` — with a `.direct` install there
// is nothing upstream to disagree with.

@MainActor
final class SelfUpdate {
    /// What the shelf strip says while this runs. `progress` is nil for the
    /// steps that have no measurable length (unzip, verify).
    struct Phase: Equatable {
        var text: String
        var progress: Double?
        var isFailure = false
    }

    static let shared = SelfUpdate()

    private let logger = Logger(subsystem: "com.hausfold.perch", category: "SelfUpdate")
    private var running = false

    /// Where the updater lives inside our own bundle. Absent in a build made
    /// before the target existed, and in any bundle assembled by hand — the
    /// caller falls back to the release page rather than pretending.
    static var updaterURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/PerchUpdater.app")
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: updaterURL.path)
    }

    private static var home: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    // MARK: The run

    /// Download `version`, verify it, hand it to the updater, and quit. Returns
    /// immediately; `onPhase` carries every step, and the last thing it reports
    /// on the happy path is the handoff — the app is gone a moment later.
    func begin(version: String, onPhase: @escaping (Phase) -> Void) {
        guard !running else { return }
        running = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.perform(version: version, onPhase: onPhase)
            } catch is CancellationError {
                self.running = false
            } catch {
                self.logger.error("self-update failed: \(error.localizedDescription, privacy: .public)")
                self.running = false
                onPhase(Phase(text: error.localizedDescription, progress: nil, isFailure: true))
            }
        }
    }

    private func perform(version: String, onPhase: @escaping (Phase) -> Void) async throws {
        guard Self.isAvailable else {
            throw SelfUpdateError("this build has no updater — download it from the release page")
        }
        onPhase(Phase(text: "Finding Perch \(version)…", progress: nil))
        let asset = try await Self.assetURL(for: version)

        onPhase(Phase(text: "Downloading Perch \(version)…", progress: 0))
        let zip = try await download(asset, version: version) { fraction in
            onPhase(Phase(text: "Downloading Perch \(version)…", progress: fraction))
        }

        onPhase(Phase(text: "Unpacking…", progress: nil))
        let payload = try await Self.unpack(zip)

        onPhase(Phase(text: "Checking the signature…", progress: nil))
        // Identity only, here: the container cannot settle notarization (see
        // `PerchSigning.identityRequirement`). The full check — the one that
        // decides whether anything is installed — runs in the updater.
        try PerchSigning.verify(bundle: payload, requirement: PerchSigning.identityRequirement)

        let target = Bundle.main.bundleURL.standardizedFileURL
        let request = UpdateRequest(
            version: version,
            payloadPath: payload.path,
            targetPath: target.path,
            appPID: ProcessInfo.processInfo.processIdentifier,
            relaunch: true,
            requestedAt: Date().timeIntervalSince1970
        )
        try Self.write(request)

        onPhase(Phase(text: "Installing — Perch will reopen…", progress: nil))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        _ = try await NSWorkspace.shared.openApplication(
            at: Self.updaterURL, configuration: configuration
        )
        logger.log("handed \(version, privacy: .public) to the updater; quitting")
        // The updater waits for this pid to go before it touches the bundle.
        NSApp.terminate(nil)
    }

    // MARK: Steps

    /// The release's macOS ZIP, from the same endpoint the hourly check uses.
    /// Asked for by tag rather than trusting a name we compose: the asset name
    /// is CI's to choose, and a 404 from a guessed URL is a worse error than a
    /// missing asset.
    static func assetURL(for version: String) async throws -> URL {
        var request = URLRequest(url: UpdateCheck.endpoint)
        request.setValue("perch-update-check", forHTTPHeaderField: "user-agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SelfUpdateError("GitHub's answer was unreadable")
        }
        return try selectAsset(from: object, version: version)
    }

    /// Pure, so the suite can pin the two refusals that matter without a
    /// network: a release that moved on under us, and a download that isn't on
    /// GitHub — the second because this URL is the one thing in the flow that
    /// GitHub's JSON gets to choose.
    nonisolated static func selectAsset(from object: [String: Any], version: String) throws -> URL {
        let tag = (object["tag_name"] as? String) ?? ""
        guard tag == "v\(version)" || tag == version else {
            throw SelfUpdateError("the latest release is \(tag), not \(version) — check again")
        }
        let assets = (object["assets"] as? [[String: Any]]) ?? []
        guard let url = assets.compactMap({ asset -> URL? in
            guard let name = asset["name"] as? String,
                  name.hasSuffix("-macos.zip"),
                  let string = asset["browser_download_url"] as? String,
                  let url = URL(string: string)
            else { return nil }
            return url
        }).first else {
            throw SelfUpdateError("that release has no macOS download")
        }
        guard url.scheme == "https", let host = url.host,
              host == "github.com" || host.hasSuffix(".github.com") || host.hasSuffix(".githubusercontent.com")
        else {
            throw SelfUpdateError("that release's download isn't on GitHub")
        }
        return url
    }

    private func download(
        _ url: URL, version: String, onProgress: @escaping (Double) -> Void
    ) async throws -> URL {
        let directory = UpdateHandoff.downloadDirectory(home: Self.home)
        // A previous attempt's bytes are never reused: the only thing that
        // makes a download trustworthy here is the signature check on what came
        // out of it, and half a file from yesterday fails that slowly.
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let observer = DownloadProgress(onProgress: onProgress)
        let (temporary, response) = try await URLSession.shared.download(from: url, delegate: observer)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw SelfUpdateError("GitHub answered \(http.statusCode) for the download")
        }
        let destination = directory.appendingPathComponent("perch-\(version).zip")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    /// `ditto`, not a Foundation unzip: it is what CI zipped the bundle with,
    /// and it is the one that restores the symlinks, the resource forks and the
    /// stapled notarization ticket that a naive extractor drops — after which
    /// the signature check below would fail on a perfectly good release.
    ///
    /// It is a child of a sandboxed process, so it inherits the sandbox: it can
    /// read and write the container and nothing else, which is all it is asked
    /// to do.
    static func unpack(_ zip: URL) async throws -> URL {
        let destination = zip.deletingLastPathComponent().appendingPathComponent("unpacked", isDirectory: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, destination.path]
        let errors = Pipe()
        ditto.standardError = errors
        try ditto.run()
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                ditto.waitUntilExit()
                continuation.resume()
            }
        }
        guard ditto.terminationStatus == 0 else {
            let message = String(
                data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SelfUpdateError("the download wouldn't unpack\(message.map { ": \($0)" } ?? "")")
        }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: destination, includingPropertiesForKeys: nil
        )) ?? []
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw SelfUpdateError("the download had no app in it")
        }
        return app.standardizedFileURL
    }

    static func write(_ request: UpdateRequest) throws {
        let url = UpdateHandoff.requestURL(home: home)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(request).write(to: url, options: .atomic)
    }

    // MARK: What the updater left behind

    /// Read once, on launch, and deleted — the relaunched app is the only
    /// reader, and a result kept around would re-announce an update every time
    /// perch starts.
    static func consumeResult() -> UpdateResult? {
        let url = UpdateHandoff.resultURL(home: home)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode(UpdateResult.self, from: data)
        else { return nil }
        return result
    }
}

struct SelfUpdateError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// `URLSession.download(from:delegate:)` reports progress nowhere else.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.onProgress(min(max(fraction, 0), 1)) }
    }

    // Required by the protocol; the file is handed back by the async call.
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {}
}

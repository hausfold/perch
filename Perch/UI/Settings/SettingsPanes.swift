import AppKit
import SwiftUI

// MARK: - The panes

/// The sidebar's contents, in the order they appear.
///
/// The names are load-bearing: the manual sends people to "Settings ▸ Shelf",
/// "Settings ▸ Watched Folders" and "Settings ▸ Updates" by name — and it lives
/// in `hausfold/hausfold.co`, so it cannot be the same commit and nothing here
/// checks the two agree. Rename one here and rename it there in the same round.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case shelf
    case folders
    case devices
    case updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .shelf: return "Shelf"
        case .folders: return "Watched Folders"
        case .devices: return "iPhone & iPad"
        case .updates: return "Updates"
        }
    }

    /// The line under the pane's title: what this pane is for, in one breath.
    var summary: String {
        switch self {
        case .general:
            return "How Perch starts, where it shows up, and its place in Finder."
        case .shelf:
            return "What the shelf holds on to, and what letting go of it costs."
        case .folders:
            return "Folders whose new files land on the shelf without being dropped."
        case .devices:
            return "Send to this Mac from a paired iPhone or iPad, over your own network."
        case .updates:
            return "How Perch finds out that a newer release exists."
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .shelf: return "tray.full.fill"
        case .folders: return "folder.fill"
        case .devices: return "iphone"
        case .updates: return "arrow.down.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .shelf: return .green
        case .folders: return .blue
        case .devices: return .indigo
        case .updates: return .orange
        }
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPaneLayout(title: SettingsPane.general.title, subtitle: SettingsPane.general.summary) {
            SettingsCard {
                SettingsRow(
                    symbol: "power",
                    title: "Launch Perch at login",
                    subtitle: "Perch comes back in the menu bar — no window, no Dock icon.",
                    locked: settings.isDeclared(AppConfig.Key.launchAtLogin)
                ) {
                    Toggle(
                        "Launch Perch at login",
                        isOn: Binding(
                            get: { settings.launchAtLogin },
                            set: { enabled in settings.setLaunchAtLogin(enabled) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow(
                    symbol: "menubar.dock.rectangle",
                    title: "Show a drop target on every display",
                    subtitle: "Each screen gets its own shelf at the notch. Off keeps it to your main display.",
                    locked: settings.isDeclared(AppConfig.Key.showOnAllDisplays)
                ) {
                    Toggle("Show a drop target on every display", isOn: $settings.showOnAllDisplays)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            SettingsDeclaredNote(
                settings: settings,
                keys: [AppConfig.Key.launchAtLogin, AppConfig.Key.showOnAllDisplays]
            )
            SettingsWriteErrorNote(settings: settings)

            if let error = settings.launchAtLoginError {
                SettingsNote(symbol: "exclamationmark.triangle.fill", tint: .orange, text: error)
            }

            SettingsCard {
                SettingsRow(
                    symbol: "contextualmenu.and.cursorarrow",
                    title: "Finder’s right-click menu",
                    subtitle: "“Add to Perch Shelf” is under Services whenever files or folders are selected."
                ) {}
            }
            // No button here on purpose. This is a classic Service, which is on
            // by default and needs no enabling — and the one place macOS lets a
            // user turn it off is a pane with no anchor that lands on it, so a
            // button would open the top of a long list and leave the same walk
            // to describe. Describe the walk and skip the button.
            SettingsFootnote(
                """
                It is on by default. If it ever goes missing, it is in System Settings ▸ \
                Keyboard ▸ Keyboard Shortcuts… ▸ Services, under Files and Folders.
                """
            )

            SettingsFootnote(
                """
                Every switch in this window is stored in \(configPath) — the file is what \
                Perch reads, so editing it by hand is the same as clicking here, and it \
                lands without a relaunch.
                """
            )
        }
    }

    /// Named, not hidden behind a button: it is the only way to find a path
    /// inside the sandbox container, where nobody would think to look.
    private var configPath: String {
        RiceFiles.abbreviate(settings.configFileURL.path)
    }
}

// MARK: - Shelf

struct ShelfPane: View {
    @ObservedObject var settings: AppSettings

    /// The offered expiries. 0 is "never", and it is the default — see
    /// `AppSettings.retentionDays` for why a staged copy that expires is often
    /// the only copy there was.
    private static let choices = [0, 1, 3, 7, 14, 30]

    var body: some View {
        SettingsPaneLayout(title: SettingsPane.shelf.title, subtitle: SettingsPane.shelf.summary) {
            SettingsCard {
                SettingsRow(
                    symbol: "clock.arrow.circlepath",
                    title: "Discard items after",
                    subtitle: "Anything added longer ago than this leaves the shelf on its own. Pinned items stay.",
                    locked: settings.isDeclared(AppConfig.Key.retentionDays)
                ) {
                    Picker("Discard items after", selection: $settings.retentionDays) {
                        ForEach(offeredChoices, id: \.self) { days in
                            Text(Self.label(for: days)).tag(days)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 128)
                }
            }
            SettingsFootnote(retentionNote)

            SettingsDeclaredNote(settings: settings, keys: [AppConfig.Key.retentionDays])
            SettingsWriteErrorNote(settings: settings)

            SettingsNote(
                symbol: "lock.shield.fill",
                tint: .green,
                text: """
                    Perch always stages a private copy and only ever offers copy when you \
                    drag out. Dragging an item off the shelf removes it from the shelf; \
                    your originals are never moved or deleted.
                    """
            )
        }
    }

    /// A value stored by an older build (or by hand) has to stay selectable, or
    /// the menu would show blank and the first click would silently change it.
    private var offeredChoices: [Int] {
        Self.choices.contains(settings.retentionDays)
            ? Self.choices
            : (Self.choices + [settings.retentionDays]).sorted()
    }

    private static func label(for days: Int) -> String {
        switch days {
        case 0: return "Never"
        case 1: return "1 day"
        default: return "\(days) days"
        }
    }

    /// The note says what discarding actually *does*, not that it happens.
    /// "Discard" reads like taking something off a shelf; this is a delete, and
    /// a staged copy is often the only copy there is.
    private var retentionNote: String {
        guard settings.retentionDays > 0 else {
            return "Nothing leaves the shelf until you take it out or clear it."
        }
        return """
            Discarding deletes the staged copy — it does not go to the Trash, and for a \
            dragged-in promise, a link or typed text it is the only copy there is.
            """
    }
}

// MARK: - Watched folders

struct WatchedFoldersPane: View {
    @ObservedObject var folderWatch: FolderWatchCenter

    /// Where this Mac saves screenshots, and that path in the canonical form
    /// `FolderWatchCenter` dedupes on — both worked out in one detached read
    /// when the pane appears, rather than from a body accessor. Same spirit as
    /// ShelfTheme re-reading the drop when the shelf opens, and no file watcher
    /// anywhere.
    ///
    /// The canonical path rides along so `body` never has to resolve symlinks
    /// itself: that is a filesystem call, and this pane is not the place to
    /// make an exception to "blocking file work stays off the main actor".
    ///
    /// Nil until the read lands, and the offer below renders nothing while it
    /// is: a card that says "Desktop" and then corrects itself to "Downloads"
    /// is worse than one that arrives a beat late.
    private struct ScreenshotsOffer: Sendable {
        let url: URL
        let canonicalPath: String
    }

    @State private var offer: ScreenshotsOffer?

    var body: some View {
        SettingsPaneLayout(title: SettingsPane.folders.title, subtitle: SettingsPane.folders.summary) {
            if let suggestion = screenshotsSuggestion {
                SettingsCard {
                    SettingsRow(
                        symbol: "camera.viewfinder",
                        tint: .blue,
                        title: "Shelf my screenshots",
                        subtitle: "This Mac saves captures to \(Self.abbreviate(suggestion.path)). "
                            + "Watch that folder and new ones land on the shelf."
                    ) {
                        Button("Watch That Folder") {
                            watchScreenshots(at: suggestion)
                        }
                        .controlSize(.small)
                    }
                }
            }

            SettingsCard {
                if folderWatch.rows.isEmpty {
                    SettingsPlaceholderRow(text: "No folders watched yet.")
                } else {
                    ForEach(Array(folderWatch.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { SettingsDivider() }
                        SettingsRow(
                            symbol: row.displayPath == nil ? "exclamationmark.triangle.fill" : "folder.fill",
                            tint: row.displayPath == nil ? .orange : .blue,
                            title: Self.name(of: row.displayPath),
                            subtitle: row.displayPath ?? "Perch can no longer reach this folder."
                        ) {
                            Button("Stop Watching") {
                                folderWatch.removeFolder(row.id)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            HStack {
                Button("Watch a Folder…") {
                    addWatchedFolder()
                }
                Spacer()
            }
            .padding(.top, -8)

            SettingsFootnote(
                """
                New files that land in a watched folder are copied onto the shelf. The \
                originals never move, and taking a tile off the shelf never touches them. \
                Every folder here is one you picked in a panel, and this list is the only \
                place they are added or removed — one row, one folder, “Stop Watching” to \
                undo it.
                """
            )
        }
        // Off main: the reads are small, but the pane is not the place to make
        // an exception to "blocking file work stays off the main actor".
        .task {
            offer = await Task.detached(priority: .utility) {
                let url = ScreenshotsFolder.resolve()
                return ScreenshotsOffer(
                    url: url,
                    canonicalPath: url.standardizedFileURL.resolvingSymlinksInPath().path
                )
            }.value
        }
    }

    // MARK: Shelf my screenshots

    /// The folder to offer, or nil when there is nothing to offer — the read has
    /// not landed, or perch already watches it.
    ///
    /// An offer is the whole of this feature now. It adds one folder and is gone
    /// once taken; it owns no row in the list below, and there is no state
    /// anywhere recording that a folder came from here. The switch this replaced
    /// was the other thing — a live query over the list, whose "off" deleted
    /// whichever row happened to sit on the folder it had guessed at, including
    /// one added deliberately through "Watch a Folder…".
    ///
    /// `watches(canonicalPath:)` answers false for the first moments after
    /// launch, before any bookmark has resolved, so this can briefly offer a
    /// folder that is already watched. Harmless in both directions: `rows` publishes when the
    /// watcher attaches and the card goes, and taking the offer meanwhile adopts
    /// the existing folder rather than adding a second one.
    private var screenshotsSuggestion: URL? {
        guard let offer, !folderWatch.watches(canonicalPath: offer.canonicalPath) else { return nil }
        return offer.url
    }

    /// The panel is the whole permission model, so even a folder perch can name
    /// has to be handed over in one. All an offer can save is the navigating and
    /// the knowing-where — which, on a Mac whose captures do not go to the
    /// Desktop, is most of it. Cancelling grants nothing and changes nothing.
    ///
    /// Whatever they pick is what gets watched, even when it is not the folder
    /// offered: it is an ordinary watched folder from the moment it lands, and
    /// nothing here treats it differently afterwards.
    private func watchScreenshots(at folder: URL) {
        watch(runFolderPanel(
            openingAt: folder,
            allowsMultiple: false,
            message: "Perch will copy new screenshots from this folder onto the shelf."
        ))
    }

    /// `~`-abbreviated for display only, against the real home — inside the
    /// sandbox `NSHomeDirectory()` is the container (same reason
    /// `FolderWatchCenter` goes through `RiceFiles.home`).
    private static func abbreviate(_ path: String) -> String {
        let home = RiceFiles.home.path
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private static func name(of displayPath: String?) -> String {
        guard let displayPath else { return "Folder unavailable" }
        let name = (displayPath as NSString).lastPathComponent
        return name.isEmpty ? displayPath : name
    }

    /// The panel is the whole permission model: the grant it returns is what
    /// the watcher keeps (as an app-scoped bookmark), so there is
    /// nothing to pre-authorize and nothing typed in by hand.
    private func addWatchedFolder() {
        watch(runFolderPanel(
            openingAt: nil,
            allowsMultiple: true,
            message: "Perch will copy new files from this folder onto the shelf."
        ))
    }

    /// Both doors into this pane are the same panel — the offer only opens it
    /// somewhere in particular and takes one folder. Empty when it was
    /// cancelled, which grants nothing and changes nothing.
    private func runFolderPanel(openingAt directory: URL?, allowsMultiple: Bool, message: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = allowsMultiple
        panel.directoryURL = directory
        panel.prompt = "Watch"
        panel.message = message
        NSApp.activate()
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }

    private func watch(_ urls: [URL]) {
        for url in urls {
            folderWatch.addFolder(at: url)
        }
    }
}

// MARK: - Devices

struct DevicesPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var mobile: MobileReceiver

    var body: some View {
        SettingsPaneLayout(title: SettingsPane.devices.title, subtitle: SettingsPane.devices.summary) {
            SettingsCard {
                SettingsRow(
                    symbol: "antenna.radiowaves.left.and.right",
                    title: "Receive from paired devices",
                    subtitle: "Off tears the listener down. Pairings are remembered for when it comes back.",
                    locked: settings.isDeclared(AppConfig.Key.mobileEnabled)
                ) {
                    // Plain binding: `MobileReceiver` follows the setting's
                    // publisher, so the listener starts and stops whether the
                    // change came from this switch or from the file.
                    Toggle("Receive from paired devices", isOn: $settings.mobileEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            SettingsDeclaredNote(settings: settings, keys: [AppConfig.Key.mobileEnabled])
            SettingsWriteErrorNote(settings: settings)

            SettingsCard {
                if mobile.pairedDevices.isEmpty {
                    SettingsPlaceholderRow(text: "No devices paired yet.")
                } else {
                    ForEach(Array(mobile.pairedDevices.enumerated()), id: \.element.id) { index, device in
                        if index > 0 { SettingsDivider() }
                        SettingsRow(
                            symbol: "iphone",
                            tint: .indigo,
                            title: device.name,
                            subtitle: "Paired \(device.pairedAt.formatted(date: .abbreviated, time: .omitted))"
                        ) {
                            Button("Revoke", role: .destructive) {
                                mobile.revoke(device)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            HStack {
                Button("Pair a Device…") {
                    MobilePairingWindowController.shared.present(receiver: mobile)
                }
                .disabled(!settings.mobileEnabled)
                Spacer()
            }
            .padding(.top, -8)

            SettingsFootnote(
                """
                Anything you put on Perch on a paired iPhone lands on this shelf when both \
                are on your network — end-to-end encrypted with a key made at pairing, \
                never through a server. Revoking a device ends it instantly.
                """
            )
        }
    }
}

// MARK: - Updates

struct UpdatesPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var update: UpdateCheck

    var body: some View {
        SettingsPaneLayout(title: SettingsPane.updates.title, subtitle: SettingsPane.updates.summary) {
            SettingsCard {
                SettingsRow(
                    symbol: "arrow.clockwise",
                    title: "Check for new releases",
                    subtitle: "Perch asks GitHub for the latest tag once an hour. It is its only network call.",
                    locked: settings.isDeclared(AppConfig.Key.automaticUpdateChecks)
                ) {
                    Toggle("Check for new releases", isOn: $settings.automaticUpdateChecks)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow(
                    symbol: pendingVersion == nil ? "checkmark.seal.fill" : "sparkles",
                    tint: pendingVersion == nil ? .secondary : .orange,
                    title: versionTitle,
                    subtitle: versionSubtitle
                ) {
                    // Check Now stays whatever the answer was: an update taken
                    // outside the app (a `brew upgrade` in another window) is
                    // only cleared by another check, and waiting out the hourly
                    // timer is not an answer.
                    HStack(spacing: 8) {
                        Button("Check Now") {
                            update.checkForUpdates(userInitiated: true)
                        }
                        if pendingVersion != nil {
                            Button(update.actionButtonLabel) {
                                update.performUpdate()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(update.installPhase != nil)
                        }
                    }
                }
            }

            SettingsDeclaredNote(
                settings: settings, keys: [AppConfig.Key.automaticUpdateChecks]
            )
            SettingsWriteErrorNote(settings: settings)

            SettingsFootnote(
                update.installKind.canSelfUpdate
                    ? """
                      \(update.installKind.settingsNote) The download is checked against \
                      our Developer ID and Apple's notarization before it replaces anything, \
                      and Perch reopens itself when it's done.
                      """
                    : """
                      \(update.installKind.settingsNote) Sandboxed, Perch never installs this \
                      kind of install itself; it hands you the command instead.
                      """
            )
        }
    }

    private var pendingVersion: String? { update.pendingVersion }

    private var versionTitle: String {
        if let pending = pendingVersion {
            return "Perch \(pending) is available"
        }
        return "Perch \(update.perchVersion)"
    }

    /// A user-initiated check's answer wins the line while it lasts — it is the
    /// only feedback the button gives.
    private var versionSubtitle: String {
        if let phase = update.installPhase { return phase.text }
        if let note = update.statusNote { return note }
        if pendingVersion != nil { return update.installKind.actionHint }
        return "The version running on this Mac."
    }
}

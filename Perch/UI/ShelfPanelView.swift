import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ShelfPanelView: View {
    @ObservedObject var store: ShelfStore
    @ObservedObject var theme: ShelfTheme
    @ObservedObject var state: ShelfPanelState
    /// The shelf is perch's only window, so it is also where a pending release
    /// gets to say so. Observed rather than owned: one check feeds every panel
    /// (one per display) and the menu bar item.
    @ObservedObject var update: UpdateCheck = .shared
    /// The same slot's other occupant, and the one with the better claim: while
    /// the Dock's top-edge trigger is armed, dragging to the notch does not
    /// work at all, so it outranks a pending release. Observed, not owned, for
    /// the same reason `update` is — one check feeds every panel and the menu.
    @ObservedObject var missionControl: MissionControlCheck = .shared

    let onExpand: () -> Void
    let onHide: () -> Void

    /// Clear asks first, and asks *in place*: the button becomes "Sure?" and
    /// only the second click empties the shelf.
    ///
    /// Not a `confirmationDialog`. The shelf is a transient panel that hides
    /// itself when the pointer leaves, so a modal sheet would be a dialog whose
    /// own parent can vanish out from under it — and on the notch panel that is
    /// a sheet with nowhere to sit. Two clicks on the same button needs no
    /// window, cannot be orphaned, and is the same gesture people already know
    /// from compact toolbars. (The menu bar's Clear Shelf, which has no armed
    /// state to leave on screen, raises a real alert instead — see `PerchApp`.)
    ///
    /// The rules live in `ClearConfirmation`; the timeout lives below. Note
    /// where the guards are attached: on the **root**, not on `header`. The
    /// panel is not torn down when it hides — `ShelfPanelController.hide()`
    /// only collapses it — so `header` unmounts while this state survives, and
    /// a guard mounted alongside `header` would go with it.
    @State private var clearConfirmation = ClearConfirmation()

    /// The palette this pass paints with. Published down the tree as well, for
    /// the tiles and the ember, which observe nothing else.
    private var rice: RicePalette { theme.palette }

    var body: some View {
        ZStack {
            if state.isExpanded {
                expandedShelf
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
            } else {
                collapsedShelf
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.24, extraBounce: 0.08), value: state.isExpanded)
        // Re-read the Dock on every expand. The check also listens for the
        // Dock's own prefchanged notification, but this is the path that
        // matters: someone acting on the strip walks to System Settings, flips
        // the toggle, comes back and opens the shelf — and the nudge telling
        // them to do it should already be gone. It costs one synchronous
        // cfprefsd round-trip (see MissionControlCheck.refresh) on the frame
        // the expand animation starts — measurably cheaper than the staging
        // work an expand routinely sits next to, and it runs once per expand,
        // not per frame.
        .onChange(of: state.isExpanded) { _, expanded in
            if expanded { missionControl.refresh() }
        }
        // The Clear arming's three guards, deliberately on the root rather than
        // beside the button they guard. `header` is only in the tree while the
        // panel is expanded and non-empty, but the panel is never destroyed on
        // hide — `ShelfPanelController.hide()` collapses it and leaves the
        // NSPanel ordered front — so `clearConfirmation` outlives `header` by a
        // long way. Guards mounted on `header` unmount with it: the timeout task
        // is cancelled without ever disarming, the collapse `onChange` is
        // removed by the very change it watches for, and nothing at all is
        // listening while items arrive from a paired iPhone or the Finder
        // action. Armed would then survive a collapse and greet the next
        // expansion pointed at a shelf nobody confirmed.
        .task(id: clearConfirmation.isArmed) {
            guard clearConfirmation.isArmed else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            clearConfirmation.disarm()
        }
        .onChange(of: store.items.map(\.id)) {
            clearConfirmation.revalidate(against: store.items.map(\.id))
        }
        .onChange(of: state.isExpanded) { clearConfirmation.disarm() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Perch file shelf")
        .environment(\.rice, rice)
        // AppKit's own furniture inside the panel — the staging spinner, the
        // tile context menus — follows the color scheme rather than our palette,
        // so a latte desktop must not leave dark controls behind on a light shelf.
        .preferredColorScheme(rice.isLight ? .light : .dark)
    }

    private var collapsedShelf: some View {
        // No synthetic notch, on any display: the collapsed shelf draws nothing
        // but the ember, hung under the camera housing where there is one and
        // under the menu bar where there isn't (see ShelfGeometry.topEdgeDepth).
        // An empty shelf shows nothing at all.
        //
        // The whole collapsed frame is made hit-testable with contentShape even
        // when it draws nothing: without it, SwiftUI's Color.clear reports no
        // hit, NSHostingView.hitTest returns nil, and AppKit never routes an
        // incoming drag here — so draggingEntered would never fire.
        ZStack(alignment: .top) {
            catchZone
            if hasContent {
                ShelfEmber(
                    itemCount: store.items.count,
                    isStaging: !store.pendingTransfers.isEmpty
                )
                // Clear of the top-edge furniture by a hair, so the ember hangs
                // off it instead of being clipped behind it.
                .padding(.top, state.topEdgeDepth + 4)
                .transition(.opacity.combined(with: .scale(scale: 0.5)))
            }
        }
        .animation(.snappy(duration: 0.3, extraBounce: 0.1), value: hasContent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onExpand)
    }

    // A non-opaque window derives its draggable/clickable region from rendered
    // alpha: fully transparent pixels are treated as click-through and never
    // receive draggingEntered. So while a drag might be underway (armed) the
    // catch zone is filled at the lowest alpha that still registers as a drop
    // target; when idle it is fully transparent — nothing to see, nothing to
    // catch (bar the ember itself, whose lit pixels are their own tap target).
    private var catchZone: some View {
        Color.black.opacity(state.isArmed ? catchZoneAlpha : 0)
    }

    /// Lowest fill alpha that keeps the collapsed window a valid drop target.
    private let catchZoneAlpha = 0.005

    // Square top corners so the panel reads as emerging from the top of the
    // screen; only the bottom corners are rounded.
    private static let shelfCornerRadius: CGFloat = 24
    private var shelfShape: UnevenRoundedRectangle {
        .rect(bottomLeadingRadius: Self.shelfCornerRadius, bottomTrailingRadius: Self.shelfCornerRadius)
    }

    private var expandedShelf: some View {
        ZStack {
            // cornerRadius 0: the glass is a plain rectangle; compositingGroup()
            // flattens it with the tint so the shelfShape clip actually rounds
            // the bottom (clipShape alone does not reshape an NSGlassEffectView).
            GlassBackground()
            rice.base.opacity(rice.panelTintOpacity)

            content
                .padding(.horizontal, 18)
                .padding(.top, state.hasCameraHousing ? 40 : 16)
                .padding(.bottom, 16)
        }
        .compositingGroup()
        .clipShape(shelfShape)
        .overlay {
            // Sides + bottom only — no line across the top, so the panel reads
            // as continuous with the screen edge it grows from.
            ShelfBorderShape(radius: Self.shelfCornerRadius)
                .stroke(rice.wash(0.14), lineWidth: 1)
        }
        // The window spans the full catch-zone width so expand only grows
        // downward; the glass is trimmed to its reading width and centered,
        // leaving transparent (click-through) margins on either side.
        .frame(maxWidth: state.expandedContentWidth)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            if let error = store.latestError {
                errorBanner(error)
                    .padding(10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var content: some View {
        VStack(spacing: 10) {
            if hasContent {
                header
                itemStrip
            } else {
                emptyState
            }
            if showsMissionControlStrip {
                MissionControlStrip(check: missionControl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if showsUpdateStrip {
                UpdateStrip(check: update)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.28), value: showsUpdateStrip)
        .animation(.snappy(duration: 0.28), value: showsMissionControlStrip)
    }

    /// Yields to a drag and to an error for the same reasons the update strip
    /// does — but takes the slot from the update strip when both want it, with
    /// one exception.
    ///
    /// **A live `statusNote` wins.** "Check for Updates…" in the menu bar opens
    /// the shelf precisely because the strip is where its answer lands, and that
    /// answer — "You're up to date", or the confirmation that a command was
    /// copied — is rendered by `UpdateStrip` and nowhere else. On a stock Mac
    /// this hint is showing, so without this the menu item would pop the shelf
    /// open and display something the user didn't ask about while their answer
    /// went nowhere. The note clears itself after six seconds and the hint comes
    /// straight back.
    ///
    /// A pending *release* does NOT win: a shelf that cannot catch anything is a
    /// worse problem than an available update, and the menu bar carries its own
    /// row for the release either way.
    private var showsMissionControlStrip: Bool {
        guard !state.isDropActive, store.latestError == nil else { return false }
        guard update.statusNote == nil else { return false }
        return missionControl.showsHint
    }

    /// The nudge is the lowest-priority thing on the shelf: it yields to a drag
    /// in progress (the empty shelf is a drop target then, not a noticeboard)
    /// and to an error, which occupies the same bottom edge.
    private var showsUpdateStrip: Bool {
        guard !state.isDropActive, store.latestError == nil else { return false }
        return update.pendingVersion != nil || update.statusNote != nil
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(itemCountDescription)
                .font(.body.weight(.semibold))
                .foregroundStyle(rice.text)
            Spacer(minLength: 8)
            if store.items.count > 1 {
                dragAllHandle
            }
            if !store.items.isEmpty {
                ShelfHeaderButton(
                    title: clearConfirmation.isArmed ? "Sure?" : "Clear",
                    systemImage: clearConfirmation.isArmed
                        ? "exclamationmark.triangle.fill" : "trash",
                    tint: rice.red,
                    action: {
                        if clearConfirmation.activate(itemIDs: store.items.map(\.id)) {
                            store.clear()
                        }
                    }
                )
                .accessibilityHint(
                    clearConfirmation.isArmed
                        ? "Confirms deleting every staged copy"
                        : "Deletes every staged copy. Asks once more first."
                )
            }
            ShelfHeaderButton(
                title: "Hide",
                systemImage: "chevron.up",
                action: onHide
            )
            .accessibilityHint("Dismisses the shelf until you move away and return")
        }
        .animation(.snappy(duration: 0.16), value: clearConfirmation.isArmed)
    }

    // Grabs the whole shelf at once — the popular flow. Individual tiles drag
    // only themselves; this stack handle is the "take everything" affordance,
    // shown only when there is more than one item (with one, the tile is it).
    private var dragAllHandle: some View {
        HStack(spacing: 5) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.subheadline.weight(.semibold))
            Text("Drag all \(store.items.count)")
                .font(.body.weight(.medium))
        }
        .foregroundStyle(rice.text.opacity(0.82))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(rice.wash(0.08)))
        .contentShape(Capsule())
        .overlay {
            FileDragSourceView(
                items: store.items.compactMap(exportItem(for:)),
                onExportStarted: {
                    state.isDropActive = true
                    // Collapse every tile at once; the strip empties as the
                    // stack lifts off. Pinned tiles stay put and need no grace
                    // bookkeeping because export never deletes or detaches them.
                    let exporting = Set(store.items.lazy.filter { !$0.isPinned }.map(\.id))
                    state.beginExport(of: exporting)
                    store.beginExport(of: exporting)
                },
                onExportEnded: {
                    state.isDropActive = false
                    state.startExportGrace()
                },
                onItemExportFinished: finishExport
            )
            .accessibilityLabel("Drag all \(store.items.count) items")
        }
    }

    /// Resolves a shelf item to something the drag source can vend by promise,
    /// or nil when its staged copy can't be located.
    ///
    /// This resolves rather than trusting `relativePath`, and it has to: the
    /// same pasteboard carries the plain `public.file-url` for promise-blind
    /// receivers, and a terminal that pastes a dead path has no verdict to
    /// report and nothing to undo — the grace timer hands the item off and its
    /// bytes are detached regardless. `liftForExport` is the authoritative
    /// check for *whether the tile leaves*, but only the URL vended here
    /// decides what the destination actually receives. One `fileExists` per
    /// visible item; the directory is only listed when the recorded name is
    /// already gone.
    private func exportItem(for item: ShelfItem) -> ExportItem? {
        guard let url = store.stagedURL(for: item) else { return nil }
        let fileType = item.contentTypeIdentifier
            ?? (item.kind == .folder ? UTType.folder.identifier : UTType.data.identifier)
        return ExportItem(id: item.id, url: url, fileType: fileType, fileName: item.displayName)
    }

    /// One dragged-out item's export progressed. The item leaves the shelf the
    /// moment a destination accepts it and only comes back if that destination
    /// then refuses it — never the other way round, which was the -8058
    /// data-loss bug. What becomes of the staged bytes is settled last: deleted
    /// on a confirmed copy, detached by the grace timer for a destination that
    /// took the plain file URL and reports nothing.
    private func finishExport(_ id: UUID, outcome: ExportOutcome) {
        switch outcome {
        case .accepted:
            store.liftForExport([id])
        case .promiseStarted:
            state.markPromiseEngaged(id)
        case .failed:
            state.finishExport(of: id)
            store.returnToShelf(id)
        case .copied:
            state.finishExport(of: id)
            store.confirmCopied(id)
        }
    }

    private var emptyState: some View {
        // An empty shelf only ever expands because a drag reached it (passive
        // hover is gated on having items), so this doubles as the "drop here"
        // affordance shown while a file is held over the target.
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 28, weight: .light))
            Text("Drop here")
                .font(.title3.weight(.semibold))
        }
        .foregroundStyle(state.isDropActive ? rice.text : rice.overlay0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(
                    rice.wash(state.isDropActive ? 0.35 : 0.12),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                )
                .padding(6)
        }
        .accessibilityLabel("Drop files here")
    }

    private var hasContent: Bool {
        !store.items.isEmpty || !store.pendingTransfers.isEmpty
    }

    private var itemStrip: some View {
        // spacing 0: the inter-tile gap lives inside each FileTile's horizontal
        // padding so it can collapse to zero along with the tile's width when
        // that tile is dragged out — otherwise the fixed HStack spacing would
        // leave a stranded gap where the exiting tile used to be.
        // LazyHStack, not HStack: an eager stack builds all N tiles on every
        // expand — N QuickLook tasks, N LaunchServices icon lookups and N live
        // FileDragSourceView NSViews — which is what janks the open/close
        // animation once a shelf has a couple of hundred items on it.
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 0) {
                ForEach(store.items) { item in
                    FileTile(
                        item: item,
                        fileURL: store.stagedURL(for: item),
                        exportItems: exportItem(for: item).map { [$0] } ?? [],
                        isExiting: state.draggingOutIDs.contains(item.id) && !item.isPinned,
                        onReveal: { store.reveal(item) },
                        onSave: { store.save(item) },
                        onRemove: { withAnimation(Self.reflow) { store.remove(item) } },
                        onSetPinned: { store.setPinned($0, for: item) },
                        onOpen: { store.open(item) },
                        onExportStarted: {
                            state.isDropActive = true
                            let exporting: Set<UUID> = item.isPinned ? [] : [item.id]
                            state.beginExport(of: exporting)
                            store.beginExport(of: exporting)
                        },
                        onExportEnded: {
                            state.isDropActive = false
                            state.startExportGrace()
                        },
                        onItemExportFinished: finishExport
                    )
                }
                ForEach(store.pendingTransfers) { transfer in
                    PendingTile(transfer: transfer)
                }
            }
            // The pin and remove badges straddle the thumbnail's top corners.
            // ScrollView clips anything outside its content bounds, so reserve
            // the full 8pt overhang plus a little room for their shadows.
            .padding(.top, 11)
            .padding(.bottom, 3)
            .animation(Self.reflow, value: state.draggingOutIDs)
            .animation(Self.reflow, value: store.items)
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: .infinity)
    }

    /// Shared spring for tiles sliding in/out so a drag-out reflows the strip
    /// instead of snap-shrinking it.
    private static let reflow = Animation.snappy(duration: 0.32, extraBounce: 0.12)

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(error)
                .lineLimit(2)
            Spacer()
            Button {
                store.latestError = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .font(.caption)
        .foregroundStyle(rice.onRed)
        .padding(10)
        .background(rice.red.opacity(0.88), in: RoundedRectangle(cornerRadius: 12))
    }

    private var itemCountDescription: String {
        let count = store.items.count
        return count == 1 ? "1 item" : "\(count) items"
    }
}

/// The shelf's update surface — pounce pins a palette row; perch gets one quiet
/// strip along the bottom of the open shelf.
///
/// Two shapes share the slot: a pending release (version, this install's next
/// step, the button), and the transient answer to a menu-bar "Check for
/// Updates…" that found nothing — which would otherwise be a menu item with no
/// visible effect.
///
/// What the button does depends on the install: three cohorts get their own
/// command copied, and a drag install installs it here — the hint line becomes
/// the progress of that download while it runs (see UpdateCheck). The ✕
/// dismisses this version only — the next release asks again.
private struct UpdateStrip: View {
    @ObservedObject var check: UpdateCheck

    @Environment(\.rice) private var rice

    var body: some View {
        if let pending = check.pendingVersion {
            NoticeRow {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.body)
                    .foregroundStyle(rice.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Perch \(pending) is out")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(rice.text)
                    // An install in progress outranks both; a note (a copied
                    // command, or why the last install failed) takes over from
                    // the standing hint while it's live.
                    Text(check.installPhase?.text ?? check.statusNote ?? check.installKind.actionHint)
                        .font(.caption)
                        .foregroundStyle(rice.subtext0)
                        .lineLimit(1)
                    if let fraction = check.installPhase?.progress {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .tint(rice.accent)
                            .frame(maxWidth: 180)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    check.performUpdate()
                } label: {
                    Text(check.actionButtonLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(rice.onAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(rice.accent.opacity(0.88)))
                        .contentShape(Capsule())
                        .opacity(check.installPhase == nil ? 1 : 0.45)
                }
                .buttonStyle(.plain)
                // A second click during an install would start a second
                // download; `SelfUpdate` refuses it anyway, but a live button
                // that does nothing reads as a broken one.
                .disabled(check.installPhase != nil)
                NoticeDismissButton { check.dismiss() }
                    .help("Dismiss until the next release")
            }
        } else if let note = check.statusNote {
            NoticeRow {
                Image(systemName: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(rice.overlay0)
                Text(note)
                    .font(.caption)
                    .foregroundStyle(rice.subtext0)
                    .lineLimit(1)
                Spacer(minLength: 8)
                NoticeDismissButton { check.clearNote() }
            }
        }
    }

}

/// Perch's notch tells you things in exactly one place: a quiet strip along the
/// bottom of the open shelf. Two notices share that slot — an armed Mission
/// Control trigger and a pending release — so they share its chrome too, rather
/// than drifting apart one padding value at a time.
private struct NoticeRow<Content: View>: View {
    @Environment(\.rice) private var rice
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(rice.wash(0.07), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
    }
}

private struct NoticeDismissButton: View {
    @Environment(\.rice) private var rice
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(rice.overlay0)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss")
    }
}

/// The strip that says the shelf's one gesture will not work yet.
///
/// It only ever appears on a Mac where the Dock's top-edge Mission Control
/// trigger is armed — which is every stock Mac, and no haus one. The button
/// opens System Settings ▸ Desktop & Dock rather than flipping the toggle:
/// perch reads that domain and does not write it (see `MissionControlCheck`).
///
/// The ✕ is forever, unlike the update strip's per-version wave-off, because
/// there is no later version of this to re-ask about. The menu bar keeps a row
/// that ignores the dismissal, so waving it off hides the nag without losing
/// the answer.
private struct MissionControlStrip: View {
    @ObservedObject var check: MissionControlCheck

    @Environment(\.rice) private var rice

    var body: some View {
        NoticeRow {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.body)
                .foregroundStyle(rice.accent)
            VStack(alignment: .leading, spacing: 1) {
                // Both lines have to survive `lineLimit(1)` at the NARROWEST
                // the shelf gets, and 540 is the CAP rather than that:
                // `expandedContentWidth` is
                // `min(min(screenWidth - 48, 540), collapsedWidth)`, and on a
                // notchless display `collapsedWidth` is
                // `max(300, min(screenWidth * 0.32, 460))` — so a 1280-wide
                // external is 410, not 540. Two subtractions then apply, not
                // one: `expandedShelf` pads its content 18pt a side INSIDE that
                // frame, and the row's own chrome is ~187 (10pt padding a side,
                // four 8pt gaps, the 17pt symbol, the 8pt minimum spacer,
                // "Open Settings" plus its 20pt of padding, and the 20pt ✕).
                // 410 − 36 − 187 leaves a ~186pt text column.
                //
                // Measured at the fonts SwiftUI resolves (.callout 12pt,
                // .caption 10pt): line 1 is 211pt and line 2 is 156pt. So line
                // 1 is the binding one — it wants a notchless display ≥ ~1359pt
                // wide and truncates below that, which it already did before
                // line 2 was touched — and line 2, at ≥ ~1187pt, stays well
                // inside it. Keep any rewrite of line 2 under line 1's width
                // and it can never be the one that truncates first.
                //
                // The second line names the toggle rather than only the pane it
                // is in. "Open Settings" lands on Desktop & Dock with nothing
                // selected and nothing scrolled to, and Mission Control's
                // section there holds five switches; a reader who knows only
                // "turn it off in Desktop & Dock" has to guess which. The row
                // reads "Drag windows to top of screen to enter Mission
                // Control" (read off DesktopSettings.appex, macOS 26), and it
                // is the only one in that section beginning "Drag windows to
                // top", so the truncated quote identifies it. The pane is what
                // the button walks you to; the tooltip carries both in full.
                Text("Mission Control is eating your drags")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(rice.text)
                    .lineLimit(1)
                Text("Turn off “Drag windows to top…”")
                    .font(.caption)
                    .foregroundStyle(rice.subtext0)
                    .lineLimit(1)
                    .help("Turn off “Drag windows to top of screen to enter Mission Control”, under Mission Control in System Settings ▸ Desktop & Dock.")
            }
            Spacer(minLength: 8)
            Button {
                check.openSettings()
            } label: {
                Text("Open Settings")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(rice.onAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(rice.accent.opacity(0.88)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            NoticeDismissButton { check.dismiss() }
                .help("Hide this. The menu bar keeps the reminder.")
        }
    }
}

/// Outline for the shelf: down the left side, around both bottom corners, up
/// the right side — deliberately omitting the top edge so there is no top
/// border where the panel meets the screen edge.
private struct ShelfBorderShape: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        // Inset by half a point so the 1pt stroke sits fully inside the clip.
        let r = rect.insetBy(dx: 0.5, dy: 0.5)
        let radius = min(radius, r.height)
        var path = Path()
        path.move(to: CGPoint(x: r.minX, y: r.minY))
        path.addLine(to: CGPoint(x: r.minX, y: r.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: r.minX + radius, y: r.maxY),
            control: CGPoint(x: r.minX, y: r.maxY)
        )
        path.addLine(to: CGPoint(x: r.maxX - radius, y: r.maxY))
        path.addQuadCurve(
            to: CGPoint(x: r.maxX, y: r.maxY - radius),
            control: CGPoint(x: r.maxX, y: r.maxY)
        )
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return path
    }
}

/// A readable, comfortably-tappable pill button for the shelf header.
private struct ShelfHeaderButton: View {
    let title: String
    let systemImage: String
    /// nil means "the palette's label color" — only the destructive button
    /// names a tint of its own.
    var tint: Color?
    let action: () -> Void

    @Environment(\.rice) private var rice
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                Text(title)
                    .font(.body.weight(.medium))
            }
            .foregroundStyle((tint ?? rice.text).opacity(hovering ? 1 : 0.82))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(rice.wash(hovering ? 0.16 : 0.08))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
    }
}

private struct FileTile: View {
    let item: ShelfItem
    let fileURL: URL?
    let exportItems: [ExportItem]
    // While true the tile is mid drag-out: it collapses to zero width so the
    // neighbouring tiles slide in, but stays mounted so its FileDragSourceView
    // survives to receive the drop result. See ShelfPanelState.draggingOutIDs.
    var isExiting: Bool = false
    let onReveal: () -> Void
    let onSave: () -> Void
    let onRemove: () -> Void
    let onSetPinned: (Bool) -> Void
    let onOpen: () -> Void
    let onExportStarted: () -> Void
    let onExportEnded: () -> Void
    let onItemExportFinished: (UUID, ExportOutcome) -> Void

    @Environment(\.rice) private var rice

    // Half the inter-tile gap on each side sums to the strip's 14pt spacing;
    // living inside the tile means it collapses to zero with the tile on exit.
    private static let sideInset: CGFloat = 7
    private static let tileWidth: CGFloat = 108
    private static let previewSize: CGFloat = 96

    var body: some View {
        card
            .padding(.horizontal, isExiting ? 0 : Self.sideInset)
            .frame(width: isExiting ? 0 : nil)
            .scaleEffect(isExiting ? 0.6 : 1, anchor: .center)
            .opacity(isExiting ? 0 : 1)
            // Contain the shrinking tile so it never bleeds over its neighbours,
            // but only while exiting — at rest the clip region is expanded so the
            // remove badge can still overhang the corner. Parameterising one clip
            // (rather than branching with `if`) keeps the subtree — and its live
            // FileDragSourceView — mounted for the whole drag.
            .clipShape(CollapseClip(collapsed: isExiting))
    }

    private var card: some View {
        VStack(spacing: 8) {
            FilePreview(
                fileURL: fileURL,
                kind: item.kind,
                contentType: item.contentType,
                size: Self.previewSize
            )
            Text(item.displayName)
                .font(.callout)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.center)
                .frame(width: 104)

            sizeLabel
        }
        .frame(width: Self.tileWidth)
        .overlay {
            FileDragSourceView(
                items: exportItems,
                onExportStarted: onExportStarted,
                onExportEnded: onExportEnded,
                onItemExportFinished: onItemExportFinished,
                onOpen: onOpen,
                badgeCornerSize: 34
            )
            .accessibilityLabel("Drag \(item.displayName)")
        }
        // The controls straddle the preview's corners instead of floating at
        // the wider tile edges. SwiftUI overlay order alone doesn't make them
        // clickable over the drag source's real NSView — see the
        // badgeCornerSize hit-test carve-out on FileDragSourceView above.
        .overlay(alignment: .top) {
            HStack(spacing: 0) {
                pinButton
                    .offset(x: -8, y: -8)
                Spacer(minLength: 0)
                removeButton
                    .offset(x: 8, y: -8)
            }
            .frame(width: Self.previewSize)
        }
        .foregroundStyle(rice.text)
        .contextMenu {
            Button(item.kind == .image ? "Quick Look" : "Open", action: onOpen)
            Button("Show in Finder", action: onReveal)
            // Copies out and leaves the tile alone, unlike a drag-out — so it
            // sits with the other non-destructive rows, above the divider.
            Button("Save to…", action: onSave)
            Divider()
            Button(
                item.isPinned ? "Unpin" : "Pin",
                systemImage: item.isPinned ? "pin.slash" : "pin"
            ) {
                onSetPinned(!item.isPinned)
            }
            Button("Remove from Shelf", role: .destructive, action: onRemove)
        }
    }

    private var pinButton: some View {
        Button {
            onSetPinned(!item.isPinned)
        } label: {
            Image(systemName: item.isPinned ? "pin.fill" : "pin")
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                // Pinned wears the shelf's accent — its own mark color, the same
                // one the ember burns — rather than the *system* accent, which
                // is the one color on the panel haus doesn't pick.
                .foregroundStyle(item.isPinned ? rice.onAccent : rice.text.opacity(0.72))
                .frame(width: 24, height: 24)
                .background(
                    Circle().fill(
                        item.isPinned
                            ? rice.accent.opacity(0.88)
                            : rice.crust.opacity(0.62)
                    )
                )
                .shadow(color: rice.shadow(0.4), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .help(item.isPinned ? "Unpin after repeated drops" : "Keep on shelf after dragging out")
        .accessibilityLabel(
            item.isPinned ? "Unpin \(item.displayName)" : "Pin \(item.displayName)"
        )
        .accessibilityHint(
            item.isPinned
                ? "The item will leave the shelf after its next successful drag"
                : "Keeps the item on the shelf after successful drags"
        )
    }

    private var removeButton: some View {
        Button(action: onRemove) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 22))
                .symbolRenderingMode(.palette)
                .foregroundStyle(rice.text, rice.crust.opacity(0.62))
                .shadow(color: rice.shadow(0.4), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel("Remove \(item.displayName)")
    }

    @ViewBuilder private var sizeLabel: some View {
        if let byteCount = item.byteCount {
            Text(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
                .font(.footnote)
                .foregroundStyle(rice.subtext0)
        } else {
            Text(item.kind == .folder ? "Folder" : "Item")
                .font(.footnote)
                .foregroundStyle(rice.subtext0)
        }
    }
}

/// A clip that tightens to the view's bounds only while `collapsed`, and
/// otherwise expands well past them so nothing is cut at rest. Being a single
/// parameterised `Shape` (not an `if`-branch), it never changes view identity —
/// so the tile's live `FileDragSourceView` survives the whole drag session.
private struct CollapseClip: Shape {
    var collapsed: Bool

    func path(in rect: CGRect) -> Path {
        Path(collapsed ? rect : rect.insetBy(dx: -200, dy: -200))
    }
}

private struct PendingTile: View {
    let transfer: PendingTransfer

    @Environment(\.rice) private var rice

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(rice.wash(0.06))
                ProgressView()
                    .controlSize(.small)
            }
            .frame(width: 62, height: 62)
            Text(transfer.displayName)
                .font(.footnote)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.center)
                .frame(width: 104)
            Text(phaseLabel)
                .font(.caption)
                .foregroundStyle(rice.subtext0)
        }
        .foregroundStyle(rice.text)
        .frame(width: 108)
        .accessibilityElement(children: .combine)
    }

    private var phaseLabel: String {
        switch transfer.phase {
        case .waitingForSource: "Receiving"
        case let .downloadingFromCloud(elapsed):
            elapsed < 3 ? "Downloading" : "Downloading \(elapsed)s"
        case .copying: "Staging"
        }
    }
}

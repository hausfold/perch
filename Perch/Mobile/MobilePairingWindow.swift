import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The window the Mac shows while a phone is being paired: the QR code, the
/// same payload as a copyable line for camera-less pairing, and — once a phone
/// knocks — the six-digit confirmation ask.
@MainActor
final class MobilePairingWindowController: NSWindowController, NSWindowDelegate {
    static let shared = MobilePairingWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pair a Device"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("unavailable")
    }

    func present(receiver: MobileReceiver) {
        receiver.openPairingWindow()
        window?.contentView = NSHostingView(rootView: MobilePairingView(receiver: receiver))
        window?.center()
        showWindow(nil)
        // Perch is an accessory app; without this the window opens behind
        // whatever has focus.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        AppRuntime.shared.mobile.closePairingWindow()
    }
}

struct MobilePairingView: View {
    @ObservedObject var receiver: MobileReceiver

    var body: some View {
        VStack(spacing: 16) {
            if let approval = receiver.pendingApproval {
                approvalContent(approval)
            } else if let window = receiver.pairingWindow {
                offerContent(window)
            } else {
                // The pairing finished (or was closed elsewhere); nothing to
                // show but the outcome.
                Text(receiver.lastEvent ?? "Pairing finished.")
                    .font(.title3)
                    .padding(40)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    @ViewBuilder
    private func offerContent(_ window: MobileReceiver.PairingWindow) -> some View {
        Text("Pair an iPhone or iPad")
            .font(.title2.weight(.semibold))
        Text("Open Perch on the phone, tap **Pair a Mac**, and point it at this code. Both screens will then show the same six digits.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

        if let qr = Self.qrImage(for: window.encodedOffer) {
            Image(nsImage: qr)
                .interpolation(.none)
                .resizable()
                .frame(width: 240, height: 240)
                .accessibilityLabel("Pairing QR code")
        }

        Link("Don't have it yet? Get Perch Companion — free on the App Store",
             destination: Self.companionAppStoreURL)
            .font(.caption)

        VStack(spacing: 6) {
            Text("No camera handy? Paste this into the phone instead:")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(window.encodedOffer.prefix(28) + "…")
                    .font(.caption.monospaced())
                    .lineLimit(1)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(window.encodedOffer, forType: .string)
                }
                .controlSize(.small)
            }
        }
        Text("This code works once and dies with this window.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private func approvalContent(_ approval: MobileReceiver.PairingApproval) -> some View {
        Text("“\(approval.deviceName)” wants to pair")
            .font(.title2.weight(.semibold))
        Text("Approve only if the phone shows these same six digits.")
            .font(.callout)
            .foregroundStyle(.secondary)
        Text(approval.code)
            .font(.system(size: 44, weight: .bold, design: .monospaced))
            .kerning(6)
            .padding(.vertical, 12)
        HStack(spacing: 12) {
            Button("Decline") {
                receiver.answerApproval(approval, approved: false)
            }
            .keyboardShortcut(.cancelAction)
            Button("Approve") {
                receiver.answerApproval(approval, approved: true)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
    }

    /// The short `/app/id<id>` form on purpose: it redirects to the viewer's
    /// own storefront and survives a rename of the listing, which the
    /// slug-bearing URL App Store Connect hands you does not.
    nonisolated static let companionAppStoreURL =
        URL(string: "https://apps.apple.com/app/id6799443735")!

    private static func qrImage(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

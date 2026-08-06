import SwiftUI
import VisionKit

/// Pairing, from the phone's side: scan the Mac's QR (or paste its code),
/// then match six digits. The heavy lifting is `MobileAppModel.pair`.
struct PairMacView: View {
    @ObservedObject var model: MobileAppModel
    @Environment(\.dismiss) private var dismiss

    @State private var pastedCode = ""
    @State private var showingScanner = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Pair a Mac")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            model.resetPairing()
                            dismiss()
                        }
                    }
                }
        }
        .interactiveDismissDisabled(model.pairingPhase != .idle)
        .onChange(of: model.pairingPhase) { _, phase in
            // Pairing succeeded — the sheet's work is done.
            if phase == .idle, model.pairedMacName != nil {
                dismiss()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.pairingPhase {
        case .idle:
            entry
        case .searching:
            VStack(spacing: 16) {
                ProgressView()
                Text("Looking for your Mac…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .confirming(code):
            VStack(spacing: 16) {
                Text("Do the digits match?")
                    .font(.title2.weight(.semibold))
                Text("Your Mac is showing six digits. Confirm only if they're these:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(code)
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
                    .kerning(6)
                HStack(spacing: 12) {
                    Button("No") { model.answerConfirmation(false) }
                    Button("They Match") { model.answerConfirmation(true) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(reason):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(reason)
                    .multilineTextAlignment(.center)
                Button("Try Again") { model.resetPairing() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var entry: some View {
        Form {
            Section {
                Text("On your Mac, choose **Pair a Device…** from Perch's menu bar icon.")
                    .font(.callout)
            }
            if DataScannerViewController.isSupported {
                Section {
                    Button {
                        showingScanner = true
                    } label: {
                        Label("Scan the QR Code", systemImage: "qrcode.viewfinder")
                    }
                }
                .sheet(isPresented: $showingScanner) {
                    QRScannerView { scanned in
                        showingScanner = false
                        model.pair(with: scanned)
                    }
                }
            }
            Section("Or paste the code") {
                TextField("perch-pair:…", text: $pastedCode, axis: .vertical)
                    .font(.caption.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Pair") {
                    model.pair(with: pastedCode)
                }
                .disabled(pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

/// The thinnest possible VisionKit wrapper: report the first QR payload seen.
private struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        private var reported = false

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(
            _ scanner: DataScannerViewController,
            didAdd added: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !reported else { return }
            for case let .barcode(barcode) in added {
                if let payload = barcode.payloadStringValue {
                    reported = true
                    onScan(payload)
                    return
                }
            }
        }
    }
}

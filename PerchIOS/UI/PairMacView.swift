import SwiftUI
import VisionKit

/// Pairing, from the phone's side: scan the Mac's QR (or paste its code),
/// then match six digits. The heavy lifting is `MobileAppModel.pair`.
struct PairMacView: View {
    @ObservedObject var model: MobileAppModel
    @Environment(\.dismiss) private var dismiss

    @State private var pastedCode = ""
    @State private var showingScanner = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            } else if phase != .idle {
                UIAccessibility.post(notification: .screenChanged, argument: nil)
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
                MotionAwareProgressView(accessibilityLabel: "Looking for your Mac")
                Text("Looking for your Mac…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .awaitingMacApproval(code):
            VStack(spacing: 16) {
                Text("Now approve on your Mac")
                    .font(.title2.weight(.semibold))
                Text("Your Mac is asking for permission and showing these digits:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                verificationCode(code)
                MotionAwareProgressView(accessibilityLabel: "Waiting for Mac approval")
                Text("If your Mac shows different digits, cancel — someone else may be pairing.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
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
                    NavigationStack {
                        ZStack(alignment: .bottom) {
                            QRScannerView(
                                highlightsCodes: !reduceMotion
                            ) { scanned in
                                showingScanner = false
                                model.pair(with: scanned)
                            }
                            Text("Point your iPhone at the QR code shown by Perch on your Mac.")
                                .font(.callout)
                                .multilineTextAlignment(.center)
                                .padding()
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                                .padding()
                        }
                        .navigationTitle("Scan QR Code")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { showingScanner = false }
                            }
                        }
                    }
                }
            }
            Section("Or paste the code") {
                TextField("perch-pair:…", text: $pastedCode, axis: .vertical)
                    .font(.caption.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel("Pairing code")
                    .accessibilityInputLabels(["Pairing code", "Code"])
                Button("Pair") {
                    model.pair(with: pastedCode)
                }
                .disabled(pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func verificationCode(_ code: String) -> some View {
        ViewThatFits(in: .horizontal) {
            Text(code)
                .kerning(6)
            VStack(spacing: 4) {
                Text(String(code.prefix(3)))
                    .kerning(6)
                Text(String(code.dropFirst(3)))
                    .kerning(6)
            }
        }
        .font(.system(.largeTitle, design: .monospaced, weight: .bold))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Verification code")
        .accessibilityValue(code.map(String.init).joined(separator: " "))
    }
}

/// The thinnest possible VisionKit wrapper: report the first QR payload seen.
private struct QRScannerView: UIViewControllerRepresentable {
    let highlightsCodes: Bool
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            isHighlightingEnabled: highlightsCodes
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

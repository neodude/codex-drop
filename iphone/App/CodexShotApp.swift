import SwiftUI
import VisionKit
import AVFoundation

@main struct CodexShotApp: App {
    var body: some Scene { WindowGroup { PairingView() } }
}

struct PairingView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var timings: [String: Int] = [:]
    @State private var pairing: Pairing?
    @State private var status = "Start the iPhone receiver on your Mac, then scan its QR code."
    @State private var scanning = false
    @State private var busy = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(pairing == nil ? "Pair your Mac" : "Mac paired", systemImage: "desktopcomputer")
                        .font(.headline)
                    Text(status).foregroundStyle(.secondary)
                    if busy { ProgressView() }
                }
                Section("One-time setup") {
                    Button("Scan Mac QR code", systemImage: "qrcode.viewfinder") { Task { await startScanner() } }
                        .disabled(busy || !DataScannerViewController.isSupported)
                    PasteButton(payloadType: String.self) { strings in
                        if let text = strings.first { Task { await pair(text) } }
                    }.disabled(busy)
                    if pairing != nil {
                        Button("Check connection") { Task { await check() } }.disabled(busy)
                        Button("Forget Mac", role: .destructive) {
                            do { try PairingStore.remove(); pairing = nil; status = "Scan your Mac to pair again." }
                            catch { status = error.localizedDescription }
                        }.disabled(busy)
                    }
                }
                Section("Share images") {
                    Text("Leave the intended Codex composer focused on your Mac. On iPhone, select 1–10 images and choose Share → Codex Drop. Images upload in order, then attach together; the message stays unsent.")
                    Text("Use the same Wi-Fi. Allow Local Network access when asked. Add Codex Drop to your share-sheet favourites for quick access.").foregroundStyle(.secondary)
                }
                if !timings.isEmpty {
                    Section("Last share timing") {
                        ForEach(["Preparing images", "Finding Mac", "Upload", "Confirmation", "Total"], id: \.self) { phase in
                            if let milliseconds = timings[phase] {
                                LabeledContent(phase, value: String(format: "%.2f s", Double(milliseconds) / 1000))
                            }
                        }
                    }
                }
            }
            .navigationTitle("Codex Drop")
            .sheet(isPresented: $scanning) {
                Scanner { value in scanning = false; Task { await pair(value) } }
                    .ignoresSafeArea()
            }
            .task {
                timings = PairingStore.loadTiming()
                do { pairing = try PairingStore.load(); if pairing != nil { status = "Paired. Use Check connection to confirm the Mac is reachable." } }
                catch { status = error.localizedDescription }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { timings = PairingStore.loadTiming() }
            }
        }
    }
    private func startScanner() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            status = "Allow Camera access for Codex Drop in Settings, or paste the pairing code."; return
        }
        guard DataScannerViewController.isAvailable else {
            status = "Camera scanning is unavailable. Close other camera apps or paste the pairing code."; return
        }
        scanning = true
    }
    private func pair(_ text: String) async {
        busy = true; defer { busy = false }
        do {
            let value = try Pairing.parse(text)
            status = "Finding your Mac… Allow Local Network access if asked."
            let client = ReceiverClient(pairing: value); defer { client.close() }
            try await client.checkConnection(); try PairingStore.save(value)
            pairing = value; status = "Connected. Share images to Codex Drop whenever its Mac composer is focused."
        } catch { status = error is ReceiverError ? error.localizedDescription : "Could not connect. Check Wi-Fi, the Mac receiver and Local Network permission, then scan again." }
    }
    private func check() async {
        guard let pairing else { return }
        busy = true; defer { busy = false }
        let client = ReceiverClient(pairing: pairing); defer { client.close() }
        do { try await client.checkConnection(); status = "Mac connected. No image or message was sent." }
        catch { status = "Mac unavailable. Check the receiver, Wi-Fi and Local Network permission." }
    }
}

struct Scanner: UIViewControllerRepresentable {
    var found: @MainActor (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(found: found) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
            recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isPinchToZoomEnabled: true,
            isGuidanceEnabled: true, isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }
    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) { controller.stopScanning() }
    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var found: (String) -> Void; var handled = false
        init(found: @escaping (String) -> Void) { self.found = found }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !handled else { return }
            for case let .barcode(code) in addedItems {
                if let value = code.payloadStringValue, value.hasPrefix("codexshot://pair?") {
                    handled = true; dataScanner.stopScanning(); found(value); return
                }
            }
        }
    }
}

import SwiftUI

/// Presentation only. The app owns pairing, camera, clipboard and network access.
struct PairingContentView<PasteControl: View>: View {
    let isPaired: Bool
    let status: String
    let busy: Bool
    let canScan: Bool
    let timings: [String: Int]
    let scan: () -> Void
    let check: () -> Void
    let forget: () -> Void
    let pasteControl: PasteControl
    @State private var confirmingForget = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image("DropMark")
                            .resizable().scaledToFit().frame(width: 60, height: 60)
                            .accessibilityHidden(true)
                        Text("Codex Drop").font(.largeTitle.weight(.bold))
                        Text("From your phone to your draft.")
                            .font(.body).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                }
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(isPaired ? "Mac paired" : "Pair your Mac",
                              systemImage: isPaired ? "checkmark.circle.fill" : "desktopcomputer")
                            .font(.headline)
                            .foregroundStyle(isPaired ? Color(uiColor: DropBrand.accent) : .primary)
                        Text(status).foregroundStyle(.secondary)
                        if busy { ProgressView().accessibilityLabel("Connecting to your Mac") }
                    }
                    .padding(.vertical, 4)
                    if isPaired {
                        Button(action: check) { Label("Check connection", systemImage: "arrow.triangle.2.circlepath") }
                            .disabled(busy)
                    }
                }
                Section {
                    Button(action: scan) { Label("Scan Mac QR code", systemImage: "qrcode.viewfinder") }
                        .disabled(busy || !canScan)
                    // The system paste control uses a white label on its tint.
                    // Keep the filled control's indigo dark enough in both appearances.
                    pasteControl.disabled(busy)
                        .tint(Color(uiColor: DropBrand.filledAccent))
                    if isPaired {
                        Button("Forget pairing", role: .destructive) { confirmingForget = true }
                            .disabled(busy)
                    }
                } header: {
                    Text(isPaired ? "Pairing" : "One-time setup")
                } footer: {
                    if !isPaired { Text("Find the pairing QR code in Codex Drop on your Mac. You can also paste its pairing code.") }
                }
                Section("Share images and videos") {
                    Label {
                        Text("Select 1–10 images or videos on your iPhone, then choose Share → Codex Drop.")
                    } icon: { Image(systemName: "square.and.arrow.up") }
                    Text("Codex opens on your Mac and the files attach to the current draft.")
                    Text("Keep your Mac awake and unlocked, with Codex Drop running. Use the same Wi-Fi and allow Local Network access when asked.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    Text("Add Codex Drop to your share-sheet favourites for quick access.")
                        .foregroundStyle(.secondary)
                }
                if !timings.isEmpty {
                    Section("Last share timing") {
                        ForEach(["Preparing images", "Finding Mac", "Upload", "Confirmation", "Total"], id: \.self) { phase in
                            if let milliseconds = timings[phase] {
                                LabeledContent(phase == "Preparing images" ? "Preparing files" : phase, value: String(format: "%.2f s", Double(milliseconds) / 1000))
                            }
                        }
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .tint(Color(uiColor: DropBrand.accent))
            .confirmationDialog("Forget this Mac?", isPresented: $confirmingForget, titleVisibility: .visible) {
                Button("Forget pairing", role: .destructive, action: forget)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You’ll need to scan or paste its pairing code before sharing again.")
            }
        }
    }
}

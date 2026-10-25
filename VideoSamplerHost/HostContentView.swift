import AppKit
import SwiftUI

struct HostContentView: View {
    @State private var isOpeningLogic = false
    @State private var logicLaunchError: String?

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)

            VStack(spacing: 7) {
                Text("Video Sampler")
                    .font(.system(size: 30, weight: .black, design: .rounded))
                Text("AUv3 Instrument for Fingersonic Beats")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 11) {
                Label("The Audio Unit is included with this app.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Open Logic Pro, create a Software Instrument track, then choose:")
                Text("AU Instruments → Fingersonic → Video Sampler")
                    .font(.system(.body, design: .monospaced).bold())
                Text("Choose a video for each pad inside the plug-in. MIDI triggers its audio directly in Logic for recording or bouncing.")
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 13))

            Button("Open Logic Pro") {
                openLogicPro()
            }
            .buttonStyle(.borderedProminent)
            .disabled(isOpeningLogic)
        }
        .padding(36)
        .alert("Unable to open Logic Pro", isPresented: Binding(
            get: { logicLaunchError != nil },
            set: { if !$0 { logicLaunchError = nil } }
        )) {
            Button("OK", role: .cancel) { logicLaunchError = nil }
        } message: {
            Text(logicLaunchError ?? "")
        }
    }

    private func openLogicPro() {
        let workspace = NSWorkspace.shared
        // Logic Pro and Logic Pro Creator Studio use different bundle IDs.
        // Launch Services also resolves renamed apps and non-default locations.
        let identifiers = ["com.apple.logic10", "com.apple.mobilelogic"]
        guard let applicationURL = identifiers.lazy.compactMap({
            workspace.urlForApplication(withBundleIdentifier: $0)
        }).first else {
            logicLaunchError = "Logic Pro was not found on this Mac. Install Logic Pro or Logic Pro Creator Studio, open it once, then try again. You can also open Logic yourself and load Video Sampler from its Instrument slot."
            return
        }

        isOpeningLogic = true
        workspace.openApplication(
            at: applicationURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            Task { @MainActor in
                isOpeningLogic = false
                if let error {
                    logicLaunchError = error.localizedDescription
                }
            }
        }
    }
}

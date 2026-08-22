import SwiftUI

/// Settings pane for the privileged fan helper: what it is, whether it is
/// installed, and one button each way. Installing asks macOS for administrator
/// rights once; afterwards fan changes apply silently.
struct HelperSettingsView: View {
    @EnvironmentObject private var state: AppState

    @State private var isInstalled = HelperInstaller.isInstalled
    @State private var isOutdated = HelperInstaller.isOutdated
    @State private var isWorking = false
    @State private var message: String?
    @State private var isError = false
    @State private var confirmUninstall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusRow
            Divider()
            explanation
            Spacer(minLength: 0)
            if let message {
                Label(message, systemImage: isError ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(isError ? Theme.critical : Theme.ok)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
        .padding()
        .onAppear { refreshStatus() }
        .confirmationDialog("Remove the fan helper?",
                            isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button("Remove Helper", role: .destructive) { uninstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All fans return to automatic control first. You can install it again at any time.")
        }
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .font(.system(size: 22))
                .foregroundStyle(statusTint)
            VStack(alignment: .leading, spacing: 1) {
                Text(statusTitle).font(.system(size: 13, weight: .semibold))
                Text(statusDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private var statusIcon: String {
        if isOutdated { return "exclamationmark.shield.fill" }
        return isInstalled ? "checkmark.shield.fill" : "shield.slash"
    }

    private var statusTint: Color {
        if isOutdated { return Theme.warning }
        return isInstalled ? Theme.ok : Theme.textMuted
    }

    private var statusTitle: String {
        if isOutdated { return "Helper needs updating" }
        return isInstalled ? "Helper installed" : "Helper not installed"
    }

    private var statusDetail: String {
        if isOutdated {
            return "The installed helper is from an older build. Background fan control is paused until you update it; changes still work but ask for a password."
        }
        return isInstalled
            ? "Fan changes apply instantly, no password needed."
            : "Fan changes ask for your password every time."
    }

    private func refreshStatus() {
        isInstalled = HelperInstaller.isInstalled
        isOutdated = HelperInstaller.isOutdated
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("The helper is a small tool that can read and write only the SMC's fan keys — nothing else. It is copied to a root-owned folder so TidyMac can adjust fans in the background, which is what makes sensor-based rules work while you use the Mac.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(HelperInstaller.installedPath)
                .font(.system(size: 10))
                .monospaced()
                .foregroundStyle(Theme.textMuted)
                .textSelection(.enabled)
            Text("macOS will ask for an administrator password once, in its own dialog. TidyMac never sees it.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button {
                install()
            } label: {
                if isWorking {
                    HStack(spacing: 7) {
                        SpinnerRing(size: 12, lineWidth: 2, color: .white)
                        Text("Working…")
                    }
                } else {
                    Text(isOutdated ? "Update Helper…"
                         : isInstalled ? "Reinstall Helper…" : "Install Helper…")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking)

            if isInstalled {
                Button("Remove Helper…") { confirmUninstall = true }
                    .disabled(isWorking)
            }
            Spacer()
        }
    }

    // MARK: - Actions

    private func install() {
        isWorking = true
        message = nil
        Task.detached(priority: .userInitiated) {
            var failure: String?
            do { try HelperInstaller.install() }
            catch { failure = "\(error)" }
            let installed = HelperInstaller.isInstalled
            await MainActor.run { finish(failure: failure, installed: installed, verb: "installed") }
        }
    }

    private func uninstall() {
        // Hand the fans back while we still have a working helper, otherwise
        // they would stay pinned with nothing able to change them.
        state.fanControl.resetAll()
        isWorking = true
        message = nil
        Task.detached(priority: .userInitiated) {
            var failure: String?
            do { try HelperInstaller.uninstall() }
            catch { failure = "\(error)" }
            let installed = HelperInstaller.isInstalled
            await MainActor.run { finish(failure: failure, installed: installed, verb: "removed") }
        }
    }

    private func finish(failure: String?, installed: Bool, verb: String) {
        isWorking = false
        refreshStatus()
        if let failure {
            // Dismissing the authentication dialog is a choice, not a failure.
            if failure.contains("-128") {
                message = "Cancelled — nothing was changed"
                isError = false
            } else {
                message = "Couldn't finish: \(failure.prefix(120))"
                isError = true
            }
        } else {
            message = "Helper \(verb)"
            isError = false
        }
    }
}

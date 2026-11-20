import AppKit
import SubsetCore
import SwiftUI

/// The Command Line section below the app list: whether `subset` is on the PATH and its version, the one-line setup,
/// and an example for each command an installed app bundles, each with a Copy button, and a link to its agent
/// instructions. The app never runs the setup itself.
struct CommandLineSection: View {
    @ObservedObject var model: CommandLineModel
    @ObservedObject var helpers: HelperExamplesModel

    /// Whether the `subset` found predates the bundled commands, so it runs none of the examples from the app.
    private var launcherPredatesCommands: Bool {
        if case .installed(let version) = model.status { return HelperExamples.predatesBundledCommands(version) }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Command Line").font(.headline)
                status
                Spacer()
                Button("Check Again") { Task { await model.check() } }
                    .controlSize(.small)
                    .disabled(model.isChecking)
                    .help("Look for subset in your login shell again")
            }
            copyLine("Set up:", HelperExamples.setupCommand, help: "Installs the subset command with npm (needs Node.js)")
            if case .installed(let version) = model.status, !helpers.examples.isEmpty, launcherPredatesCommands {
                note("The commands below need subset \(HelperExamples.minimumLauncherVersion) or later. subset \(version) runs Timer and Minutes from npm, not from the app, and knows no other command below")
            }
            ForEach(helpers.examples) { example in
                HStack(spacing: 8) {
                    copyLine("\(example.appName):", example.example, help: "subset runs the command \(example.appName) bundles once it has checked its signature")
                    Link("Agent instructions", destination: example.guide)
                        .font(.caption)
                        .help("Open the instructions for agents in the README")
                }
                // An older subset runs no command from the app, so what the app holds does not matter to it.
                if example.missingFromCopy, !launcherPredatesCommands {
                    note(example.npmFallback
                        ? "This copy of \(example.appName) does not include it, so subset runs the npm package instead, downloading it if needed"
                        : "This copy of \(example.appName) does not include it: update \(example.appName) first")
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Unstructured, so closing the window does not cut a check short; a check already running is not repeated.
        .onAppear { Task { await model.check() } }
    }

    @ViewBuilder
    private var status: some View {
        switch model.status {
        case .checking:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Checking for subset…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .installed(let version):
            Label("subset \(version) is on your PATH", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
                .textSelection(.enabled)
        case .notInstalled:
            Label("subset is not installed", systemImage: "minus.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Not found on your login shell's PATH within 5 seconds")
        }
    }

    private func note(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
    }

    private func copyLine(_ label: String, _ command: String, help: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled).help(help)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            .controlSize(.small)
            .accessibilityLabel("Copy \(command)")
        }
    }
}

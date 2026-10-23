import SwiftUI
import SystemCore

/// Explain for one item: asks to choose a provider when there is none, starts and shows the explanation, shows the
/// send preview for each request off this Mac until one confirmed this session has been answered, and says why it failed, the provider is unavailable,
/// or the choice was set back. Every answer is shown as plain text (`Text(verbatim:)`), never as Markdown or anything
/// run.
struct ExplainPanel: View {
    let center: ExplainCenter
    let key: ExplainKey
    let request: (ExplainRedactor) -> ExplainRequest?
    let openSettings: () -> Void
    /// Starts as soon as it is shown, as the Disk section's Explain sheet does.
    var startsAtOnce = false
    /// The send preview is open: it opens when the item starts waiting for it, and closes once it no longer does.
    @State private var showingPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice = center.notice {
                Text(verbatim: notice).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            switch center.state(for: key) {
            case .needsProvider:
                Text("Explain needs an AI provider. System works fully without one; choose one in Settings.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings…", action: openSettings)
            case .idle:
                Button("Explain", action: start)
                    .help("Explain what this is and how to remove it, with \(center.choice.title)")
            case .working:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Explaining with \(center.choice.title)…").foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            case let .confirming(preview):
                Text("Until \(preview.provider.title) has answered a request you confirmed this session, review each "
                    + "one exactly as it will be sent.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Review and Send…") { showingPreview = true }
            case let .explained(explanation, request):
                ExplanationView(explanation: explanation, sent: center.sentText(for: key) ?? request.promptText,
                                provider: center.choice)
            case let .unavailable(availability):
                Text(availability.title).bold()
                Text(availability.meaning).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Try Again", action: start)
            case let .failed(message, _):
                Text(verbatim: message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Button("Try Again", action: start)
            case .gone:
                Text("This item is no longer in the sample or scan, so nothing was sent.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again", action: start)
            }
        }
        .task(id: key) { if startsAtOnce { start() } }
        .onChange(of: preview, initial: true) { _, preview in showingPreview = preview != nil }
        .sheet(isPresented: $showingPreview) {
            if let preview {
                SendPreviewSheet(preview: preview) {
                    showingPreview = false
                    Task { await center.confirmSend(key) }
                } cancel: {
                    showingPreview = false
                    center.cancelSend(key)
                }
            }
        }
    }

    private var preview: SendPreview? {
        if case let .confirming(preview) = center.state(for: key) { preview } else { nil }
    }

    private func start() {
        // Not tied to the view: an answer that comes in after the selection changed is still kept for the session.
        Task { await center.explain(key, request: request) }
    }
}

private struct ExplanationView: View {
    let explanation: Explanation
    /// Exactly what was sent: OpenRouter's JSON body, or the prompt given to the on-device model.
    let sent: String
    let provider: AIProviderChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: explanation.summary).font(.headline)
            HStack(spacing: 8) {
                Badge(text: explanation.removalSafety.title, color: safetyColor)
                Text("Confidence: \(explanation.confidence.title)").font(.caption).foregroundStyle(.secondary)
            }
            if let origin = explanation.suggestedOrigin {
                HStack(spacing: 6) {
                    Text("Origin:").foregroundStyle(.secondary)
                    Text(verbatim: origin)
                    Badge(text: "Suggested", color: .purple)
                }
                .accessibilityElement(children: .combine)
                Text("Suggested by \(provider.title). System's own grouping is unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            section("What it is", explanation.whatItIs)
            section("How to remove it", explanation.howToRemove)
            Text("Generated by \(provider.title); it can be wrong. Check before removing anything.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("What was sent") {
                Text(verbatim: sent)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
        }
        .textSelection(.enabled)
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.bold())
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var safetyColor: Color {
        switch explanation.removalSafety {
        case .likelySafe: .green
        case .review: .orange
        case .unsafe: .red
        case .unknown: .secondary
        }
    }
}

private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.2)))
            .foregroundStyle(color)
    }
}

/// Settings: the Explain provider (OpenRouter only while its key is stored), its availability, why the choice was set
/// back, Send folder names, exactly which fields Explain sends, and the OpenRouter key and model.
struct SettingsView: View {
    @Bindable var center: ExplainCenter
    let openRouter: OpenRouterAccount

    var body: some View {
        Form {
            Section("Explain with AI") {
                Picker("Provider", selection: Binding(get: { center.choice }, set: { center.choose($0) })) {
                    ForEach(AIProviderChoice.allCases, id: \.self) { choice in
                        Text(choice.title).tag(choice).selectionDisabled(!center.canChoose(choice))
                    }
                }
                Text(center.choice.detail).foregroundStyle(.secondary)
                if let notice = center.notice {
                    Text(verbatim: notice).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if let reason = center.openRouterUnavailableReason {
                    Text(reason)
                        .font(.caption).foregroundStyle(.secondary)
                }
                if center.choice != .none {
                    LabeledContent("Status") {
                        switch center.availabilityStatus {
                        case .checking?:
                            Text("Checking…").foregroundStyle(.secondary)
                        case let .read(availability)?:
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(availability.title)
                                Text(availability.meaning).font(.caption).foregroundStyle(.secondary)
                            }
                        case let .noAnswer(seconds)?:
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("No answer")
                                Text("\(center.choice.title) did not say whether it is available within \(seconds) seconds. "
                                    + "Check again, or try later.")
                                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                                Button("Check Again") { Task { await center.refreshAvailability() } }
                            }
                        case nil:
                            Button("Check") { Task { await center.refreshAvailability() } }
                        }
                    }
                }
                Toggle("Send folder names", isOn: $center.sendFolderNames)
                Text(ExplainRedactor.folderNamesCaption)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("What Explain sends") {
                ForEach(ExplainRequest.fieldGuide, id: \.name) { field in
                    LabeledContent(field.name) {
                        Text(field.meaning).multilineTextAlignment(.trailing)
                    }
                    .font(.callout)
                }
                Text("Only these fields are sent. Your home folder's path is sent as ~ and your account name is removed. "
                    + "Tools' messages and error text are never sent; a reason is sent as one of a fixed list. Command-line "
                    + "arguments and file contents are never sent: System never reads them. Nothing is sent until you "
                    + "choose a provider and press Explain; with OpenRouter, until it has answered a request you confirmed since "
                    + "System opened, each request is shown to you, exactly as it will be sent, and sent only once you "
                    + "confirm it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            OpenRouterSection(account: openRouter)
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 420)
        .task(id: center.choice) { await center.refreshAvailability() }
    }
}

/// The send preview: exactly the body that will be sent, and Send or Cancel. Cancel, or Escape, sends nothing.
private struct SendPreviewSheet: View {
    let preview: SendPreview
    let send: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send to \(preview.provider.title)?").font(.title3.bold())
            Text("This is exactly what will be sent to openrouter.ai, with your API key in the request's Authorization "
                + "header. You are asked for each request until OpenRouter has answered one you sent since System opened; "
                + "nothing is sent unless you choose Send.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(verbatim: preview.text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
            .accessibilityLabel("Request body")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Send", action: send).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 420, idealHeight: 520)
        .interactiveDismissDisabled()
    }
}

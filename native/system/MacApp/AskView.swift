import SwiftUI
import SystemCore

/// Ask (SET-51), below the main window's sections: the thread's questions and answers, and the field to ask the next
/// one. Answers are plain text; each cited id is a link that only selects what it cites in the window. Without a
/// provider, it says how to choose one.
struct AskView: View {
    let center: AskCenter
    let openSettings: () -> Void
    @State private var question = ""
    @State private var showingPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if center.needsProvider {
                HStack {
                    Text("Ask needs an AI provider. System works fully without one; choose one in Settings.")
                        .foregroundStyle(.secondary)
                    Button("Open Settings…", action: openSettings)
                }
            } else {
                if let notice = center.notice {
                    Text(verbatim: notice).font(.caption).foregroundStyle(.orange)
                }
                if !center.exchanges.isEmpty { thread }
                field
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: preview, initial: true) { _, preview in showingPreview = preview != nil }
        .sheet(isPresented: $showingPreview) {
            if let preview {
                SendPreviewSheet(provider: preview.provider, text: preview.text) {
                    showingPreview = false
                    center.confirmSend(preview)
                } cancel: {
                    showingPreview = false
                    center.cancelSend()
                }
            }
        }
    }

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(center.exchanges) { exchange in
                        ExchangeView(exchange: exchange, provider: center.provider) { center.select($0) }
                            .id(exchange.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .onChange(of: center.exchanges.last?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Ask about this Mac, such as “What is using the most memory?”", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(ask)
                    .disabled(!center.canAsk)
                    .accessibilityLabel("Ask a question")
                if center.isBusy {
                    Button("Stop", action: center.stop)
                } else {
                    Button("Ask", action: ask)
                        .disabled(!center.canAsk || question.trimmingCharacters(in: .whitespaces).isEmpty
                            || question.count > AskCenter.questionLimit)
                }
                Button("New Thread", action: center.newThread)
                    .disabled(center.exchanges.isEmpty)
                    .help("Start again: the questions and answers so far are forgotten")
            }
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var caption: String {
        if question.count > AskCenter.questionLimit {
            return "A question can be at most \(AskCenter.questionLimit) characters."
        }
        let left = center.questionsLeft
        let thread = left == 0
            ? "This thread is full; start a new thread to ask more."
            : "\(left) question\(left == 1 ? "" : "s") left in this thread."
        return "Answered by \(center.provider.title) from the latest sample and scan; it only reads, and can be wrong. "
            + thread
    }

    private var preview: AskSendPreview? {
        if case let .confirming(preview)? = center.exchanges.last?.state { preview } else { nil }
    }

    private func ask() {
        guard center.ask(question) else { return }
        question = ""
    }
}

private struct ExchangeView: View {
    let exchange: AskCenter.Exchange
    let provider: AIProviderChoice
    /// Selects what a citation cites; `false` when it is no longer in the sample or scan.
    let select: (AskTarget) -> Bool
    @State private var gone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: exchange.question).bold().textSelection(.enabled)
            switch exchange.state {
            case .working:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Asking \(provider.title)…").foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            case .confirming:
                Text("Waiting for you to review the request in the send preview.").foregroundStyle(.secondary)
            case let .answered(answer):
                Text(attributed(answer))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.openURL, OpenURLAction { url in
                        if let target = target(url, in: answer) { gone = !select(target) }
                        return .handled
                    })
                if gone {
                    Text("That is no longer in the sample or scan.").font(.caption).foregroundStyle(.secondary)
                }
                details
            case let .failed(message):
                Text(verbatim: message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                // A question can fail after a tool round trip: what was already sent stays inspectable.
                details
            }
        }
    }

    @ViewBuilder
    private var details: some View {
        if !exchange.tools.isEmpty || !exchange.sent.isEmpty {
            DisclosureGroup("Tools used and what was sent") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(exchange.tools.enumerated()), id: \.offset) { _, record in
                        Text(verbatim: record.call + (record.ran ? "" : " (refused)"))
                    }
                    // Only what left this Mac: OpenRouter's bodies, each exactly as sent.
                    ForEach(Array(exchange.sent.enumerated()), id: \.offset) { _, body in
                        Text(verbatim: String(decoding: body, as: UTF8.self)).font(.caption.monospaced())
                    }
                }
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
        }
    }

    /// The answer as plain text, never read as Markdown, with each citation a link to its id.
    private func attributed(_ answer: AskAnswer) -> AttributedString {
        var text = AttributedString()
        for part in answer.parts {
            switch part {
            case let .text(plain):
                text += AttributedString(plain)
            case let .citation(id, _):
                var link = AttributedString("[\(id)]")
                link.link = URL(string: "subset-system-ask:\(id)")
                text += link
            }
        }
        return text
    }

    private func target(_ url: URL, in answer: AskAnswer) -> AskTarget? {
        guard url.scheme == "subset-system-ask" else { return nil }
        let id = url.absoluteString.dropFirst("subset-system-ask:".count)
        for case let .citation(cited, target) in answer.parts where cited == id { return target }
        return nil
    }
}

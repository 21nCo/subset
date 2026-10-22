import SwiftUI
import SystemCore

/// Settings' OpenRouter section: Add key (or Replace key), Test key, Remove key, and the model ID. The key is typed or
/// pasted into a secure field, stored in the Keychain, and never shown again.
struct OpenRouterSection: View {
    @Bindable var account: OpenRouterAccount
    @State private var entered = ""

    var body: some View {
        Section("OpenRouter") {
            LabeledContent("API key") {
                Text(account.hasKey ? "Stored in this Mac's Keychain" : "None")
                    .foregroundStyle(.secondary)
            }
            HStack {
                SecureField(account.hasKey ? "New key" : "Key", text: $entered)
                    .labelsHidden()
                    .onSubmit(add)
                Button(account.hasKey ? "Replace Key" : "Add Key", action: add)
                    .disabled(entered.isEmpty)
            }
            if account.hasKey {
                HStack {
                    Button("Test Key") { Task { await account.testKey() } }
                        .disabled(account.keyTest == .testing)
                    Button("Remove Key", role: .destructive) { account.removeKey() }
                    Spacer()
                    keyTest
                }
            }
            if let error = account.keyError {
                Text(verbatim: error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            TextField("Model", text: $account.model, prompt: Text(verbatim: OpenRouterProvider.defaultModel))
            Text("The OpenRouter model ID to use; when empty, openrouter/auto picks a model for each request. Test Key "
                + "asks OpenRouter whether the key works and sends none of your data. The key is kept only in this "
                + "Mac's Keychain and is sent only in each request's Authorization header, to openrouter.ai.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var keyTest: some View {
        switch account.keyTest {
        case .testing?:
            ProgressView().controlSize(.small)
        case .passed?:
            Label("The key works", systemImage: "checkmark.circle").foregroundStyle(.green)
        case let .failed(message)?:
            Text(verbatim: message).foregroundStyle(.red).multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        case nil:
            EmptyView()
        }
    }

    private func add() {
        if account.addKey(entered) { entered = "" }
    }
}

/// The send preview: before the first request of the session to OpenRouter, the exact JSON body, for the user to send
/// or cancel. It is shown as plain text and never run.
struct SendPreviewSheet: View {
    let preview: SendPreview
    let send: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send this to \(preview.provider.title)?").font(.headline)
            Text("This is exactly what System will send. Your API key is sent only in the request's Authorization "
                + "header and is not shown. Once you send it, System does not ask again until it is next opened.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(verbatim: preview.text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .accessibilityLabel("Request body")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Send", action: send).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 600, minHeight: 420, idealHeight: 520)
    }
}

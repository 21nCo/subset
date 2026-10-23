import SwiftUI
import SystemCore

/// Settings' OpenRouter section: Add key (or Replace key), Test key, Remove key, and the model ID. The key is typed or
/// pasted into a secure field, stored in the Keychain, and never shown again. Whether a key is stored is read again
/// each time Settings is shown (`AppDelegate.perform(.settings)`).
struct OpenRouterSection: View {
    @Bindable var account: OpenRouterAccount
    @State private var entered = ""
    @FocusState private var modelFocused: Bool

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
                    // Not while Add Key or Remove Key waits for the Keychain: the key it would test may be going.
                    Button("Test Key") { Task { await account.testKey() } }
                        .disabled(account.keyTest == .testing || account.isChangingKey)
                    Button("Remove Key", role: .destructive) { Task { await account.removeKey() } }
                    Spacer()
                    keyTest
                }
            }
            if let error = account.keyError {
                Text(verbatim: error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            // Checked and kept on Return or when the field loses focus, not as each character is typed.
            TextField("Model", text: $account.modelEntry, prompt: Text(verbatim: OpenRouterProvider.defaultModel))
                .focused($modelFocused)
                .onSubmit { account.commitModel() }
                .onChange(of: modelFocused) { _, focused in
                    if !focused { account.commitModel() }
                }
            if let error = account.modelError {
                Text(verbatim: error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Text("The OpenRouter model ID to use; when empty, openrouter/auto picks a model for each request. Test Key "
                + "asks OpenRouter whether the key works and sends none of your data. The key is kept only in this "
                + "Mac's Keychain and is sent only in each request's Authorization header, to openrouter.ai. Explain "
                + "cannot use OpenRouter yet.")
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
        let key = entered
        Task {
            // Cleared once stored, unless something else was typed or pasted meanwhile.
            if await account.addKey(key), entered == key { entered = "" }
        }
    }
}

import AppKit
import SwiftUI
import TimerCore

/// "New Countdown…": a small window that takes a duration, checks it as the CLI does, and starts the countdown.
@MainActor
final class CountdownWindowController {
    private let controller: TimerController
    private var window: NSWindow?

    init(controller: TimerController) {
        self.controller = controller
    }

    func show() {
        if window?.isVisible != true {
            weak var presented: NSWindow? // A new window and form each time: a start still pending in a closed one cannot touch it.
            let form = CountdownForm(start: { [controller] ms, name in
                await controller.perform("start", OperationInput(timer: .countdown(durationMs: ms, name: name)))
            }, close: { presented?.close() })
            let window = NSWindow(contentViewController: NSHostingController(rootView: form))
            presented = window
            window.title = "New Countdown"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct CountdownForm: View {
    let start: (Int, String?) async -> String?
    let close: () -> Void
    @State private var duration = ""
    @State private var name = ""
    @State private var failure: String?
    @State private var starting = false

    private var parsed: Result<Int, DurationError> { DurationParser.parse(duration) }

    var body: some View {
        Form {
            TextField("Duration", text: $duration, prompt: Text("25m, 1:30 or 1h30m"))
            TextField("Name", text: $name, prompt: Text("Countdown"))
            if !duration.trimmingCharacters(in: .whitespaces).isEmpty, case .failure(let error) = parsed {
                Text(error.message).foregroundStyle(.red).accessibilityLabel("Invalid duration: \(error.message)")
            }
            if let failure {
                Text(failure).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { finish() }
                    .keyboardShortcut(.cancelAction)
                Button("Start") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(starting || (try? parsed.get()) == nil)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onChange(of: duration) { failure = nil }
        .onChange(of: name) { failure = nil }
    }

    private func submit() {
        guard case .success(let ms) = parsed else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        starting = true
        Task {
            failure = await start(ms, trimmed.isEmpty ? nil : trimmed)
            starting = false
            if failure == nil { finish() }
        }
    }

    private func finish() {
        duration = ""
        name = ""
        failure = nil
        close()
    }
}

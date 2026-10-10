import SwiftUI
import UIKit

@main
struct AnnotateApp: App {
    var body: some Scene {
        WindowGroup {
            DocumentWindow()
        }
    }
}

/// Each window owns its own document store, so opening or closing a PDF in one
/// window (iPad multitasking, Mac Catalyst) does not affect the others.
private struct DocumentWindow: View {
    @StateObject private var store = PDFDocumentStore()

    var body: some View {
        ContentView()
            .environmentObject(store)
            .background(WindowCloseGuard(isClosable: !store.hasUnexportedChanges))
    }
}

/// The store holds the only copy of unexported annotations, and the system window close control
/// (Mac Catalyst title bar, iPad Stage Manager) would destroy it without the discard prompt.
/// While there are unexported changes the window is not closable, so the in-app Close (⌘W),
/// which asks first, is the way out.
private struct WindowCloseGuard: UIViewRepresentable {
    let isClosable: Bool

    func makeUIView(context _: Context) -> GuardView {
        GuardView()
    }

    func updateUIView(_ view: GuardView, context _: Context) {
        view.isClosable = isClosable
    }

    final class GuardView: UIView {
        var isClosable = true {
            didSet { apply() }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            isUserInteractionEnabled = false
            apply()
        }

        private func apply() {
            window?.windowScene?.windowingBehaviors?.isClosable = isClosable
        }
    }
}

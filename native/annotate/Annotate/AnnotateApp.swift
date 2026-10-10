import SwiftUI

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
    }
}

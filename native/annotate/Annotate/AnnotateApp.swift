import SwiftUI

@main
struct AnnotateApp: App {
    @StateObject private var store = PDFDocumentStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}

import Observation
import SwiftUI
import SystemCore
import SystemDisk
import SystemProcesses

/// The main window's sections.
enum MainWindowSection: String, CaseIterable {
    case processes
    case disk

    var title: String {
        switch self {
        case .processes: "Processes"
        case .disk: "Disk"
        }
    }
}

/// Which section the main window shows, shared with the View menu.
@MainActor
@Observable
final class MainWindowState {
    var section: MainWindowSection = .processes
}

/// The main window: the section picker above Processes or Disk, and Ask below them.
struct MainWindowView: View {
    @Bindable var state: MainWindowState
    let processes: ProcessesWindowModel
    let disk: DiskWindowModel
    let monitor: SystemMonitor
    let explain: ExplainCenter
    let ask: AskCenter
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $state.section) {
                ForEach(MainWindowSection.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show processes or disk usage (⌥⌘1, ⌥⌘2)")
            .accessibilityLabel("Section")
            .accessibilityValue(state.section.title)
            .padding(.top, 10)
            switch state.section {
            case .processes: ProcessesView(model: processes, monitor: monitor, explain: explain, openSettings: openSettings)
            case .disk: DiskView(model: disk, explain: explain, openSettings: openSettings)
            }
            Divider()
            AskView(center: ask, openSettings: openSettings)
        }
    }
}

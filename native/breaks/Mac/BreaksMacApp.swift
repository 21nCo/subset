import AppKit
import SwiftUI

@main
struct BreaksMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(appDelegate.controller)
        } label: {
            MenuBarLabel()
                .environmentObject(appDelegate.controller)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            MacSettingsView()
                .environmentObject(appDelegate.controller)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = MacBreakController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject private var controller: MacBreakController

    var body: some View {
        if controller.settings.desktop.showsMenuBarCountdown {
            Label(controller.menuBarText, systemImage: controller.menuBarSymbol)
                .labelStyle(.titleAndIcon)
                .monospacedDigit()
                .accessibilityLabel("Breaks: \(controller.statusLine)")
        } else {
            Image(systemName: controller.menuBarSymbol)
                .accessibilityLabel("Breaks: \(controller.statusLine)")
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject private var controller: MacBreakController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(controller.statusLine)

        Divider()

        switch controller.phase {
        case .breaking:
            Button("End break") { controller.endBreak() }
                .disabled(!controller.canEndEarly)
            if controller.settings.discipline != .hardcore {
                Button("Skip break") { controller.skipActiveBreak() }
                    .disabled(!controller.canSkipBreak)
            }
        case .paused:
            Button("Resume reminders") { controller.resume() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            if controller.pauseReason != .manual {
                Button("Pause until I resume") { controller.pause() }
            }
        case .focusing, .headsUp:
            Button("Start break now") { controller.startBreak() }
                .keyboardShortcut("b")
            Menu("Snooze next break") {
                Button("1 minute") { controller.snooze(minutes: 1) }
                Button("5 minutes") { controller.snooze(minutes: 5) }
                Button("15 minutes") { controller.snooze(minutes: 15) }
                Divider()
                Text("\(controller.snoozesRemaining) of \(controller.settings.snoozesAllowedPerDay) snoozes left today")
            }
            .disabled(controller.snoozesRemaining == 0)
            if controller.canSkipUpcomingBreak {
                Button("Skip next break") { controller.skipUpcomingBreak() }
            }
            Menu("Pause reminders") {
                Button("For 30 minutes") { controller.pause(for: 30 * 60) }
                Button("For 1 hour") { controller.pause(for: 60 * 60) }
                Button("For 2 hours") { controller.pause(for: 2 * 60 * 60) }
                Button("Until I resume") { controller.pause() }
            }
        }

        Divider()

        let stats = controller.stats
        Text("Today: \(stats.breaksTaken) breaks, \(stats.skippedBreaks) skipped, score \(stats.screenScore)")
        if let (planned, date) = controller.nextPlannedBreak {
            Text("Next planned: \(planned.name) at \(date.formatted(date: .omitted, time: .shortened))")
        }

        Divider()

        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")
        Button("Quit Breaks") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

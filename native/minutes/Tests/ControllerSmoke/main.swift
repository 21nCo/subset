import Foundation

// Controller smoke test: drives the app's real MinutesController against the real CLI, without the UI
// and without joining a meeting. It checks readiness through `doctor --json`, then starts a join whose
// link passes the app's host check but fails the CLI's strict validation, and expects the structured
// `invalid_link` error to reach the controller. See native/minutes/README.md for the command.
@MainActor
func runHarness() async {
    let controller = MinutesController()
    controller.refreshReadiness(outputDirectory: NSTemporaryDirectory() + "minutes-harness-out")
    // isCheckingReadiness brackets the whole check, even when nothing is found.
    while controller.isCheckingReadiness {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    let r = controller.readiness
    print("node:", r.nodePath ?? "nil")
    print("cli:", r.cli.map { "\($0.source.rawValue) \($0.scriptPath)" } ?? "nil")
    print("doctor ok:", r.doctor?.ok as Any, "checks:", r.doctor?.checks.map { "\($0.id)=\($0.ok)" } ?? [])
    print("ready:", r.isReady)

    guard let link = MeetingLink("https://meet.google.com/not-a-meeting-code") else { print("app rejected link"); exit(1) }
    controller.start(link: link, displayName: "Harness", recordingDirectory: NSTemporaryDirectory() + "minutes-harness-out")
    for _ in 0..<100 where controller.isRunning || controller.phase == .launching {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    try? await Task.sleep(nanoseconds: 300_000_000)
    print("phase:", controller.phase)
    print("lastErrorCode:", controller.lastErrorCode ?? "nil")
    for entry in controller.logs { print("log:", entry.isError ? "[err]" : "", entry.text) }
    exit(controller.lastErrorCode == "invalid_link" ? 0 : 1)
}

Task { await runHarness() }
RunLoop.main.run()

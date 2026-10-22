import AppKit
import Foundation
import PointInTimeCore

// The `point-in-time` command, bundled at pointInTime.app/Contents/Helpers/point-in-time. Everything it does is in
// `StatusCommand`; this file only gathers what that reads from the system and prints the result.

/// The app's version when this executable runs from inside pointInTime.app, nil otherwise (a `swift build` binary).
func enclosingAppVersion() -> String? {
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
    let helpers = executable.deletingLastPathComponent()
    let contents = helpers.deletingLastPathComponent()
    guard helpers.lastPathComponent == "Helpers", contents.lastPathComponent == "Contents",
          let app = Bundle(url: contents.deletingLastPathComponent()), app.bundleIdentifier == StoredSettings.domain,
          let version = app.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return nil }
    let build = app.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    return build.map { "\(version) (\($0))" } ?? version
}

/// The app's defaults domain, read without writing it.
func appSettings() -> StoredSettings {
    let values = CFPreferencesCopyMultiple(nil, StoredSettings.domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    return StoredSettings(values as? [String: Any] ?? [:])
}

let arguments = Array(CommandLine.arguments.dropFirst())
let environment = StatusEnvironment(
    now: Date(), timeZone: .current, storeDirectory: try? ActivityStore.defaultDirectory(), settings: appSettings(),
    appRunning: !NSRunningApplication.runningApplications(withBundleIdentifier: StoredSettings.domain).isEmpty,
    version: enclosingAppVersion())
let output = StatusCommand.run(arguments, environment: environment)
FileHandle.standardOutput.write(Data(output.standardOutput.utf8))
FileHandle.standardError.write(Data(output.standardError.utf8))
exit(output.exitCode.rawValue)

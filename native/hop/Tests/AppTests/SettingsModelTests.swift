import Foundation
@testable import Hop
import HopCore
import XCTest

/// A login item that answers as set and records what it was asked.
@MainActor
private final class FakeLoginItem: LoginItemService {
    var status: LoginItemStatus = .notRegistered
    var failure: Error?
    var statusAfterRegister: LoginItemStatus = .requiresApproval
    private(set) var requests: [String] = []

    func register() throws {
        requests.append("register")
        if let failure { throw failure }
        status = statusAfterRegister
    }

    func unregister() throws {
        requests.append("unregister")
        if let failure { throw failure }
        status = .notRegistered
    }

    func openSettings() {
        requests.append("openSettings")
    }
}

@MainActor
final class SettingsModelTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private let loginItem = FakeLoginItem()

    override func setUp() async throws {
        suiteName = "dev.subset.hop.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func model() -> SettingsModel {
        SettingsModel(store: SettingsStore(defaults: defaults), loginItemService: loginItem)
    }

    private func press(_ code: UInt16, _ modifiers: ModifierMask) -> KeyEvent {
        KeyEvent(.keyDown, keyCode: code, modifiers: modifiers)
    }

    func testAChangeIsSavedAndHandedToTheAppAtOnce() {
        let settings = model()
        var applied: [Settings] = []
        settings.onChange = { applied.append($0) }
        settings.update { $0.shownWindows.windowlessApps = true }
        settings.update { $0.shownWindows.windowlessApps = true }
        XCTAssertEqual(applied.count, 1, "a change that changes nothing is not applied again")
        XCTAssertTrue(applied[0].shownWindows.windowlessApps)
        XCTAssertEqual(SettingsStore(defaults: defaults).load(), settings.settings)
        XCTAssertEqual(model().settings, settings.settings, "the next launch reads it")
    }

    func testRecordingSuspendsTheShortcutUntilAnAllowedPressAndRefusesOthersWithAReason() throws {
        let settings = model()
        var suspended: [Bool] = []
        var applied: [Shortcut] = []
        settings.onRecordingChange = { suspended.append($0) }
        settings.onChange = { applied.append($0.shortcut) }
        settings.startRecording()
        XCTAssertEqual(suspended, [true])
        settings.record(press(KeyCode.tab, [.option, .shift]))
        XCTAssertTrue(settings.isRecording)
        XCTAssertEqual(settings.recorderMessage, "⇧ switches backward, so it can't be part of the shortcut.")
        settings.record(press(KeyCode.grave, .option))
        XCTAssertEqual(settings.recorderMessage, "⌥` is the same-app shortcut.")
        XCTAssertEqual(applied, [])
        settings.record(press(KeyCode.grave, .control))
        let controlGrave = try Shortcut(holdModifier: .control, keyCode: KeyCode.grave)
        XCTAssertFalse(settings.isRecording)
        XCTAssertNil(settings.recorderMessage)
        XCTAssertEqual(settings.settings.shortcut, controlGrave)
        XCTAssertEqual(applied, [controlGrave])
        XCTAssertEqual(suspended, [true, false])
        XCTAssertEqual(SettingsStore(defaults: defaults).load().shortcut, controlGrave)
        settings.resetShortcut()
        XCTAssertEqual(settings.settings.shortcut, .default)
    }

    func testResetShowsWhyWhenOptionTabIsTheSameAppShortcut() throws {
        defaults.set(Data(#"""
            {"schemaVersion": 1, "shortcut": {"holdModifier": "control", "keyCode": 48},
             "sameAppShortcut": {"holdModifier": "option", "keyCode": 48}}
            """#.utf8), forKey: Settings.defaultsKey)
        let settings = model()
        var applied: [Settings] = []
        settings.onChange = { applied.append($0) }
        let stored = settings.settings
        XCTAssertNotEqual(stored, .default)
        settings.resetShortcut()
        XCTAssertEqual(settings.recorderMessage, "⌥Tab is the same-app shortcut.")
        XCTAssertEqual(settings.settings, stored)
        XCTAssertEqual(applied, [])
        XCTAssertEqual(SettingsStore(defaults: defaults).load(), stored)
    }

    func testRecordingTheSameAppShortcutRefusesTheSwitchShortcut() throws {
        let settings = model()
        var suspended: [Bool] = []
        var applied: [Settings] = []
        settings.onRecordingChange = { suspended.append($0) }
        settings.onChange = { applied.append($0) }
        settings.startRecording()
        settings.startRecording(.sameApp)
        XCTAssertEqual(settings.recording, .sameApp, "recording moves to the same-app shortcut")
        XCTAssertEqual(suspended, [true], "the tap stays suspended")
        settings.record(press(KeyCode.tab, .option))
        XCTAssertEqual(settings.recording, .sameApp)
        XCTAssertEqual(settings.recorderMessage, "⌥Tab is the switch shortcut.")
        XCTAssertEqual(settings.recorderMessageRole, .sameApp)
        settings.record(press(KeyCode.grave, .control))
        let controlGrave = try Shortcut(holdModifier: .control, keyCode: KeyCode.grave)
        XCTAssertFalse(settings.isRecording)
        XCTAssertEqual(suspended, [true, false])
        XCTAssertEqual(settings.settings.sameAppShortcut, controlGrave)
        XCTAssertEqual(settings.settings.shortcut, .default)
        XCTAssertEqual(applied.map(\.sameAppShortcut), [controlGrave])
        XCTAssertEqual(SettingsStore(defaults: defaults).load().sameAppShortcut, controlGrave)
        settings.resetShortcut(.sameApp)
        XCTAssertEqual(settings.settings.sameAppShortcut, .sameAppDefault)
    }

    func testEscOrStopEndsRecordingAndKeepsTheShortcut() {
        let settings = model()
        var suspended: [Bool] = []
        settings.onRecordingChange = { suspended.append($0) }
        settings.startRecording()
        settings.record(press(KeyCode.escape, []))
        XCTAssertFalse(settings.isRecording)
        settings.startRecording()
        settings.stopRecording()
        settings.stopRecording()
        XCTAssertEqual(suspended, [true, false, true, false])
        XCTAssertEqual(settings.settings.shortcut, .default)
        settings.record(press(KeyCode.tab, .control))
        XCTAssertEqual(settings.settings.shortcut, .default, "a press outside recording changes nothing")
    }

    func testLaunchAtLoginShowsTheApprovalStateAndErrors() {
        let settings = model()
        XCTAssertEqual(settings.loginItem, .notRegistered)
        settings.setLaunchAtLogin(true)
        XCTAssertEqual(settings.loginItem, .requiresApproval)
        XCTAssertTrue(settings.loginItem.isOn)
        settings.openLoginItems()
        XCTAssertEqual(loginItem.requests, ["register", "openSettings"])
        loginItem.status = .enabled // approved in System Settings
        settings.refreshLoginItem()
        XCTAssertEqual(settings.loginItem, .enabled)
        loginItem.failure = CocoaError(.fileNoSuchFile)
        settings.setLaunchAtLogin(false)
        XCTAssertEqual(settings.loginItem, .enabled)
        XCTAssertTrue(settings.loginItemError?.hasPrefix("Couldn't turn off launch at login") == true)
        loginItem.failure = nil
        settings.setLaunchAtLogin(false)
        XCTAssertNil(settings.loginItemError)
        XCTAssertEqual(settings.loginItem, .notRegistered)
    }

    func testExcludingAndIncludingApps() {
        let settings = model()
        settings.exclude("com.example.mail")
        settings.exclude("com.example.mail")
        XCTAssertEqual(settings.excludedApps.map(\.bundleIdentifier), ["com.example.mail"])
        XCTAssertFalse(settings.runningAppsToExclude.contains { $0.bundleIdentifier == HopIdentity.bundleIdentifier })
        settings.include("com.example.mail")
        XCTAssertEqual(SettingsStore(defaults: defaults).load().excludedApps, [])
    }

    func testOpenPrivacyAndSecurityOpensTheAccessibilityPaneWhetherOrNotHopIsAllowed() {
        var trusted = true
        var requests: [String] = []
        let pane = AccessibilityPane(
            isTrusted: { trusted },
            prompt: { requests.append("prompt") },
            open: { requests.append("open \($0.absoluteString)") }
        )
        let settings = SettingsModel(store: SettingsStore(defaults: defaults), loginItemService: loginItem, accessibilityPane: pane)
        let open = "open x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        settings.openAccessibilitySettings()
        XCTAssertEqual(requests, [open], "allowed: opens the pane without prompting")
        trusted = false
        requests = []
        settings.openAccessibilitySettings()
        XCTAssertEqual(requests, ["prompt", open], "not allowed: prompts so Hop is listed, then opens the pane")
    }

    // MARK: - Window previews

    /// Screen Recording as macOS would answer: granted or not, and whether Hop ever asked.
    private final class FakeScreenRecording {
        var granted = false
        var requested = false
        var calls: [String] = []

        var pane: ScreenRecordingPane {
            ScreenRecordingPane(
                isGranted: { self.granted },
                wasRequested: { self.requested },
                request: {
                    self.requested = true
                    self.calls.append("request")
                },
                open: { self.calls.append("open \($0.absoluteString)") }
            )
        }
    }

    private func model(_ screenRecording: FakeScreenRecording) -> SettingsModel {
        SettingsModel(store: SettingsStore(defaults: defaults), loginItemService: loginItem,
                      screenRecordingPane: screenRecording.pane)
    }

    func testTurningPreviewsOnAsksForScreenRecordingOnceAndSaysTheSwitcherShowsIcons() {
        let screenRecording = FakeScreenRecording()
        let settings = model(screenRecording)
        XCTAssertFalse(settings.settings.showWindowPreviews, "off by default")
        XCTAssertEqual(settings.screenRecording, .notDetermined)
        XCTAssertEqual(screenRecording.calls, [], "nothing is asked while previews are off")
        var applied: [Settings] = []
        settings.onChange = { applied.append($0) }

        settings.setShowWindowPreviews(true)
        XCTAssertEqual(screenRecording.calls, ["request"])
        XCTAssertEqual(applied.map(\.showWindowPreviews), [true])
        XCTAssertTrue(SettingsStore(defaults: defaults).load().showWindowPreviews, "saved at once")
        XCTAssertEqual(settings.screenRecording, .denied)
        XCTAssertEqual(settings.screenRecording.notice, "Screen Recording isn't allowed for \(HopIdentity.appName), so the switcher shows app icons.")
        XCTAssertFalse(settings.capturesThumbnails())

        settings.setShowWindowPreviews(false)
        XCTAssertEqual(screenRecording.calls, ["request"], "turning previews off asks nothing")
        XCTAssertEqual(applied.map(\.showWindowPreviews), [true, false])
    }

    func testTurningPreviewsOnWithAccessAlreadyGrantedAsksNothingAndCaptures() {
        let screenRecording = FakeScreenRecording()
        screenRecording.granted = true
        let settings = model(screenRecording)
        settings.setShowWindowPreviews(true)
        XCTAssertEqual(screenRecording.calls, [])
        XCTAssertEqual(settings.screenRecording, .granted)
        XCTAssertNil(settings.screenRecording.notice)
        XCTAssertTrue(settings.capturesThumbnails())
    }

    func testARevocationNoticedWhenTheSwitcherOpensShowsInSettingsAndStopsCapture() {
        let screenRecording = FakeScreenRecording()
        screenRecording.granted = true
        let settings = model(screenRecording)
        settings.setShowWindowPreviews(true)
        XCTAssertTrue(settings.capturesThumbnails())
        screenRecording.granted = false
        XCTAssertFalse(settings.capturesThumbnails(), "the switcher shows icons")
        XCTAssertEqual(settings.screenRecording, .revoked)
        XCTAssertEqual(settings.screenRecording.notice, "Screen Recording was turned off for \(HopIdentity.appName), so the switcher shows app icons.")
        XCTAssertEqual(screenRecording.calls, [], "never asks while switching")
    }

    func testPreviewsOffNeverCaptureEvenWithAccess() {
        let screenRecording = FakeScreenRecording()
        screenRecording.granted = true
        XCTAssertFalse(model(screenRecording).capturesThumbnails())
    }

    func testAnEarlierRequestReadsAsDeniedAfterRelaunch() {
        let screenRecording = FakeScreenRecording()
        screenRecording.requested = true
        XCTAssertEqual(model(screenRecording).screenRecording, .denied)
    }

    func testOpenScreenRecordingSettingsAsksFirstOnlyWhenNotAllowed() {
        let screenRecording = FakeScreenRecording()
        let settings = model(screenRecording)
        let open = "open x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        settings.openScreenRecordingSettings()
        XCTAssertEqual(screenRecording.calls, ["request", open])
        screenRecording.granted = true
        screenRecording.calls = []
        settings.openScreenRecordingSettings()
        XCTAssertEqual(screenRecording.calls, [open])
        XCTAssertEqual(settings.screenRecording, .granted)
    }
}

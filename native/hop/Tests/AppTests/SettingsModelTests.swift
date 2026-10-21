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
}

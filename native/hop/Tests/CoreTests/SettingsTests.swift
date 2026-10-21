import CoreGraphics
import Foundation
import HopCore
import XCTest

final class SettingsTests: XCTestCase {
    // MARK: - Shortcut

    func testTheSameAppShortcutIsRefusedAsTheSwitchShortcut() throws {
        let settings = Settings.default
        XCTAssertEqual(settings.sameAppShortcut.displayName, "⌥`")
        XCTAssertThrowsError(try settings.validateShortcut(modifiers: .option, keyCode: KeyCode.grave)) { error in
            XCTAssertEqual(error as? Shortcut.Invalid, .sameAppShortcut(.sameAppDefault))
            XCTAssertEqual((error as? Shortcut.Invalid)?.reason, "⌥` is the same-app shortcut.")
        }
        var changed = settings
        XCTAssertThrowsError(try changed.setShortcut(.sameAppDefault))
        XCTAssertEqual(changed.shortcut, .default)
        // The same key with the other holding modifier is a different combination.
        XCTAssertEqual(try settings.validateShortcut(modifiers: .control, keyCode: KeyCode.grave).displayName, "⌃`")
    }

    func testTheRecorderTakesAnAllowedPressAndRefusesOthersWithAReason() throws {
        let settings = Settings.default
        func press(_ code: UInt16, _ modifiers: ModifierMask, repeat isRepeat: Bool = false) -> ShortcutRecording {
            settings.record(KeyEvent(.keyDown, keyCode: code, modifiers: modifiers, isRepeat: isRepeat))
        }
        XCTAssertEqual(press(KeyCode.tab, .control), .recorded(try Shortcut(holdModifier: .control, keyCode: KeyCode.tab)))
        XCTAssertEqual(press(KeyCode.grave, .control), .recorded(try Shortcut(holdModifier: .control, keyCode: KeyCode.grave)))
        XCTAssertEqual(press(KeyCode.tab, .option), .recorded(.default))
        XCTAssertEqual(press(KeyCode.grave, .option), .rejected(.sameAppShortcut(.sameAppDefault)))
        XCTAssertEqual(press(KeyCode.tab, [.option, .shift]), .rejected(.shift))
        XCTAssertEqual(press(KeyCode.tab, [.command]), .rejected(.command))
        XCTAssertEqual(press(KeyCode.tab, []), .rejected(.noHoldModifier))
        XCTAssertEqual(press(0x0D /* W */, .option), .rejected(.key(0x0D)))
        XCTAssertEqual(press(KeyCode.escape, []), .cancelled, "Esc alone stops recording")
        XCTAssertEqual(press(KeyCode.escape, .option), .rejected(.key(KeyCode.escape)))
        XCTAssertEqual(press(KeyCode.tab, .control, repeat: true), .ignored)
        XCTAssertEqual(settings.record(KeyEvent(.keyUp, keyCode: KeyCode.tab, modifiers: .control)), .ignored)
        XCTAssertEqual(settings.record(KeyEvent(.flagsChanged, keyCode: 0x3B, modifiers: .control)), .ignored)
    }

    func testResetGoesBackToOptionTab() throws {
        var settings = Settings.default
        try settings.setShortcut(Shortcut(holdModifier: .control, keyCode: KeyCode.grave))
        try settings.resetShortcut()
        XCTAssertEqual(settings.shortcut.displayName, "⌥Tab")
    }

    func testTheSameAppShortcutFollowsTheSameRulesAndCannotBeTheSwitchShortcut() throws {
        var settings = Settings.default
        func press(_ code: UInt16, _ modifiers: ModifierMask) -> ShortcutRecording {
            settings.record(KeyEvent(.keyDown, keyCode: code, modifiers: modifiers), for: .sameApp)
        }
        XCTAssertEqual(press(KeyCode.tab, .option), .rejected(.switchShortcut(.default)))
        XCTAssertEqual(Shortcut.Invalid.switchShortcut(.default).reason, "⌥Tab is the switch shortcut.")
        XCTAssertEqual(press(KeyCode.grave, [.option, .command]), .rejected(.command))
        XCTAssertEqual(press(KeyCode.grave, [.option, .shift]), .rejected(.shift))
        XCTAssertEqual(press(0x0E /* E */, .option), .rejected(.key(0x0E)))
        let controlTab = try Shortcut(holdModifier: .control, keyCode: KeyCode.tab)
        XCTAssertEqual(press(KeyCode.tab, .control), .recorded(controlTab))
        XCTAssertThrowsError(try settings.setShortcut(.default, for: .sameApp)) { error in
            XCTAssertEqual(error as? Shortcut.Invalid, .switchShortcut(.default))
        }
        XCTAssertEqual(settings.sameAppShortcut, .sameAppDefault, "a refused shortcut changes nothing")
        try settings.setShortcut(controlTab, for: .sameApp)
        XCTAssertEqual(settings.shortcut(for: .sameApp), controlTab)
        XCTAssertThrowsError(try settings.setShortcut(controlTab)) { error in
            XCTAssertEqual(error as? Shortcut.Invalid, .sameAppShortcut(controlTab), "the switch shortcut can't take it")
        }
        // ⌥` is free now, so the switch shortcut may take it, and then the same-app shortcut can't go back to it.
        try settings.setShortcut(.sameAppDefault)
        XCTAssertThrowsError(try settings.resetShortcut(.sameApp)) { error in
            XCTAssertEqual(error as? Shortcut.Invalid, .switchShortcut(.sameAppDefault))
        }
        XCTAssertEqual(settings.sameAppShortcut, controlTab)
        try settings.resetShortcut()
        try settings.resetShortcut(.sameApp)
        XCTAssertEqual(settings, .default)
    }

    // MARK: - Excluded apps

    func testExcludedAppsKeepTheirOrderWithoutDuplicatesOrEmptyIDs() {
        var settings = Settings.default
        settings.exclude("com.example.b")
        settings.exclude("com.example.a")
        settings.exclude("com.example.b")
        settings.exclude("")
        XCTAssertEqual(settings.excludedApps, ["com.example.b", "com.example.a"])
        settings.include("com.example.b")
        XCTAssertEqual(settings.excludedApps, ["com.example.a"])
        XCTAssertFalse(settings.allows(bundleIdentifier: "com.example.a"))
        XCTAssertTrue(settings.allows(bundleIdentifier: "com.example.b"))
        XCTAssertTrue(settings.allows(bundleIdentifier: nil), "an app without a bundle ID cannot be excluded")
    }

    // MARK: - Login item

    func testLoginItemStates() {
        XCTAssertEqual(
            [LoginItemStatus.notRegistered, .enabled, .requiresApproval, .notFound].map(\.isOn),
            [false, true, true, false]
        )
        XCTAssertEqual(
            [LoginItemStatus.notRegistered, .enabled, .requiresApproval, .notFound].map(\.needsApproval),
            [false, false, true, false]
        )
        XCTAssertNil(LoginItemStatus.enabled.note)
        XCTAssertNotNil(LoginItemStatus.requiresApproval.note)
        XCTAssertNotNil(LoginItemStatus.notFound.note)
    }
}

final class SettingsStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "dev.subset.hop.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private var store: SettingsStore { SettingsStore(defaults: defaults) }

    private func storeJSON(_ json: String) {
        defaults.set(Data(json.utf8), forKey: Settings.defaultsKey)
    }

    private func changedSettings() throws -> Settings {
        var settings = Settings.default
        try settings.setShortcut(Shortcut(holdModifier: .control, keyCode: KeyCode.grave))
        settings.shownWindows.minimized = false
        settings.shownWindows.hiddenApps = false
        settings.shownWindows.windowlessApps = true
        settings.shownWindows.pointerDisplayOnly = true
        settings.exclude("com.example.mail")
        settings.exclude("com.example.music")
        return settings
    }

    func testNothingStoredReadsTheDefaults() {
        let settings = store.load()
        XCTAssertEqual(settings, .default)
        XCTAssertEqual(settings.shortcut, .default)
        XCTAssertEqual(
            [settings.shownWindows.minimized, settings.shownWindows.hiddenApps,
             settings.shownWindows.windowlessApps, settings.shownWindows.pointerDisplayOnly],
            [true, true, false, false]
        )
        XCTAssertEqual(settings.excludedApps, [])
    }

    func testSettingsRoundTripUnderTheirKeyWithSchemaVersionOne() throws {
        let settings = try changedSettings()
        store.save(settings)
        XCTAssertEqual(store.load(), settings)
        XCTAssertEqual(Settings.defaultsKey, "dev.subset.hop.settings")
        let data = try XCTUnwrap(defaults.data(forKey: "dev.subset.hop.settings"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["shortcut"] as? [String: AnyHashable], ["holdModifier": "control", "keyCode": 0x32])
        XCTAssertEqual(json["excludedApps"] as? [String], ["com.example.mail", "com.example.music"])
    }

    func testAChangedSameAppShortcutRoundTrips() throws {
        var settings = Settings.default
        try settings.setShortcut(Shortcut(holdModifier: .control, keyCode: KeyCode.grave), for: .sameApp)
        store.save(settings)
        XCTAssertEqual(store.load(), settings)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: Settings.defaultsKey)))
            as? [String: Any])
        XCTAssertEqual(json["sameAppShortcut"] as? [String: AnyHashable], ["holdModifier": "control", "keyCode": 0x32])
    }

    func testCorruptOrUnknownDataReadsTheDefaults() {
        let cases: [(String, Any)] = [
            ("not JSON", Data("{nope".utf8)),
            ("not data", "schemaVersion 1"),
            ("an array", Data("[1]".utf8)),
            ("no version", Data(#"{"shownWindows": {"minimized": false}}"#.utf8)),
            ("a later version", Data(#"{"schemaVersion": 2, "shownWindows": {"minimized": false}}"#.utf8)),
            ("a version of the wrong type", Data(#"{"schemaVersion": "1"}"#.utf8)),
            ("an option of the wrong type", Data(#"{"schemaVersion": 1, "shownWindows": {"minimized": "no"}}"#.utf8)),
            ("excluded apps not a list", Data(#"{"schemaVersion": 1, "excludedApps": "com.example.mail"}"#.utf8)),
            ("a ⌘ shortcut", Data(#"{"schemaVersion": 1, "shortcut": {"holdModifier": "command", "keyCode": 48}}"#.utf8)),
            ("an arrow shortcut", Data(#"{"schemaVersion": 1, "shortcut": {"holdModifier": "option", "keyCode": 123}}"#.utf8)),
            ("a negative key code", Data(#"{"schemaVersion": 1, "shortcut": {"holdModifier": "option", "keyCode": -1}}"#.utf8)),
            ("half a shortcut", Data(#"{"schemaVersion": 1, "shortcut": {"holdModifier": "control"}}"#.utf8)),
            ("the same-app shortcut", Data(#"{"schemaVersion": 1, "shortcut": {"holdModifier": "option", "keyCode": 50}}"#.utf8)),
            ("shortcuts that collide", Data(#"""
                {"schemaVersion": 1, "shortcut": {"holdModifier": "control", "keyCode": 48},
                 "sameAppShortcut": {"holdModifier": "control", "keyCode": 48}}
                """#.utf8)),
        ]
        for (name, value) in cases {
            defaults.set(value, forKey: Settings.defaultsKey)
            XCTAssertEqual(store.load(), .default, name)
        }
    }

    func testResetIsRefusedWhenOptionTabIsTheSameAppShortcutSoSavedSettingsStillRead() throws {
        storeJSON(#"""
            {"schemaVersion": 1, "shortcut": {"holdModifier": "control", "keyCode": 48},
             "sameAppShortcut": {"holdModifier": "option", "keyCode": 48}}
            """#)
        var settings = store.load()
        let controlTab = try Shortcut(holdModifier: .control, keyCode: KeyCode.tab)
        XCTAssertEqual(settings.shortcut, controlTab)
        XCTAssertEqual(settings.sameAppShortcut, .default)
        XCTAssertThrowsError(try settings.resetShortcut()) { error in
            XCTAssertEqual(error as? Shortcut.Invalid, .sameAppShortcut(.default))
        }
        XCTAssertEqual(settings.shortcut, controlTab)
        store.save(settings)
        XCTAssertEqual(store.load(), settings)
        XCTAssertNotEqual(store.load(), .default)
    }

    func testAbsentKeysInVersionOneTakeTheirDefaults() {
        storeJSON(#"{"schemaVersion": 1, "shownWindows": {"windowlessApps": true}}"#)
        var expected = Settings.default
        expected.shownWindows.windowlessApps = true
        XCTAssertEqual(store.load(), expected)
    }

    func testUnreadableDataStaysUntilTheNextChangeOverwritesIt() throws {
        storeJSON(#"{"schemaVersion": 7}"#)
        var settings = store.load()
        XCTAssertEqual(settings, .default)
        XCTAssertEqual(defaults.data(forKey: Settings.defaultsKey), Data(#"{"schemaVersion": 7}"#.utf8), "reading never writes")
        settings.shownWindows.pointerDisplayOnly = true
        store.save(settings)
        XCTAssertEqual(store.load(), settings)
    }
}

/// The Shown-windows options and the excluded apps, applied after `WindowFilter` to a fixture list.
final class ShownWindowsTests: XCTestCase {
    private static func window(
        _ ref: UInt64,
        _ bundle: String,
        minimized: Bool = false,
        hidden: Bool = false,
        display: DisplayID?
    ) -> WindowEntry {
        WindowEntry(
            app: SourceApp(pid: pid_t(100 + ref), bundleIdentifier: bundle, name: bundle, isHidden: hidden),
            window: SourceWindow(ref: WindowRef(rawValue: ref), title: "", subrole: "AXStandardWindow", isMinimized: minimized,
                                 frame: CGRect(x: 0, y: 0, width: 400, height: 300)),
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            display: display
        )
    }

    private static func app(_ pid: pid_t, _ bundle: String, hidden: Bool = false) -> AppEntry {
        AppEntry(SourceApp(pid: pid, bundleIdentifier: bundle, name: bundle, isHidden: hidden))
    }

    /// Most recent first: a window on display 1, a minimized one on 1, a hidden app's on 2, another of the first app's
    /// on 2, and one on no display; then three windowless apps, one of them hidden.
    private let list = WindowList(
        windows: [
            window(0, "com.example.a", display: 1),
            window(1, "com.example.b", minimized: true, display: 1),
            window(2, "com.example.c", hidden: true, display: 2),
            window(3, "com.example.a", display: 2),
            window(4, "com.example.d", display: nil),
        ],
        windowlessApps: [app(200, "com.example.e"), app(201, "com.example.f", hidden: true), app(202, "com.example.g")]
    )

    private func ids(_ settings: Settings, pointer: DisplayID? = 1) -> [SwitcherItem.ID] {
        settings.items(from: list, pointerDisplay: pointer).map(\.id)
    }

    private func windows(_ refs: UInt64...) -> [SwitcherItem.ID] {
        refs.map { .window(WindowRef(rawValue: $0)) }
    }

    func testTheDefaultsShowEveryListedWindowInOrderAndNoAppCells() {
        XCTAssertEqual(ids(.default), windows(0, 1, 2, 3, 4))
    }

    func testMinimizedWindowsOff() {
        var settings = Settings.default
        settings.shownWindows.minimized = false
        XCTAssertEqual(ids(settings), windows(0, 2, 3, 4))
    }

    func testWindowsOfHiddenAppsOff() {
        var settings = Settings.default
        settings.shownWindows.hiddenApps = false
        XCTAssertEqual(ids(settings), windows(0, 1, 3, 4))
        settings.shownWindows.windowlessApps = true
        XCTAssertEqual(ids(settings), windows(0, 1, 3, 4) + [.app(200), .app(202)], "a hidden windowless app is left out too")
    }

    func testWindowlessAppsAppearAsAppCellsOnlyWhenOn() {
        var settings = Settings.default
        XCTAssertFalse(settings.items(from: list, pointerDisplay: 1).contains { $0.window == nil })
        settings.shownWindows.windowlessApps = true
        let items = settings.items(from: list, pointerDisplay: 1)
        XCTAssertEqual(items.map(\.id), windows(0, 1, 2, 3, 4) + [.app(200), .app(201), .app(202)])
        XCTAssertEqual(items[5], .app(Self.app(200, "com.example.e")))
        XCTAssertEqual(items[6].accessibilityLabel, "com.example.f, no open windows, hidden")
    }

    func testAnAppWhoseWindowsAnOptionRemovedGetsNoAppCell() {
        var settings = Settings.default
        settings.shownWindows.minimized = false
        settings.shownWindows.windowlessApps = true
        XCTAssertFalse(ids(settings).contains(.app(101)), "com.example.b has a window; it is minimized, not missing")
        XCTAssertFalse(ids(settings).contains(.window(WindowRef(rawValue: 1))))
    }

    func testThePointerDisplayFilterUsesEachEntrysDisplay() {
        var settings = Settings.default
        settings.shownWindows.pointerDisplayOnly = true
        XCTAssertEqual(ids(settings, pointer: 1), windows(0, 1))
        XCTAssertEqual(ids(settings, pointer: 2), windows(2, 3), "the same app's window on display 1 is left out")
        XCTAssertEqual(ids(settings, pointer: 3), [])
        XCTAssertEqual(ids(settings, pointer: nil), windows(0, 1, 2, 3, 4), "an unknown pointer display leaves nothing out")
        settings.shownWindows.windowlessApps = true
        XCTAssertEqual(ids(settings, pointer: 2), windows(2, 3) + [.app(200), .app(201), .app(202)], "app cells have no display")
    }

    func testExcludedAppsNeverAppear() {
        var settings = Settings.default
        settings.exclude("com.example.a")
        settings.exclude("com.example.g")
        XCTAssertEqual(ids(settings), windows(1, 2, 4))
        settings.shownWindows.windowlessApps = true
        XCTAssertEqual(ids(settings), windows(1, 2, 4) + [.app(200), .app(201)])
    }
}

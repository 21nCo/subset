import Foundation
import Testing
@testable import PointInTimeCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000) // a bucket boundary: 1_800_000_000 / 180 is whole

private func content(_ bundleID: String, title: String? = nil, url: String? = nil, policy: CapturePolicy = CapturePolicy()) -> Segment? {
    policy.content(for: Activity(bundleID: bundleID, appName: bundleID.uppercased(), windowTitle: title, url: url.flatMap(RedactedURL.init)), at: t0)
}

@Suite struct RedactedURLTests {
    @Test func dropsQueryFragmentCredentialsAndPort() throws {
        let url = try #require(RedactedURL("https://user:secret@Mail.Example.com:8443/inbox/42?token=abc&q=salary#msg-9"))
        #expect(url.string == "https://mail.example.com/inbox/42")
        #expect(!url.string.contains("token"))
        #expect(!url.string.contains("secret"))
    }

    @Test func emptyPathBecomesSlash() {
        #expect(RedactedURL("http://example.com?x=1")?.string == "http://example.com/")
    }

    @Test(arguments: ["file:///Users/me/secret.txt", "about:blank", "chrome://settings", "not a url", "https:///nohost"])
    func rejectsNonWebURLs(_ raw: String) {
        #expect(RedactedURL(raw) == nil)
    }

    @Test func hostAndPathAreBoundedInBytes() throws {
        let label = String(repeating: "a", count: 63)
        let longestHost = [label, label, label, String(repeating: "a", count: 57), "com"].joined(separator: ".")
        #expect(longestHost.utf8.count == RedactedURL.maxHostBytes)
        #expect(RedactedURL("https://\(longestHost)/x")?.host == longestHost)
        #expect(RedactedURL("https://a\(longestHost)/x") == nil)
        let url = try #require(RedactedURL("https://example.com/" + String(repeating: "p", count: 5_000)))
        #expect(url.path.utf8.count == RedactedURL.maxPathBytes)
        #expect(RedactedURL("https://example.com/caf%C3%A9")?.path == "/caf%C3%A9")
    }

    /// Characters with 1-, 2-, 3- and 4-byte UTF-8 encodings, and a literal percent sign.
    private static let escaped = ["\u{E9}", "\u{20AC}", "\u{1F600}", "%"]

    /// Pads the path so the 512-byte cut falls before, inside, and after the escapes of each character.
    @Test(arguments: escaped, 497...512)
    func pathCutsKeepWholeEscapesAndWholeCharacters(_ character: String, _ padding: Int) throws {
        let pieces = ["/"] + Array(repeating: "a", count: padding) + [character] + Array(repeating: "b", count: 20)
        let encoded = pieces.map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! }
        // The expected path: the longest run of whole pieces within the limit, computed apart from the implementation.
        var expected = ""
        for piece in encoded {
            guard expected.utf8.count + piece.utf8.count <= RedactedURL.maxPathBytes else { break }
            expected += piece
        }
        let url = try #require(RedactedURL("https://example.com" + encoded.joined() + "?q=secret#frag"))
        #expect(url.path == expected)
        #expect(url.path.utf8.count <= RedactedURL.maxPathBytes)
        #expect(url.path.removingPercentEncoding != nil)
        #expect(RedactedURL(url.string)?.path == url.path)
        #expect(!url.string.contains("secret") && !url.string.contains("frag"))
    }
}

@Suite struct PolicyTests {
    @Test func excludedTimeOnlyKeepsNoIdentity() throws {
        let segment = try #require(content("com.bank", title: "Balance 1234", url: "https://bank.example/acct", policy: CapturePolicy(excludedBundleIDs: ["com.bank"])))
        #expect(segment.excluded)
        #expect(segment.bundleID == nil && segment.appName == nil && segment.windowTitle == nil && segment.url == nil)
    }

    @Test func excludedNothingRecordsNothing() {
        #expect(content("com.bank", policy: CapturePolicy(excludedBundleIDs: ["com.bank"], exclusionMode: .nothing)) == nil)
    }

    @Test func excludedSegmentsDropAnyIdentityTheyAreGiven() {
        let segment = Segment(start: t0, end: t0 + 5, excluded: true, bundleID: "a", appName: "A", windowTitle: "Secret",
                              url: RedactedURL("https://example.com/x"))
        #expect(segment.bundleID == nil && segment.appName == nil && segment.windowTitle == nil && segment.url == nil)
    }

    @Test func titlesAreTrimmedAndCapped() {
        #expect(Activity(bundleID: "a", appName: "A", windowTitle: "   ").windowTitle == nil)
        #expect(Activity(bundleID: "a", appName: "A", windowTitle: String(repeating: "x", count: 1_000)).windowTitle?.count == Activity.maxTitleLength)
    }

    private static let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}" // one character, 25 bytes
    /// Title and the number of leading characters kept, keyed by name so the test log does not print 100,000 marks.
    private static let boundedTitles: [String: (String, Int)] = [
        "ordinary": (String(repeating: "x", count: 300), 300),
        "CJK at the character cap": (String(repeating: "\u{8A9E}", count: 300), 300),
        "CJK over the character cap": (String(repeating: "\u{8A9E}", count: 400), 300),
        "emoji ZWJ sequences": (String(repeating: family, count: 60), 48),
        "one character of combining marks": ("a" + String(repeating: "\u{0301}", count: 100_000), 0),
        "combining marks after a prefix": ("Repo" + "e" + String(repeating: "\u{0301}", count: 2_000), 4),
    ]

    @Test(arguments: boundedTitles.keys.sorted())
    func titlesAreBoundedInBytesOnCharacterBoundaries(_ name: String) throws {
        let (title, keptCharacters) = try #require(Self.boundedTitles[name])
        let stored = Activity(bundleID: "a", appName: "A", windowTitle: title).windowTitle
        #expect(stored.map { Array($0) } == (keptCharacters == 0 ? nil : Array(title.prefix(keptCharacters))), "\(name)")
        #expect((stored?.utf8.count ?? 0) <= Activity.maxTitleBytes, "\(name)")
        if keptCharacters == title.count { #expect(stored == title, "\(name)") }
    }

    /// A segment bounds its own text however it is built, so a caller that skips `Activity` stores no more.
    @Test func segmentsBoundTheirOwnTitle() throws {
        let marks = String(repeating: "\u{0301}", count: 100_000)
        func title(_ raw: String) -> String? {
            Segment(start: t0, end: t0 + 5, excluded: false, bundleID: "a", appName: "A", windowTitle: raw, url: nil).windowTitle
        }
        #expect(title("a" + marks) == nil)
        #expect(title("  Report" + marks) == "Repor")
        #expect(title(String(repeating: "\u{8A9E}", count: 400)) == String(repeating: "\u{8A9E}", count: 300))
        #expect(title("  Quarterly report \u{2013} draft  ") == "Quarterly report \u{2013} draft")
        // Trimming after the cut leaves no trailing space, so bounding a bounded title changes nothing.
        let cut = try #require(title(String(repeating: "x", count: 299) + " y"))
        #expect(cut == String(repeating: "x", count: 299) && Segment.boundedTitle(cut) == cut)
    }

    @Test func appIdentityIsBoundedAfterExclusionsMatchTheFullBundleID() throws {
        let longID = "com.example." + String(repeating: "x", count: 1_000)
        let heavyName = "App" + String(repeating: "\u{0301}", count: 100_000)
        let segment = try #require(CapturePolicy().content(for: Activity(bundleID: longID, appName: heavyName), at: t0))
        #expect(segment.bundleID == String(longID.prefix(Segment.maxIdentityBytes)))
        #expect(segment.appName == "Ap")
        let excluded = try #require(CapturePolicy(excludedBundleIDs: [longID]).content(for: Activity(bundleID: longID, appName: heavyName), at: t0))
        #expect(excluded.excluded && excluded.bundleID == nil && excluded.appName == nil)
        // Ordinary identities are untouched.
        #expect(content("com.apple.Safari")?.bundleID == "com.apple.Safari")
    }
}

@Suite struct SleepSignalsTests {
    enum Event: CaseIterable, Sendable {
        case systemWillSleep, systemDidWake, screensDidSleep, screensDidWake

        var isSystem: Bool { self == .systemWillSleep || self == .systemDidWake }
        var isSleep: Bool { self == .systemWillSleep || self == .screensDidSleep }

        func apply(to signals: inout SleepSignals) {
            switch self {
            case .systemWillSleep: signals.systemWillSleep()
            case .systemDidWake: signals.systemDidWake()
            case .screensDidSleep: signals.screensDidSleep()
            case .screensDidWake: signals.screensDidWake()
            }
        }
    }

    /// Both sleeps in either order, then both wakes in either order: asleep until the second wake.
    @Test(arguments: [[Event.screensDidSleep, .systemWillSleep], [.systemWillSleep, .screensDidSleep]],
          [[Event.systemDidWake, .screensDidWake], [.screensDidWake, .systemDidWake]])
    func theMacStaysAsleepUntilBothHaveWoken(sleeps: [Event], wakes: [Event]) {
        var signals = SleepSignals()
        for event in sleeps { event.apply(to: &signals) }
        #expect(signals.asleep)
        wakes[0].apply(to: &signals)
        #expect(signals.asleep, "\(wakes[0]) alone woke the Mac")
        wakes[1].apply(to: &signals)
        #expect(!signals.asleep)
    }

    /// Every sequence of up to six notifications, duplicates and wakes without a sleep included: the Mac is asleep
    /// exactly when the latest system notification or the latest display notification was a sleep.
    @Test func everyOrderAndDuplicateKeepsTheOtherConditionUnchanged() {
        var sequences: [[Event]] = [[]]
        for _ in 0..<6 {
            sequences = sequences.flatMap { prefix in Event.allCases.map { prefix + [$0] } }
            for sequence in sequences {
                var signals = SleepSignals()
                for event in sequence { event.apply(to: &signals) }
                let system = sequence.last { $0.isSystem }?.isSleep ?? false
                let display = sequence.last { !$0.isSystem }?.isSleep ?? false
                #expect(signals.systemAsleep == system && signals.displayAsleep == display && signals.asleep == (system || display),
                        "\(sequence)")
            }
        }
    }
}

@Suite struct RecorderTests {
    @Test func extendsSameContentAndSplitsOnChange() {
        var recorder = SegmentRecorder()
        #expect(recorder.record(content("a"), at: t0).isEmpty)
        #expect(recorder.record(content("a"), at: t0 + 5).isEmpty)
        let closed = recorder.record(content("b"), at: t0 + 10)
        #expect(closed.count == 1)
        #expect(closed.first?.bundleID == "a" && closed.first?.start == t0 && closed.first?.end == t0 + 10)
        #expect(recorder.open?.bundleID == "b" && recorder.open?.start == t0 + 10)
    }

    @Test func titleChangeStartsNewSegment() {
        var recorder = SegmentRecorder()
        _ = recorder.record(content("a", title: "one"), at: t0)
        #expect(recorder.record(content("a", title: "two"), at: t0 + 5).count == 1)
    }

    @Test func idleGapEndsWhenIdleBegan() {
        var recorder = SegmentRecorder()
        for second in stride(from: 0.0, through: 150, by: 5) { _ = recorder.record(content("a"), at: t0 + second) }
        let closed = recorder.gap(at: t0 + 30) // idle began 120 s before the sample at 150
        #expect(closed?.end == t0 + 30)
        #expect(recorder.open == nil)
    }

    @Test func gapNeverInventsTimeBeyondOneInterval() {
        var recorder = SegmentRecorder(maxSampleInterval: 30)
        _ = recorder.record(content("a"), at: t0)
        _ = recorder.record(content("a"), at: t0 + 5)
        let closed = recorder.gap(at: t0 + 3_600) // sleep notification delivered late
        #expect(closed?.end == t0 + 35)
    }

    @Test func missedSamplesCloseAtLastConfirmation() {
        var recorder = SegmentRecorder(maxSampleInterval: 30)
        _ = recorder.record(content("a"), at: t0)
        _ = recorder.record(content("a"), at: t0 + 5)
        let closed = recorder.record(content("a"), at: t0 + 600) // process was suspended
        #expect(closed.first?.end == t0 + 5)
        #expect(recorder.open?.start == t0 + 600)
    }

    @Test func clockStepBackDoesNotOverlap() {
        var recorder = SegmentRecorder()
        _ = recorder.record(content("a"), at: t0)
        _ = recorder.record(content("a"), at: t0 + 20)
        let closed = recorder.record(content("b"), at: t0 + 10)
        #expect(closed.first?.end == t0 + 20)
        #expect(recorder.open == nil)
        _ = recorder.record(content("b"), at: t0 + 21)
        #expect(recorder.open?.start == t0 + 21)
    }

    @Test func idleBeginningBeforeTheSegmentReturnsItEmptyForRetraction() throws {
        var recorder = SegmentRecorder()
        for second in stride(from: 0.0, through: 60, by: 5) { _ = recorder.record(content("a"), at: t0 + second) }
        // The host flushed [t0, t0 + 60]; idle turns out to have begun before the segment opened.
        let gap = recorder.gap(at: t0 - 10)
        let closed = try #require(gap)
        #expect(closed.start == t0 && closed.duration == 0)
        #expect(recorder.open == nil)
        #expect(recorder.record(content("a"), at: t0 + 200).isEmpty)
        #expect(recorder.open?.start == t0 + 200)
    }

    @Test func recordNeverReturnsEmptySegments() {
        var recorder = SegmentRecorder()
        _ = recorder.record(content("a"), at: t0)
        #expect(recorder.record(content("b"), at: t0).isEmpty)
    }

    @Test func nilContentClosesWithoutOpening() {
        var recorder = SegmentRecorder()
        _ = recorder.record(content("a"), at: t0)
        #expect(recorder.record(nil, at: t0 + 5).first?.end == t0 + 5)
        #expect(recorder.open == nil)
    }
}

@Suite struct SequencerTests {
    private func sequencer() -> CaptureSequencer { CaptureSequencer(recorder: SegmentRecorder(maxSampleInterval: 30)) }

    private func read(_ sequencer: inout CaptureSequencer, _ pid: Int32, _ date: Date) -> CaptureSequencer.Ticket? {
        sequencer.beginRead(of: pid, at: date)
    }

    /// Reads one sample of `bundleID` (pid `pid`) at `second` and finishes it immediately.
    private func readNow(_ sequencer: inout CaptureSequencer, _ bundleID: String, pid: Int32, at second: TimeInterval) -> [Segment] {
        guard let ticket = sequencer.beginRead(of: pid, at: t0 + second) else { return [] }
        return sequencer.complete(ticket, with: content(bundleID))
    }

    @Test func lateReadCannotBridgeAnotherAppInBetween() throws {
        // A -> B -> A within one read's latency: A's first read finishes only after A is back in front.
        var sequencer = sequencer()
        let lateA = try #require(read(&sequencer, 1, t0))
        _ = sequencer.foregroundChanged(at: t0 + 2)
        #expect(read(&sequencer, 2, t0 + 2) == nil) // B waits behind the slow read
        _ = sequencer.foregroundChanged(at: t0 + 4)
        #expect(read(&sequencer, 1, t0 + 4) == nil)
        let lateClosed = sequencer.complete(lateA, with: content("a"))
        #expect(lateClosed.isEmpty && sequencer.open == nil)
        let a = try #require(read(&sequencer, 1, t0 + 6))
        _ = sequencer.complete(a, with: content("a"))
        _ = readNow(&sequencer, "a", pid: 1, at: 9)
        #expect(sequencer.open?.bundleID == "a" && sequencer.open?.start == t0 + 6)
    }

    @Test func foregroundChangeEndsTheOpenSegmentSoTheSameAppCannotResumeIt() throws {
        var sequencer = sequencer()
        _ = readNow(&sequencer, "a", pid: 1, at: 0)
        _ = readNow(&sequencer, "a", pid: 1, at: 5)
        let closed = sequencer.foregroundChanged(at: t0 + 7) // B came to the front; its read never lands
        #expect(closed.first?.end == t0 + 7)
        _ = sequencer.foregroundChanged(at: t0 + 12) // A again
        _ = readNow(&sequencer, "a", pid: 1, at: 12)
        #expect(sequencer.open?.start == t0 + 12)
    }

    @Test(arguments: [nil, CapturePolicy(excludedBundleIDs: ["x"], exclusionMode: .nothing)])
    func lateReadCannotBridgeTimeThatRecordsNothing(_ policy: CapturePolicy?) throws {
        // A -> pointInTime (nil) or A -> an app excluded with "record nothing" -> A, seen only by the sample timer.
        var sequencer = sequencer()
        let lateA = try #require(read(&sequencer, 1, t0))
        let nothing = policy.flatMap { content("x", policy: $0) }
        #expect(nothing == nil)
        _ = sequencer.sample(nothing, at: t0 + 5)
        _ = sequencer.sample(nothing, at: t0 + 10)
        #expect(read(&sequencer, 1, t0 + 15) == nil) // A is back, behind its own slow read
        let lateClosed = sequencer.complete(lateA, with: content("a"))
        #expect(lateClosed.isEmpty && sequencer.open == nil)
        let a = try #require(read(&sequencer, 1, t0 + 16))
        _ = sequencer.complete(a, with: content("a"))
        #expect(sequencer.open?.start == t0 + 16)
    }

    @Test func aNothingSampleStopsEarlierSamplesFromOpeningAfterIt() {
        var recorder = SegmentRecorder()
        _ = recorder.record(nil, at: t0 + 10)
        let closed = recorder.record(content("a"), at: t0)
        #expect(closed.isEmpty && recorder.open == nil)
    }

    @Test func gapVoidsReadsInFlight() throws {
        var sequencer = sequencer()
        let ticket = try #require(read(&sequencer, 1, t0))
        _ = sequencer.gap(at: t0 + 1)
        let closed = sequencer.complete(ticket, with: content("a"))
        #expect(closed.isEmpty && sequencer.open == nil)
    }

    @Test func oneReadInFlightAcrossForegrounds() throws {
        var sequencer = sequencer()
        let first = try #require(read(&sequencer, 1, t0))
        #expect(read(&sequencer, 1, t0 + 5) == nil) // a slow app does not build a backlog
        // Nor do app switches: the read of app 2 waits, and app 1's read is already void.
        #expect(read(&sequencer, 2, t0 + 6) == nil)
        #expect(read(&sequencer, 3, t0 + 7) == nil)
        #expect(!sequencer.isCurrent(first))
        #expect(sequencer.complete(first, with: content("a")).isEmpty && sequencer.open == nil)
        let third = try #require(read(&sequencer, 3, t0 + 8)) // the app in front now is read once the slow read ends
        #expect(sequencer.isCurrent(third))
        _ = sequencer.complete(third, with: content("c"))
        #expect(sequencer.open?.bundleID == "c" && sequencer.open?.start == t0 + 8)
    }
}

@Suite struct WindowPrivacyTests {
    private let query = "https://example.com/pit/page?secret=abc#frag"

    private func scriptable(_ report: BrowserWindowReport, focusedTitle: String? = "Focused", readsTitles: Bool = true) -> (title: String?, url: RedactedURL?) {
        WindowPrivacy.reduce(focusedTitle: focusedTitle, readsTitles: readsTitles, support: .scriptable, report: report, privateTitles: titles)
    }

    /// A Chromium browser answering get-data events from fixed windows and tabs. It logs every event, and its active
    /// tab can switch after each event, as a user switching tabs mid-read would.
    private final class FakeChromium: ChromiumScripting {
        struct Failed: Error {}
        var mode: String? = "normal"
        var tabs: [Int: (title: String?, url: String?)] = [1: ("Example Domain", "https://example.com/pit/page?secret=abc#frag")]
        /// The active tab before each successive event; the last entry stays.
        var activeTabs = [1]
        var failing: Set<String> = []
        private(set) var events: [String] = []

        private func send(_ event: String) throws {
            events.append(event)
            if failing.contains(event) { throw Failed() }
        }
        private var active: Int { activeTabs[min(events.count - 1, activeTabs.count - 1)] }

        func frontWindowID() throws -> Int { try send("window"); return 7 }
        func mode(ofWindow window: Int) throws -> String? { try send("mode"); return mode }
        func activeTabID(ofWindow window: Int) throws -> Int { try send("activeTab"); return active }
        func title(ofTab tab: Int, inWindow window: Int) throws -> String? { try send("title"); return tabs[tab]?.title }
        func url(ofTab tab: Int, inWindow window: Int) throws -> String? { try send("url"); return tabs[tab]?.url }
    }

    private func chromium(_ configure: (FakeChromium) -> Void = { _ in }) -> (report: BrowserWindowReport, events: [String]) {
        let browser = FakeChromium()
        configure(browser)
        return (.chromium(reading: browser), browser.events)
    }

    @Test func chromiumIncognitoKeepsNoTitleOrURL() {
        let read = chromium { $0.mode = "incognito" }
        #expect(read.report == .privateWindow)
        let kept = scriptable(read.report, focusedTitle: "Bank statement - Google Chrome (Incognito)")
        #expect(kept.title == nil && kept.url == nil)
    }

    @Test func chromiumPrivateOrUnconfirmedWindowIsNeverAskedForATab() {
        // The window's mode is read first; a private window's tabs are never asked for their title or URL.
        for mode in ["incognito", nil] as [String?] {
            let read = chromium { $0.mode = mode }
            #expect(read.events == ["window", "mode"], "\(String(describing: mode))")
        }
    }

    @Test func chromiumNormalWindowKeepsItsOwnTitleAndRedactedURL() {
        let read = chromium()
        #expect(read.events == ["window", "mode", "activeTab", "title", "url"])
        let kept = scriptable(read.report)
        #expect(kept.title == "Example Domain")
        #expect(kept.url?.string == "https://example.com/pit/page")
    }

    @Test func chromiumTitleAndURLComeFromOneTabWhenTheUserSwitchesTabsMidRead() {
        // Tab 1 is active when the read resolves the tab; tab 2 is active by the time the title and URL are read.
        let read = chromium {
            $0.tabs = [1: ("Work", "https://work.example/doc"), 2: ("Bank", "https://bank.example/account")]
            $0.activeTabs = [1, 1, 1, 2]
        }
        #expect(read.report == .normal(title: "Work", url: "https://work.example/doc"))
    }

    @Test func chromiumTitleNeverComesFromAnotherFocusedWindow() {
        // Accessibility focus can sit on an incognito window while the scripted window is a normal one.
        let kept = scriptable(chromium().report, focusedTitle: "Secret - Google Chrome (Incognito)")
        #expect(kept.title == "Example Domain")
    }

    @Test func chromiumTitlesNeedAccessibility() {
        let kept = scriptable(chromium().report, focusedTitle: nil, readsTitles: false)
        #expect(kept.title == nil && kept.url?.string == "https://example.com/pit/page")
    }

    @Test func chromiumWithoutConfirmationKeepsNothing() {
        // No Automation or a failed or timed-out event at any step, or a dictionary without `mode`.
        var reports = ["window", "mode", "activeTab", "title", "url"].map { event in chromium { $0.failing = [event] }.report }
        reports.append(chromium { $0.mode = nil }.report)
        for report in reports {
            #expect(report == .unconfirmed)
            let kept = scriptable(report)
            #expect(kept.title == nil && kept.url == nil)
        }
    }

    @Test func chromiumNormalModeWithAPrivateMarkerKeepsNothingAndSkipsTheURL() {
        let read = chromium { $0.tabs = [1: ("New Incognito Tab", "https://example.com/?q=secret")] }
        #expect(read.report == .privateWindow)
        #expect(!read.events.contains("url"))
    }

    @Test func chromiumBlankTabIsNormalWithoutTitleOrURL() {
        let read = chromium { $0.tabs = [1: (nil, "")] }
        #expect(read.report == .normal(title: nil, url: nil))
    }

    private let titles = PrivateWindowTitles(tables: [
        [PrivateWindowTitles.formatKey: "%@, „Privates Surfen“", PrivateWindowTitles.titleKey: "Privates Surfen"],
        [PrivateWindowTitles.formatKey: "\u{200F}%@، التصفح الخاص", PrivateWindowTitles.titleKey: "تصفح خاص"]
    ])

    private func titleOnly(_ title: String?, readsTitles: Bool = true) -> (title: String?, url: RedactedURL?) {
        WindowPrivacy.reduce(focusedTitle: title, readsTitles: readsTitles, support: .titleOnly,
                             report: .normal(title: "Ignored", url: query), privateTitles: titles)
    }

    @Test func safariNormalWindowKeepsItsTitleButNeverAURL() {
        let kept = titleOnly("Personal — Example Domain")
        #expect(kept.title == "Personal — Example Domain" && kept.url == nil)
    }

    @Test func safariPrivateWindowWithAPageKeepsNothing() {
        // Observed on macOS 26 / Safari 26: a private window's Accessibility title is "%@, Private Browsing".
        let kept = titleOnly("Example Domain, Private Browsing")
        #expect(kept.title == nil && kept.url == nil)
    }

    @Test func safariBlankOrLockedPrivateWindowKeepsNothing() {
        for title in ["Private Browsing", "Privates Surfen", "تصفح خاص"] {
            #expect(titleOnly(title).title == nil, "\(title)")
        }
    }

    @Test func safariLocalizedPrivateTitlesKeepNothing() {
        // No English marker, so only Safari's own string tables recognize these.
        for title in ["Inbox, „Privates Surfen“", "\u{200F}Inbox، التصفح الخاص"] {
            #expect(!WindowPrivacy.looksPrivate(title: title))
            #expect(titleOnly(title).title == nil, "\(title)")
        }
    }

    @Test func englishPrivateTitlesApplyWithoutSafarisStringTables() {
        #expect(PrivateWindowTitles.english.matches("Private Browsing"))
        #expect(PrivateWindowTitles.english.matches("Inbox, Private Browsing"))
        #expect(!PrivateWindowTitles.english.matches("Inbox"))
        #expect(!titles.matches("Privates Surfen und mehr") && titles.matches("Private Browsing"))
    }

    @Test func titleOnlyAppsDropMarkedPrivateTitlesAndNeverKeepAURL() {
        let markedPrivate = titleOnly("Example Domain — Private Browsing")
        #expect(markedPrivate.title == nil && markedPrivate.url == nil)
        let normal = titleOnly("Notes — Project plan")
        #expect(normal.title == "Notes — Project plan" && normal.url == nil)
        #expect(titleOnly("Notes — Project plan", readsTitles: false).title == nil)
    }

    private func kept(_ bundleID: String, title: String, opensWebURLs: Bool? = true,
                      report: BrowserWindowReport = .unconfirmed) -> (title: String?, url: RedactedURL?) {
        let support = BrowserSupport.forApp(bundleID, opensWebURLs: opensWebURLs)
        return WindowPrivacy.reduce(focusedTitle: title, readsTitles: true, support: support, report: report, privateTitles: titles)
    }

    @Test func firefoxFamilyBrowsersKeepOnlyTheApp() {
        // German and French private windows carry no English marker, so a title rule would have kept them.
        let titles = ["Example Domain – Privater Modus", "Example Domain — Navigation privée", "Example Domain — Mozilla Firefox"]
        for bundleID in ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly", "org.mozilla.firefoxbeta"] {
            // Known even when the Info.plist reports no web URL scheme.
            #expect(BrowserSupport.forApp(bundleID, opensWebURLs: false) == .appOnly, "\(bundleID)")
            for title in titles {
                let result = kept(bundleID, title: title, report: .normal(title: title, url: query))
                #expect(result.title == nil && result.url == nil, "\(title)")
            }
        }
        #expect(!WindowPrivacy.looksPrivate(title: titles[0]) && !WindowPrivacy.looksPrivate(title: titles[1]))
    }

    @Test func unlistedBrowsersKeepOnlyTheApp() {
        // Chrome Canary's German incognito title has no English marker, so the title rule alone would have kept it.
        let incognito = "Neuer Tab – Google Chrome Canary – Inkognito"
        #expect(!WindowPrivacy.looksPrivate(title: incognito))
        for bundleID in ["com.google.Chrome.canary", "com.google.Chrome.beta", "com.microsoft.edgemac.Beta", "org.chromium.Chromium",
                         "com.operasoftware.Opera", "com.kagi.kagimacOS", "com.duckduckgo.macos.browser"] {
            for opens in [true, false, nil] as [Bool?] {
                #expect(BrowserSupport.forApp(bundleID, opensWebURLs: opens) == .appOnly, "\(bundleID)")
            }
            #expect(kept(bundleID, title: incognito).title == nil)
        }
        // A browser on no list is recognized by the web URL scheme in its Info.plist, or fails closed when it is unreadable.
        #expect(kept("com.example.newbrowser", title: incognito, opensWebURLs: true).title == nil)
        #expect(kept("com.example.newbrowser", title: incognito, opensWebURLs: nil).title == nil)
    }

    @Test func safariAndAppsThatAreNotBrowsersKeepTheirTitles() {
        // Safari opens web URLs but keeps titles, minus its private-window titles.
        #expect(BrowserSupport.forApp(BrowserSupport.safari, opensWebURLs: true) == .titleOnly)
        #expect(kept(BrowserSupport.safari, title: "Example Domain").title == "Example Domain")
        #expect(kept(BrowserSupport.safari, title: "Example Domain, Private Browsing").title == nil)
        #expect(BrowserSupport.forApp("com.apple.SafariTechnologyPreview", opensWebURLs: true) == .appOnly)
        let notes = kept("com.apple.TextEdit", title: "Project plan.rtf", opensWebURLs: false)
        #expect(notes.title == "Project plan.rtf" && notes.url == nil)
    }

    @Test func listedChromiumWithoutAutomationKeepsOnlyTheApp() {
        // Without Automation the reader sends no events and its report stays unconfirmed; the Accessibility title is
        // never used for a listed Chromium browser, so a localized incognito title is not kept either.
        #expect(BrowserSupport.forApp("com.google.Chrome", opensWebURLs: true) == .scriptable)
        let result = kept("com.google.Chrome", title: "Neuer Tab – Inkognito")
        #expect(result.title == nil && result.url == nil)
    }

    @Test func onlyTheListedChromiumBrowsersAreScriptable() {
        #expect(Set(BrowserSupport.scriptableChromium.keys) == ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser"])
        // Vivaldi and Aside answer the same Chromium events but are not on the SET-19 list: app name only, even when a
        // normal window would report a title and URL, and even if their Info.plist cannot be read or declares no web scheme.
        for bundleID in ["com.vivaldi.Vivaldi", "at.studio.AsideBrowser"] {
            for opens in [true, false, nil] as [Bool?] {
                #expect(BrowserSupport.forApp(bundleID, opensWebURLs: opens) == .appOnly, "\(bundleID)")
            }
            let result = kept(bundleID, title: "Example Domain", report: .normal(title: "Example Domain", url: query))
            #expect(result.title == nil && result.url == nil)
        }
    }

    @Test func webURLSchemesAreReadFromURLTypes() {
        #expect(BrowserSupport.declaresWebURLs([["CFBundleURLName": "Web site URL", "CFBundleURLSchemes": ["http", "https"]]]))
        #expect(BrowserSupport.declaresWebURLs([["CFBundleURLSchemes": ["myapp"]], ["CFBundleURLSchemes": ["HTTPS"]]]))
        #expect(!BrowserSupport.declaresWebURLs([["CFBundleURLSchemes": ["myapp", "httpx"]]]))
        #expect(!BrowserSupport.declaresWebURLs(nil) && !BrowserSupport.declaresWebURLs("https"))
    }
}

@Suite struct BlockTests {
    private func segment(_ bundleID: String?, _ from: TimeInterval, _ to: TimeInterval, title: String? = nil, excluded: Bool = false) -> Segment {
        Segment(start: t0 + from, end: t0 + to, excluded: excluded, bundleID: bundleID, appName: bundleID?.uppercased(), windowTitle: title, url: nil)
    }

    @Test func bucketsAlignToEpochMultiplesOfThreeMinutes() {
        #expect(Block.bucketStart(containing: t0 + 179.9) == t0)
        #expect(Block.bucketStart(containing: t0 + 180) == t0 + 180)
        #expect(Block.bucketStarts(from: t0 + 170, to: t0 + 370) == [t0, t0 + 180, t0 + 360])
        #expect(Block.bucketStarts(from: t0 + 170, to: t0 + 170).isEmpty && Block.bucketStarts(from: t0 + 370, to: t0 + 170).isEmpty)
    }

    @Test func localMidnightIsABucketBoundaryInEveryWholeQuarterHourZone() throws {
        for identifier in ["Asia/Kolkata", "Asia/Kathmandu", "America/St_Johns", "Australia/Eucla", "Pacific/Chatham", "UTC"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(identifier: identifier))
            let midnight = calendar.startOfDay(for: t0)
            #expect(Block.bucketStart(containing: midnight) == midnight, "\(identifier)")
        }
    }

    @Test func splitsSegmentAcrossBucketsAndPicksDominant() throws {
        let segments = [segment("b", 0, 100, title: "long"), segment("a", 100, 170, title: "short"), segment("a", 170, 200, title: "tail")]
        let first = try #require(Block.rollUp(start: t0, segments: segments))
        #expect(first.activeSeconds == 180)
        #expect(first.apps.map(\.bundleID) == ["b", "a"])
        #expect(first.dominantTitle == "long")
        let second = try #require(Block.rollUp(start: t0 + 180, segments: segments))
        #expect(second.activeSeconds == 20 && second.dominantTitle == "tail")
    }

    @Test func excludedTimeIsCountedSeparately() throws {
        let block = try #require(Block.rollUp(start: t0, segments: [segment(nil, 0, 60, excluded: true), segment("a", 60, 90)]))
        #expect(block.excludedSeconds == 60 && block.activeSeconds == 30)
        #expect(Block.rollUp(start: t0 + 180, segments: [segment("a", 0, 90)]) == nil)
    }

    @Test func tiesResolveByBundleID() throws {
        let block = try #require(Block.rollUp(start: t0, segments: [segment("z", 0, 50), segment("m", 50, 100)]))
        #expect(block.dominantBundleID == "m")
    }
}

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

    @Test func titlesAreTrimmedAndCapped() {
        #expect(Activity(bundleID: "a", appName: "A", windowTitle: "   ").windowTitle == nil)
        #expect(Activity(bundleID: "a", appName: "A", windowTitle: String(repeating: "x", count: 1_000)).windowTitle?.count == Activity.maxTitleLength)
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
        // A -> B -> A within one read's latency: A's first read finishes last of all.
        var sequencer = sequencer()
        let lateA = try #require(read(&sequencer, 1, t0))
        _ = sequencer.foregroundChanged(at: t0 + 2)
        let b = try #require(read(&sequencer, 2, t0 + 2))
        _ = sequencer.foregroundChanged(at: t0 + 4)
        let a = try #require(read(&sequencer, 1, t0 + 4))
        let lateClosed = sequencer.complete(lateA, with: content("a")), bClosed = sequencer.complete(b, with: content("b"))
        #expect(lateClosed.isEmpty && bClosed.isEmpty && sequencer.open == nil)
        _ = sequencer.complete(a, with: content("a"))
        _ = readNow(&sequencer, "a", pid: 1, at: 9)
        #expect(sequencer.open?.bundleID == "a" && sequencer.open?.start == t0 + 4)
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
        let a = try #require(read(&sequencer, 1, t0 + 15))
        let lateClosed = sequencer.complete(lateA, with: content("a"))
        #expect(lateClosed.isEmpty && sequencer.open == nil)
        _ = sequencer.complete(a, with: content("a"))
        #expect(sequencer.open?.start == t0 + 15)
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

    @Test func oneReadInFlightPerForeground() throws {
        var sequencer = sequencer()
        let first = try #require(read(&sequencer, 1, t0))
        #expect(read(&sequencer, 1, t0 + 5) == nil) // a slow app does not build a backlog
        sequencer.discard(first)
        let second = try #require(read(&sequencer, 1, t0 + 10)) // a dropped read frees the next sample
        _ = sequencer.complete(second, with: content("a"))
        #expect(read(&sequencer, 1, t0 + 15) != nil)
        #expect(read(&sequencer, 2, t0 + 16) != nil) // another app is read at once, behind nothing
    }
}

@Suite struct WindowPrivacyTests {
    private let query = "https://example.com/pit/page?secret=abc#frag"

    private func scriptable(_ report: BrowserWindowReport, focusedTitle: String? = "Focused", readsTitles: Bool = true) -> (title: String?, url: RedactedURL?) {
        WindowPrivacy.reduce(focusedTitle: focusedTitle, readsTitles: readsTitles, support: .scriptable, report: report, privateTitles: titles)
    }

    private func chromium(mode: String? = "normal", title: String? = "Example Domain", url: String? = nil) -> ScriptedWindow {
        ScriptedWindow(id: "7", mode: mode, title: title, url: url ?? query)
    }

    @Test func chromiumIncognitoKeepsNoTitleOrURL() {
        let kept = scriptable(.chromium(chromium(mode: "incognito")), focusedTitle: "Bank statement - Google Chrome (Incognito)")
        #expect(kept.title == nil && kept.url == nil)
    }

    @Test func chromiumNormalWindowKeepsItsOwnTitleAndRedactedURL() {
        let kept = scriptable(.chromium(chromium()))
        #expect(kept.title == "Example Domain")
        #expect(kept.url?.string == "https://example.com/pit/page")
    }

    @Test func chromiumTitleNeverComesFromAnotherFocusedWindow() {
        // Accessibility focus can sit on an incognito window while the scripted window is a normal one.
        let kept = scriptable(.chromium(chromium()), focusedTitle: "Secret - Google Chrome (Incognito)")
        #expect(kept.title == "Example Domain")
    }

    @Test func chromiumTitlesNeedAccessibility() {
        let kept = scriptable(.chromium(chromium()), focusedTitle: nil, readsTitles: false)
        #expect(kept.title == nil && kept.url?.string == "https://example.com/pit/page")
    }

    @Test func chromiumWithoutConfirmationKeepsNothing() {
        // A failed read (no Automation, an error or timeout) or a dictionary without `mode`.
        for report in [BrowserWindowReport.chromium(nil), .chromium(chromium(mode: nil))] {
            #expect(report == .unconfirmed)
            let kept = scriptable(report)
            #expect(kept.title == nil && kept.url == nil)
        }
    }

    @Test func chromiumNormalModeWithAPrivateMarkerKeepsNothing() {
        #expect(BrowserWindowReport.chromium(chromium(title: "New Incognito Tab")) == .privateWindow)
    }

    @Test func chromiumBlankTabIsNormalWithoutTitleOrURL() {
        #expect(BrowserWindowReport.chromium(chromium(title: nil, url: "")) == .normal(title: nil, url: nil))
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
        let firefoxPrivate = titleOnly("Example Domain — Private Browsing")
        #expect(firefoxPrivate.title == nil && firefoxPrivate.url == nil)
        let normal = titleOnly("Example Domain — Mozilla Firefox")
        #expect(normal.title == "Example Domain — Mozilla Firefox" && normal.url == nil)
        #expect(titleOnly("Example Domain — Mozilla Firefox", readsTitles: false).title == nil)
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

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

    @Test func nilContentClosesWithoutOpening() {
        var recorder = SegmentRecorder()
        _ = recorder.record(content("a"), at: t0)
        #expect(recorder.record(nil, at: t0 + 5).first?.end == t0 + 5)
        #expect(recorder.open == nil)
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

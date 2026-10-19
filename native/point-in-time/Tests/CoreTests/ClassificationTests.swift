import Foundation
import Security
import SQLite3
import Testing
@testable import PointInTimeCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("pit-classify-\(UUID().uuidString)", isDirectory: true)
}

private func block(_ index: Int, app: String = "com.example.editor", title: String? = "Draft — Notes", host: String? = "docs.example.com",
                   others: [AppTime] = []) -> Block {
    let start = t0.addingTimeInterval(Double(index) * Block.length)
    let apps = [AppTime(bundleID: app, appName: "App \(app)", seconds: 120)] + others
    return Block(start: start, activeSeconds: apps.reduce(0) { $0 + $1.seconds }, excludedSeconds: 0, apps: apps, dominantBundleID: app,
                 dominantAppName: "App \(app)", dominantTitle: title,
                 dominantURL: host.map { RedactedURL(scheme: "https", host: $0, path: "/page") })
}

private let noExclusions = ClassificationOptions(includeWindowTitles: true, excludedBundleIDs: [])

private func answer(_ entries: [(String, String, String, Double)]) -> String {
    let items = entries.map { ["id": $0.0, "label": $0.1, "reason": $0.2, "confidence": $0.3] as [String: Any] }
    return String(decoding: try! JSONSerialization.data(withJSONObject: ["blocks": items]), as: UTF8.self)
}

private func payload(_ request: ClassificationRequest) throws -> [String: Any] {
    let start = try #require(request.prompt.range(of: "<activity>\n")), end = try #require(request.prompt.range(of: "\n</activity>"))
    return try #require(JSONSerialization.jsonObject(with: Data(request.prompt[start.upperBound..<end.lowerBound].utf8)) as? [String: Any])
}

private func segment(_ start: Date, _ seconds: TimeInterval, _ bundleID: String?, excluded: Bool = false) -> Segment {
    Segment(start: start, end: start.addingTimeInterval(seconds), excluded: excluded, bundleID: bundleID, appName: bundleID, windowTitle: nil, url: nil)
}

/// The segment `store(withBlocksAt:)` saves for a block index.
private func specSegment(_ index: Int, app: String = "com.example.editor") -> Segment {
    let start = t0.addingTimeInterval(Double(index) * Block.length)
    return Segment(start: start, end: start.addingTimeInterval(150), excluded: false, bundleID: app, appName: "Editor", windowTitle: "Spec",
                   url: RedactedURL("https://docs.example.com/spec?q=secret"))
}

/// Saves one segment per block index, so the store holds real blocks.
private func store(withBlocksAt indexes: [Int], in directory: URL, app: String = "com.example.editor") throws -> ActivityStore {
    let store = try ActivityStore(directory: directory)
    for index in indexes { try store.save(specSegment(index, app: app)) }
    return store
}

@Suite struct RequestTests {
    @Test func windowTitlesAreSentOnlyWhenAllowed() throws {
        let on = try #require(ClassificationRequest(blocks: [block(0)], memory: "", corrections: [], options: noExclusions))
        let off = try #require(ClassificationRequest(blocks: [block(0)], memory: "", corrections: [],
                                                     options: ClassificationOptions(includeWindowTitles: false, excludedBundleIDs: [])))
        let sentOn = try #require((try payload(on))["blocks"] as? [[String: Any]]).first
        let sentOff = try #require((try payload(off))["blocks"] as? [[String: Any]]).first
        #expect(sentOn?["title"] as? String == "Draft — Notes")
        #expect(sentOff?["title"] == nil)
        #expect(!off.prompt.contains("Draft"))
        // Hosts, paths, and app names are sent either way.
        #expect(sentOff?["host"] as? String == "docs.example.com")
        #expect(sentOff?["path"] as? String == "/page")
        #expect(sentOff?["app"] as? String == "App com.example.editor")
        #expect(sentOff?["id"] as? String == "1800000000")
    }

    @Test func excludedAppsAreNeverSent() throws {
        let secret = AppTime(bundleID: "com.example.secret", appName: "Secret Diary", seconds: 30)
        let options = ClassificationOptions(includeWindowTitles: true, excludedBundleIDs: ["com.example.secret"])
        let blocks = [block(0, others: [secret]), block(1, app: "com.example.secret", title: "Dear diary", host: "diary.example.com")]
        let correction = LabelCorrection(block: block(2, app: "com.example.secret", title: "Diary entry", host: nil), previous: .focus,
                                         new: .drift, note: "never", at: t0)
        let request = try #require(ClassificationRequest(blocks: blocks, memory: "", corrections: [correction], options: options))
        // The block led by the excluded app is left out, and the excluded app is removed from the other block's apps.
        #expect(request.blocks.map(\.start) == [blocks[0].start])
        for text in ["com.example.secret", "Secret Diary", "diary", "Diary"] {
            #expect(!request.prompt.contains(text), "\(text) was sent")
        }
        #expect(ClassificationRequest(blocks: [blocks[1]], memory: "", corrections: [], options: options) == nil)
    }

    @Test func memoryIsCappedAt8KBOnWholeCharacters() throws {
        // 8,191 ASCII bytes and a 4-byte character that would cross the cap.
        let memory = String(repeating: "a", count: 8_191) + "😀" + "TAIL"
        let request = try #require(ClassificationRequest(blocks: [block(0)], memory: memory, corrections: [], options: noExclusions))
        let start = try #require(request.prompt.range(of: "<work_profile>\n")), end = try #require(request.prompt.range(of: "\n</work_profile>"))
        let sent = String(request.prompt[start.upperBound..<end.lowerBound])
        #expect(sent == String(repeating: "a", count: 8_191))
        #expect(ClassificationRequest.cap("short", bytes: 8_192) == "short")
    }

    @Test func batchesHoldAtMostTenBlocksAndTwentyCorrections() throws {
        let corrections = (0..<25).map { LabelCorrection(block: block(100 + $0), previous: nil, new: .focus, note: nil, at: t0) }
        let request = try #require(ClassificationRequest(blocks: (0..<15).map { block($0) }, memory: "", corrections: corrections, options: noExclusions))
        #expect(request.blocks.count == 10)
        #expect((try payload(request))["recentCorrections"] as? [Any] != nil)
        #expect(((try payload(request))["recentCorrections"] as? [Any])?.count == 20)
    }
}

@Suite struct ValidationTests {
    private let request = ClassificationRequest(blocks: [block(0), block(1)], memory: "", corrections: [], options: noExclusions)!

    @Test func acceptsOneValidEntryPerBlock() throws {
        let result = try request.validate(answer([("1800000000", "focus", "Writing the spec", 0.9), ("1800000180", "drift", "Video site", 0.6)]))
        #expect(result.accepted.map(\.label) == [.focus, .drift])
        #expect(result.accepted.map(\.reason) == ["Writing the spec", "Video site"])
        #expect(result.rejected.isEmpty)
    }

    @Test func badJSONAndUnknownIDsRejectTheWholeAnswer() {
        for text in ["not json", "[]", "{\"blocks\": 3}", "<b>focus</b>", "{\"blocks\": [], \"note\": \"extra\"}", answer([("1800000000", "focus", "ok", 0.9), ("1799999820", "focus", "ok", 0.9)]),
                     "{\"blocks\": [{\"label\": \"focus\"}]}"] {
            #expect(throws: ProviderError.self, "\(text)") { try request.validate(text) }
        }
    }

    @Test func missingDuplicatedAndInvalidEntriesStayPending() throws {
        let cases: [(String, [(String, String, String, Double)])] = [
            ("missing", [("1800000000", "focus", "ok", 0.9)]),
            ("duplicate", [("1800000000", "focus", "ok", 0.9), ("1800000180", "focus", "a", 0.5), ("1800000180", "drift", "b", 0.5)]),
            ("label", [("1800000000", "focus", "ok", 0.9), ("1800000180", "Focus", "ok", 0.5)]),
            ("reason length", [("1800000000", "focus", "ok", 0.9), ("1800000180", "focus", String(repeating: "r", count: 141), 0.5)]),
            ("empty reason", [("1800000000", "focus", "ok", 0.9), ("1800000180", "focus", "  ", 0.5)]),
            ("control character", [("1800000000", "focus", "ok", 0.9), ("1800000180", "focus", "line\nbreak", 0.5)]),
            ("confidence", [("1800000000", "focus", "ok", 0.9), ("1800000180", "focus", "ok", 1.5)])
        ]
        for (name, entries) in cases {
            let result = try request.validate(answer(entries))
            #expect(result.accepted.map(\.blockStart) == [block(0).start], "\(name)")
            #expect(result.rejected.map(\.start) == [block(1).start], "\(name)")
        }
        // Exactly 140 characters is allowed; a Boolean is not a confidence.
        #expect(try request.validate(answer([("1800000000", "focus", String(repeating: "é", count: 140), 1), ("1800000180", "neutral", "ok", 0)])).rejected.isEmpty)
        let boolean = #"{"blocks":[{"id":"1800000000","label":"focus","reason":"ok","confidence":true}]}"#
        #expect(try request.validate(boolean).accepted.isEmpty)
        // A property the schema does not allow leaves that block pending.
        let extra = #"{"blocks":[{"id":"1800000000","label":"focus","reason":"ok","confidence":0.9,"html":"<b>x</b>"}]}"#
        #expect(try request.validate(extra).rejected.map(\.start) == [block(0).start, block(1).start])
    }
}

/// A provider that answers from a queue and can run a hook while "in flight".
private final class StubProvider: ClassificationProvider, @unchecked Sendable {
    let name = "stub"
    let model: String
    var answers: [Result<String, ProviderError>] = []
    var prompts: [String] = []
    var whilePreparing: (@MainActor () async -> Void)?

    init(model: String = "stub-model") {
        self.model = model
    }
    var whileInFlight: (@MainActor () async -> Void)?

    func prepare() async throws {
        if let hook = whilePreparing { await hook() }
    }

    func complete(prompt: String, schema: String) async throws -> String {
        prompts.append(prompt)
        if let hook = whileInFlight { await hook() }
        guard !answers.isEmpty else { throw ProviderError.network("no answer queued") }
        return try answers.removeFirst().get()
    }
}

@MainActor
@Suite struct QueueTests {
    private final class Clock: @unchecked Sendable { var now = t0 }

    private func setup(_ indexes: [Int], deletionPending: @escaping @MainActor () -> Bool = { false }) throws -> (URL, ActivityStore, Clock, ClassificationRunner) {
        let directory = temporaryDirectory()
        let store = try store(withBlocksAt: indexes, in: directory)
        let clock = Clock()
        clock.now = t0.addingTimeInterval(Double((indexes.max() ?? 0) + 1) * Block.length + ClassificationRunner.settleDelay)
        return (directory, store, clock, ClassificationRunner(store: store, memory: { "I write specs." }, clock: { clock.now },
                                                              deletionPending: deletionPending))
    }

    private func id(_ index: Int) -> String { String(Int(t0.timeIntervalSince1970) + index * Int(Block.length)) }

    @Test func storesLabelsWithProviderModelAndTimeForCompletedBlocksOnly() async throws {
        let (directory, store, clock, runner) = try setup([0, 1])
        defer { try? FileManager.default.removeItem(at: directory) }
        // Block 1 ended less than the settle delay ago, so only block 0 is sent.
        clock.now = clock.now.addingTimeInterval(-Block.length)
        let provider = StubProvider()
        provider.answers = [.success(answer([(id(0), "focus", "Spec work", 0.8)]))]
        #expect(await runner.runOnce(provider: provider, options: noExclusions))
        #expect(provider.prompts.count == 1)
        #expect(!provider.prompts[0].contains(id(1)))
        #expect(provider.prompts[0].contains("I write specs."))
        let stored = try store.blocks(from: t0, to: t0.addingTimeInterval(1_000))
        #expect(stored[0].labeling == BlockLabeling(state: .classified, label: .focus, reason: "Spec work", confidence: 0.8,
                                                    provider: "stub", model: "stub-model", at: clock.now))
        #expect(stored[1].labeling == .pending)
        #expect(runner.status.lastSuccess == clock.now)
        // Without a provider nothing is sent and the block stays pending.
        clock.now = clock.now.addingTimeInterval(Block.length)
        #expect(await runner.runOnce(provider: nil, options: noExclusions) == false)
        #expect(runner.status.pending == 1)
    }

    @Test func sendsBatchesOfTenWithOneRequestInFlight() async throws {
        let (directory, store, _, runner) = try setup(Array(0..<12))
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = StubProvider()
        var secondCallStarted: Bool?
        provider.whileInFlight = {
            provider.whileInFlight = nil
            secondCallStarted = await runner.runOnce(provider: provider, options: noExclusions)
        }
        provider.answers = [.success(answer((2..<12).map { (self.id($0), "neutral", "ok", 0.5) }))]
        #expect(await runner.runOnce(provider: provider, options: noExclusions))
        #expect(secondCallStarted == false)
        #expect(provider.prompts.count == 1)
        #expect(try store.blocks(from: t0, to: t0.addingTimeInterval(3_000)).filter { $0.labeling.state == .classified }.count == 10)
        #expect(runner.status.pending == 2)
    }

    @Test func failuresBackOffExponentiallyAndResumeAfterWake() async throws {
        let (directory, _, clock, runner) = try setup([0])
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = StubProvider()
        var expected: [TimeInterval] = []
        for failure in 1...8 {
            provider.answers = [.failure(failure % 2 == 0 ? .process("exit 1") : .network("offline"))]
            #expect(await runner.runOnce(provider: provider, options: noExclusions) == false)
            let delay = try #require(runner.backoff.notBefore).timeIntervalSince(clock.now)
            expected.append(delay)
            // Nothing is sent before the backoff ends.
            clock.now = clock.now.addingTimeInterval(delay - 1)
            #expect(await runner.runOnce(provider: provider, options: noExclusions) == false)
            #expect(provider.prompts.count == failure)
            clock.now = clock.now.addingTimeInterval(1)
        }
        #expect(expected == [30, 60, 120, 240, 480, 960, 1_800, 1_800])
        #expect(runner.status.lastError == "exit 1")
        // A rate limit waits as long as the provider asks, past the usual cap.
        provider.answers = [.failure(.rateLimited(retryAfter: 2_000))]
        #expect(await runner.runOnce(provider: provider, options: noExclusions) == false)
        #expect(runner.backoff.notBefore == clock.now.addingTimeInterval(2_000))
        // A wake, the network returning, or a change to what is sent does not end the provider's wait.
        runner.resume()
        #expect(runner.backoff.notBefore == clock.now.addingTimeInterval(2_000))
        #expect(await runner.runOnce(provider: provider, options: noExclusions) == false)
        #expect(provider.prompts.count == 9)
        // Another provider, model, or key lets the next request go at once, and a success clears the error.
        runner.resume(providerChanged: true)
        provider.answers = [.success(answer([(id(0), "focus", "ok", 0.9)]))]
        #expect(await runner.runOnce(provider: provider, options: noExclusions))
        #expect(runner.backoff == ClassificationBackoff())
        #expect(runner.status.lastError == nil)
    }

    @Test func aFirstRateLimitWaitsAsLongAsTheProviderAsks() {
        var backoff = ClassificationBackoff()
        backoff.failed(at: t0, retryAfter: 120)
        #expect(backoff.notBefore == t0.addingTimeInterval(120))
        backoff.failed(at: t0, retryAfter: 10 * 24 * 3_600)
        #expect(backoff.notBefore == t0.addingTimeInterval(ClassificationBackoff.maximumRetryAfter))
    }

    @Test func onlyTheNetworkReturningCountsAsAReturn() {
        var tracker = ConnectivityTracker()
        // The first report, and changes while connected (a new interface, a VPN), are not a return.
        let returns = [true, true, false, false, true, true].map { tracker.update(available: $0) }
        #expect(returns == [false, false, false, false, true, false])
    }

    @Test func pendingBlocksSurviveFailuresAndARelaunch() async throws {
        let (directory, _, clock, runner) = try setup([0, 1])
        defer { try? FileManager.default.removeItem(at: directory) }
        let failing = StubProvider()
        failing.answers = [.failure(.network("offline"))]
        #expect(await runner.runOnce(provider: failing, options: noExclusions) == false)
        // A relaunch opens the store again with a fresh queue and sends the same blocks.
        let reopened = try ActivityStore(directory: directory)
        let relaunched = ClassificationRunner(store: reopened, memory: { "" }, clock: { clock.now })
        let provider = StubProvider()
        provider.answers = [.success(answer([(id(0), "focus", "a", 0.9), (id(1), "drift", "b", 0.4)]))]
        #expect(await relaunched.runOnce(provider: provider, options: noExclusions))
        #expect(try reopened.blocks(from: t0, to: t0.addingTimeInterval(1_000)).map(\.labeling.label) == [.focus, .drift])
    }

    @Test func invalidEntriesCountAttemptsUntilTheBlockFailsAndANewModelRetriesIt() async throws {
        let (directory, store, clock, runner) = try setup([0, 1])
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = StubProvider()
        // An unusable answer counts against the provider, not the blocks: nothing fails, however often it happens.
        provider.answers = Array(repeating: .success("nope"), count: 6)
        for _ in 0..<6 {
            #expect(await runner.runOnce(provider: provider, options: noExclusions) == false)
            runner.resume()
        }
        #expect(runner.status.pending == 2 && runner.status.failed == 0)
        // Block 1 is left out of five otherwise valid answers. A partly answered batch is not sent again at once.
        provider.answers = [.success(answer([(id(0), "focus", "ok", 0.9)]))] + Array(repeating: .success(answer([])), count: 4)
        #expect(await runner.runOnce(provider: provider, options: noExclusions) == false)
        for _ in 0..<4 {
            runner.resume()
            clock.now = clock.now.addingTimeInterval(1)
            await runner.runOnce(provider: provider, options: noExclusions)
        }
        let stored = try store.blocks(from: t0, to: t0.addingTimeInterval(1_000))
        #expect(stored[0].labeling.state == .classified)
        #expect(stored[1].labeling.state == .failed)
        #expect(runner.status.failed == 1)
        #expect(runner.status.pending == 0)
        // Another model gets a fresh set of attempts for the failed block.
        let other = StubProvider(model: "other-model")
        other.answers = [.success(answer([(id(1), "drift", "ok", 0.7)]))]
        runner.resume()
        #expect(await runner.runOnce(provider: other, options: noExclusions))
        #expect(try store.blocks(from: t0, to: t0.addingTimeInterval(1_000))[1].labeling.state == .classified)
        // Retry Failed does the same for the same provider.
        try store.save(segment(block(2).start, 60, "com.example.editor"))
        clock.now = clock.now.addingTimeInterval(Block.length * 2)
        for _ in 0..<5 { try store.applyClassifications([], rejected: try store.pendingBlocks(completedBy: clock.now, options: noExclusions, limit: 1),
                                                       provider: "stub", model: "other-model", at: clock.now) }
        #expect(try store.classificationSummary(completedBy: clock.now, options: noExclusions).failed == 1)
        try store.requeueFailed()
        #expect(try store.pendingBlocks(completedBy: clock.now, options: noExclusions, limit: 10).map(\.start) == [block(2).start])
    }

    @Test func aCorrectionOutranksALaterModelLabelAndIsSentAsContext() async throws {
        let (directory, store, _, runner) = try setup([0, 1])
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = StubProvider()
        // The user corrects block 0 while the request that includes it is in flight.
        provider.whileInFlight = {
            try? store.correct(blockStart: block(0).start, to: .drift, note: "Reading the news", at: t0)
        }
        provider.answers = [.success(answer([(id(0), "focus", "Model says focus", 0.9), (id(1), "focus", "ok", 0.9)]))]
        #expect(await runner.runOnce(provider: provider, options: noExclusions))
        let stored = try store.blocks(from: t0, to: t0.addingTimeInterval(1_000))
        #expect(stored[0].labeling.state == .corrected)
        #expect(stored[0].labeling.label == .drift)
        #expect(stored[0].labeling.reason == "Reading the news")
        #expect(stored[1].labeling.state == .classified)
        let corrections = try store.recentCorrections()
        #expect(corrections.map(\.previous) == [nil])
        #expect(corrections.map(\.new) == [.drift])
        // A second correction of a classified block records the model's label as the previous one.
        try store.correct(blockStart: block(1).start, to: .neutral, note: nil, at: t0.addingTimeInterval(1))
        #expect(try store.recentCorrections().map(\.previous) == [.focus, nil])
        let request = try #require(ClassificationRequest(blocks: [block(5)], memory: "", corrections: try store.recentCorrections(), options: noExclusions))
        #expect(request.prompt.contains("Reading the news"))
        #expect(((try payload(request))["recentCorrections"] as? [[String: Any]])?.first?["newLabel"] as? String == "neutral")
    }

    @Test func aQueuedDeletionSendsNothing() async throws {
        final class Box: @unchecked Sendable { var pending = true }
        let box = Box()
        let (directory, store, _, runner) = try setup([0], deletionPending: { box.pending })
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = StubProvider()
        provider.answers = [.success(answer([(id(0), "focus", "Spec work", 0.9)]))]
        #expect(await runner.runOnce(provider: provider, options: noExclusions) == false)
        // A Delete Today asked for while the provider prepares, and not applied yet, stops the request too.
        box.pending = false
        provider.whilePreparing = { box.pending = true }
        #expect(await runner.runOnce(provider: provider, options: noExclusions) == false)
        #expect(provider.prompts.isEmpty)
        #expect(try store.blocks(from: t0, to: t0.addingTimeInterval(180)).map(\.labeling) == [.pending])
        // Once it has been applied, the request goes.
        box.pending = false
        provider.whilePreparing = nil
        #expect(await runner.runOnce(provider: provider, options: noExclusions))
        #expect(provider.prompts.count == 1)
    }

    @Test func aDeletionWhileInFlightDropsOnlyTheAnswersItAffects() async throws {
        let (directory, store, _, runner) = try setup([0, 1])
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = StubProvider()
        // Delete All, then the same activity captured again at the same starts: an answer about the deleted blocks
        // does not label the new ones, even though their content is identical.
        provider.whileInFlight = {
            try? store.deleteAll()
            try? store.save(specSegment(0))
            try? store.save(specSegment(1))
        }
        provider.answers = [.success(answer([(id(0), "focus", "About the deleted spec", 0.9), (id(1), "focus", "ok", 0.9)]))]
        #expect(await runner.runOnce(provider: provider, options: noExclusions) == false)
        #expect(try store.blocks(from: t0, to: t0.addingTimeInterval(1_000)).map(\.labeling) == [.pending, .pending])
        // A discarded answer is not a success.
        #expect(runner.status.lastSuccess == nil)
        // An idle retraction of later time leaves the blocks that were sent, and their answer, alone.
        try store.save(segment(block(4).start, 60, "com.example.editor"))
        provider.whileInFlight = { try? store.deleteData(from: block(4).start, to: block(5).start) }
        provider.answers = [.success(answer([(id(0), "focus", "Spec work", 0.9), (id(1), "focus", "Spec work", 0.9)]))]
        runner.resume()
        #expect(await runner.runOnce(provider: provider, options: noExclusions))
        #expect(try store.blocks(from: t0, to: t0.addingTimeInterval(1_000)).map(\.labeling.state) == [.classified, .classified])
    }

    @Test func settingsChangedWhileTheProviderPreparesAreHonored() async throws {
        let (directory, _, _, runner) = try setup([0])
        defer { try? FileManager.default.removeItem(at: directory) }
        final class Box: @unchecked Sendable { var options: ClassificationOptions? = noExclusions }
        let box = Box(), provider = StubProvider()
        // Titles turned off while Codex's sign-in is checked: the request is built without them.
        provider.whilePreparing = { box.options = ClassificationOptions(includeWindowTitles: false, excludedBundleIDs: []) }
        provider.answers = [.failure(.network("offline"))]
        await runner.runOnce(provider: provider, options: box.options)
        #expect(provider.prompts.count == 1)
        #expect(!provider.prompts[0].contains("\"title\""))
        // The app excluded meanwhile: nothing is sent.
        runner.resume()
        box.options = noExclusions
        provider.whilePreparing = { box.options = ClassificationOptions(includeWindowTitles: true, excludedBundleIDs: ["com.example.editor"]) }
        #expect(await runner.runOnce(provider: provider, options: box.options) == false)
        // The provider turned off or changed meanwhile: nothing is sent, and the caller sets up the new one at once.
        box.options = noExclusions
        provider.whilePreparing = { box.options = nil }
        #expect(await runner.runOnce(provider: provider, options: box.options))
        #expect(provider.prompts.count == 1)
    }

    @Test func aLabelIsStoredOnlyForTheContentItJudged() async throws {
        let (directory, store, _, runner) = try setup([0, 1])
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = StubProvider()
        // A delayed capture write changes block 0 while the request that carries it is in flight.
        provider.whileInFlight = { try? store.save(segment(t0.addingTimeInterval(150), 20, "com.example.video")) }
        provider.answers = [.success(answer([(id(0), "focus", "Spec work", 0.9), (id(1), "focus", "Spec work", 0.9)]))]
        await runner.runOnce(provider: provider, options: noExclusions)
        var stored = try store.blocks(from: t0, to: t0.addingTimeInterval(1_000))
        #expect(stored.map(\.labeling.state) == [.pending, .classified])
        #expect(stored[0].revision > stored[1].revision)
        // A labeled block whose content changes afterwards is pending again; a corrected one keeps the user's label.
        try store.correct(blockStart: block(0).start, to: .drift, note: nil, at: t0)
        try store.save(segment(t0.addingTimeInterval(170), 5, "com.example.video"))
        try store.save(segment(block(1).start.addingTimeInterval(150), 20, "com.example.video"))
        stored = try store.blocks(from: t0, to: t0.addingTimeInterval(1_000))
        #expect(stored[0].labeling.state == .corrected && stored[0].labeling.label == .drift)
        #expect(stored[1].labeling == .pending)
        // Saving the same content again changes nothing.
        try store.save(segment(block(1).start.addingTimeInterval(150), 20, "com.example.video"))
        #expect(try store.blocks(from: t0, to: t0.addingTimeInterval(1_000))[1].revision == stored[1].revision)
    }
}

@Suite struct ClassificationStoreTests {
    @Test func migratingAVersion1StoreLeavesItsBlocksPending() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("activity.sqlite").path
        do {
            let connection = try SQLiteConnection(path: path)
            try connection.execute(try #require(ActivityStore.migrations[1]))
            try connection.execute("CREATE TABLE schema_version (version INTEGER PRIMARY KEY, applied_at REAL NOT NULL); INSERT INTO schema_version VALUES (1, 0);")
            try connection.execute("INSERT INTO blocks (start, active_seconds, excluded_seconds, apps_json) VALUES (1800000000, 60, 0, '[]')")
        }
        let store = try ActivityStore(directory: directory)
        #expect(try store.schemaVersion() == 2)
        #expect(try store.blocks(from: t0, to: t0.addingTimeInterval(180)).map(\.labeling) == [.pending])
    }

    @Test func correctionsAreDeletedWithTheirBlocks() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try store(withBlocksAt: [0, 1], in: directory)
        try store.correct(blockStart: block(0).start, to: .focus, note: "spec", at: t0)
        try store.correct(blockStart: block(1).start, to: .drift, note: nil, at: t0)
        try store.deleteData(from: block(1).start, to: .distantFuture)
        #expect(try store.recentCorrections().map(\.new) == [.focus])
        try store.deleteAll()
        // Recreating the block does not bring the deleted correction back.
        try store.save(segment(t0, 60, "b"))
        #expect(try store.recentCorrections().isEmpty)
        #expect(throws: StoreError.self) { try store.correct(blockStart: block(3).start, to: .focus, note: nil, at: t0) }
    }

    @Test func pendingBlocksSkipExcludedAndEmptyBlocks() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try store(withBlocksAt: [0], in: directory)
        try store.save(segment(block(1).start, 60, "com.example.secret"))
        try store.save(segment(block(2).start, 60, nil, excluded: true))
        let later = t0.addingTimeInterval(10_000)
        let options = ClassificationOptions(includeWindowTitles: false, excludedBundleIDs: ["com.example.secret"])
        #expect(try store.pendingBlocks(completedBy: later, options: options, limit: 10).map(\.start) == [block(0).start])
        #expect(try store.classificationSummary(completedBy: later, options: options).pending == 1)
        #expect(try store.pendingBlocks(completedBy: later, options: noExclusions, limit: 10).map(\.start) == [block(1).start, block(0).start])
    }
}

/// Records every Security call and answers from a script, with one item in each of the data protection and login
/// keychains.
private final class KeychainDouble: KeychainAPI, @unchecked Sendable {
    var calls: [(String, [String: Any])] = []
    /// Keyed by whether the query targets the data protection keychain.
    var stored: [Bool: Data] = [:]
    var dataProtectionMissing = false
    var failure: OSStatus?

    private func status(_ query: [String: Any], _ success: (Bool) -> OSStatus) -> OSStatus {
        let dataProtection = query[kSecUseDataProtectionKeychain as String] as? Bool == true
        if dataProtectionMissing, dataProtection { return errSecMissingEntitlement }
        return failure ?? success(dataProtection)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        calls.append(("add", attributes))
        return status(attributes) { stored[$0] = attributes[kSecValueData as String] as? Data; return errSecSuccess }
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
        calls.append(("copy", query))
        var value: Data?
        let result = status(query) { value = stored[$0]; return value == nil ? errSecItemNotFound : errSecSuccess }
        return (result, value as AnyObject?)
    }

    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        calls.append(("update", attributes))
        return status(query) {
            guard stored[$0] != nil else { return errSecItemNotFound }
            stored[$0] = attributes[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        calls.append(("delete", query))
        return status(query) { keychain in defer { stored[keychain] = nil }; return stored[keychain] == nil ? errSecItemNotFound : errSecSuccess }
    }
}

@Suite struct KeychainTests {
    @Test func savesAThisDeviceOnlyGenericPasswordAndReadsItBack() throws {
        let double = KeychainDouble()
        let secret = KeychainSecret(service: "svc", account: "acct", api: double)
        #expect(try secret.read() == nil)
        try secret.save("sk-or-1")
        let add = try #require(double.calls.first { $0.0 == "add" }?.1)
        #expect(add[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(add[kSecAttrService as String] as? String == "svc")
        #expect(add[kSecAttrAccount as String] as? String == "acct")
        #expect(add[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(add[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(add[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(try secret.read() == "sk-or-1")
        // Saving again updates the item instead of adding a second one.
        try secret.save("sk-or-2")
        #expect(double.calls.filter { $0.0 == "add" }.count == 1)
        #expect(try secret.read() == "sk-or-2")
        try secret.delete()
        try secret.delete()
        #expect(try secret.read() == nil)
    }

    @Test func fallsBackToTheLoginKeychainWithoutTheEntitlementAndReportsErrors() throws {
        let double = KeychainDouble()
        double.dataProtectionMissing = true
        let secret = KeychainSecret(service: "svc", account: "acct", api: double)
        try secret.save("sk-or-1")
        // The update is tried in the data protection keychain first; the item is then added to the login keychain only.
        #expect(double.calls.map(\.0) == ["update", "update", "add"])
        #expect(double.stored[false] != nil && double.stored[true] == nil)
        let adds = double.calls.filter { $0.0 == "add" }.map(\.1)
        #expect(adds.last?[kSecUseDataProtectionKeychain as String] == nil)
        #expect(adds.last?[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(try secret.read() == "sk-or-1")
        double.failure = errSecAuthFailed
        #expect(throws: KeychainError(status: errSecAuthFailed)) { try secret.read() }
        #expect(throws: KeychainError(status: errSecAuthFailed)) { try secret.save("x") }
        #expect(throws: KeychainError(status: errSecAuthFailed)) { try secret.delete() }
    }

    @Test func aKeyAnUnentitledBuildLeftInTheLoginKeychainIsFoundReplacedAndRemoved() throws {
        let double = KeychainDouble()
        double.stored[false] = Data("sk-or-old".utf8)
        let secret = KeychainSecret(service: "svc", account: "acct", api: double)
        #expect(try secret.read() == "sk-or-old")
        // Saving puts the key in the data protection keychain and removes the login-keychain copy.
        try secret.save("sk-or-new")
        #expect(double.stored == [true: Data("sk-or-new".utf8)])
        #expect(try secret.read() == "sk-or-new")
        // Remove Key clears both keychains.
        double.stored[false] = Data("sk-or-old".utf8)
        try secret.delete()
        #expect(double.stored.isEmpty)
        #expect(try secret.read() == nil)
    }
}

@Suite struct CodexTests {
    /// A stand-in `codex`: `login status` succeeds only when `signed-in` exists beside it; `exec` records its arguments,
    /// working folder, stdin, and PATH, optionally sleeps, and writes `answer` to the `-o` file.
    private func stub() throws -> URL {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("codex")
        try """
            #!/bin/sh
            dir="${0%/*}"
            # A launcher that ignores SIGTERM and first starts a child that inherits that and holds the output open.
            if [ -f "$dir/orphan" ]; then trap '' TERM; sleep 60 & echo $! > "$dir/child"; fi
            if [ "$1" = "login" ]; then
              if [ -f "$dir/signed-in" ]; then echo "Logged in using ChatGPT"; exit 0; fi
              if [ -f "$dir/api-key" ]; then echo "Logged in using an API key - sk-fake-***00000"; exit 0; fi
              if [ -f "$dir/broken" ]; then echo "env: node: No such file or directory" >&2; exit 127; fi
              echo "Not logged in" >&2; exit 1
            fi
            printf '%s\\n' "$@" > "$dir/args"
            pwd -P > "$dir/cwd"; ls -A > "$dir/cwd-contents"; printf '%s' "$PATH" > "$dir/path"
            cat > "$dir/stdin"
            if [ -f "$dir/sleep" ]; then exec sleep "$(cat "$dir/sleep")"; fi
            if [ -f "$dir/fail" ]; then exit 3; fi
            out=""; prev=""
            for a in "$@"; do if [ "$prev" = "-o" ]; then out="$a"; fi; prev="$a"; done
            cp "$dir/answer" "$out"
            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func touch(_ codex: URL, _ name: String, _ text: String = "") throws {
        try text.write(to: codex.deletingLastPathComponent().appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func recorded(_ codex: URL, _ name: String) throws -> String {
        try String(contentsOf: codex.deletingLastPathComponent().appendingPathComponent(name), encoding: .utf8)
    }

    @Test func buildsTheExecArgumentsTheIssueRequires() {
        let arguments = CodexCLI.execArguments(workingDirectory: URL(fileURLWithPath: "/tmp/w"), schema: URL(fileURLWithPath: "/tmp/s.json"),
                                               output: URL(fileURLWithPath: "/tmp/a.json"))
        #expect(arguments == ["exec", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check", "--sandbox", "read-only",
                              "--color", "never", "--cd", "/tmp/w", "--output-schema", "/tmp/s.json", "-o", "/tmp/a.json", "-"])
    }

    @Test func runsExecInAnEmptyPrivateFolderWithThePromptOnStdin() async throws {
        let codex = try stub()
        defer { try? FileManager.default.removeItem(at: codex.deletingLastPathComponent()) }
        try touch(codex, "signed-in")
        try touch(codex, "answer", "{\"blocks\":[]}")
        let cli = CodexCLI(executable: codex, searchPath: "/usr/bin:/bin")
        #expect(await cli.loginStatus() == .signedIn)
        #expect(try await cli.complete(prompt: "PROMPT TEXT", schema: ClassificationRequest.responseSchema) == "{\"blocks\":[]}")
        #expect(try recorded(codex, "stdin") == "PROMPT TEXT")
        #expect(try recorded(codex, "cwd-contents").isEmpty)
        let cwd = try recorded(codex, "cwd").trimmingCharacters(in: .newlines)
        let arguments = try recorded(codex, "args").split(separator: "\n").map(String.init)
        #expect(Array(arguments.prefix(7)) == ["exec", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check", "--sandbox", "read-only"])
        #expect(arguments.last == "-")
        // The folder is private while the run lasts and removed afterwards.
        #expect(cwd.contains("pointInTime-codex-"))
        #expect(!FileManager.default.fileExists(atPath: cwd))
        // The binary's own folder comes first in the child's PATH.
        #expect(try recorded(codex, "path") == codex.deletingLastPathComponent().path + ":/usr/bin:/bin")
    }

    @Test func refusesToRunWhenSignedOutOrWhenExecFails() async throws {
        let codex = try stub()
        defer { try? FileManager.default.removeItem(at: codex.deletingLastPathComponent()) }
        let cli = CodexCLI(executable: codex, searchPath: nil)
        #expect(await cli.loginStatus() == .signedOut)
        await #expect(throws: ProviderError.notSignedIn) { try await cli.prepare() }
        #expect(!FileManager.default.fileExists(atPath: codex.deletingLastPathComponent().appendingPathComponent("args").path))
        // A launcher that cannot start is not reported as signed out.
        try touch(codex, "broken")
        #expect(await cli.loginStatus() == .unavailable("codex login status exited with status 127"))
        // An API-key sign-in is not the ChatGPT subscription: nothing is sent.
        try touch(codex, "api-key")
        #expect(await cli.loginStatus() == .notChatGPT)
        await #expect(throws: ProviderError.notChatGPT) { try await cli.prepare() }
        #expect(!ProviderError.notChatGPT.description.contains("sk-"))
        #expect(!FileManager.default.fileExists(atPath: codex.deletingLastPathComponent().appendingPathComponent("args").path))
        try touch(codex, "signed-in")
        try await cli.prepare()
        try touch(codex, "fail")
        await #expect(throws: ProviderError.process("codex exec exited with status 3")) { try await cli.complete(prompt: "p", schema: "{}") }
        let missing = CodexCLI(executable: URL(fileURLWithPath: "/nonexistent/codex"), searchPath: nil)
        guard case .unavailable = await missing.loginStatus() else { Issue.record("A missing binary was not reported"); return }
    }

    @Test func stopsAnExecThatOutlivesItsTimeout() async throws {
        let codex = try stub()
        defer { try? FileManager.default.removeItem(at: codex.deletingLastPathComponent()) }
        try touch(codex, "signed-in")
        try touch(codex, "sleep", "30")
        let cli = CodexCLI(executable: codex, searchPath: nil, timeout: 1)
        let started = Date()
        await #expect(throws: ProviderError.timedOut(1)) { try await cli.complete(prompt: "p", schema: "{}") }
        // Well before the stub would have finished on its own.
        #expect(Date().timeIntervalSince(started) < 15)
    }

    @Test func aTimeoutStopsEverythingTheLauncherStarted() async throws {
        let codex = try stub()
        defer { try? FileManager.default.removeItem(at: codex.deletingLastPathComponent()) }
        try touch(codex, "orphan")
        try touch(codex, "sleep", "30")
        // Long enough for the stub to start its child even on a busy machine.
        let cli = CodexCLI(executable: codex, searchPath: nil, timeout: 10)
        await #expect(throws: ProviderError.timedOut(10)) { try await cli.complete(prompt: "p", schema: "{}") }
        let child = try #require(pid_t(try recorded(codex, "child").trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await exits(child))
    }

    @Test func aLauncherThatExitsIsNotWaitedOnForWhatItLeftRunning() async throws {
        let codex = try stub()
        defer { try? FileManager.default.removeItem(at: codex.deletingLastPathComponent()) }
        try touch(codex, "orphan")
        try touch(codex, "answer", "{\"blocks\":[]}")
        let cli = CodexCLI(executable: codex, searchPath: nil, timeout: 50)
        let started = Date()
        #expect(try await cli.complete(prompt: "p", schema: "{}") == "{\"blocks\":[]}")
        #expect(Date().timeIntervalSince(started) < 30)
        let child = try #require(pid_t(try recorded(codex, "child").trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await exits(child))
    }

    @Test func quittingStopsARunningExecAndRemovesItsFolder() async throws {
        let codex = try stub()
        defer { try? FileManager.default.removeItem(at: codex.deletingLastPathComponent()) }
        try touch(codex, "orphan")
        try touch(codex, "sleep", "60")
        let children = ChildProcesses()
        let cli = CodexCLI(executable: codex, searchPath: nil, timeout: 120, children: children)
        let run = Task { try await cli.complete(prompt: "p", schema: "{}") }
        // The stub writes its child's pid first and its working folder once it has read the prompt.
        let stdin = codex.deletingLastPathComponent().appendingPathComponent("stdin")
        for _ in 0..<400 where !FileManager.default.fileExists(atPath: stdin.path) { try await Task.sleep(for: .milliseconds(50)) }
        let child = try #require(pid_t(try recorded(codex, "child").trimmingCharacters(in: .whitespacesAndNewlines)))
        let folder = URL(fileURLWithPath: try recorded(codex, "cwd").trimmingCharacters(in: .newlines)).deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: folder.path))
        // Both the launcher and its child ignore SIGTERM, so only the SIGKILL after the grace stops them.
        let started = Date()
        children.stopAll(grace: 0.5)
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(await exits(child))
        await #expect(throws: ProviderError.self) { try await run.value }
        // Nothing starts once the app is quitting.
        try FileManager.default.removeItem(at: codex.deletingLastPathComponent().appendingPathComponent("args"))
        await #expect(throws: ProviderError.self) { try await cli.complete(prompt: "p", schema: "{}") }
        #expect(!FileManager.default.fileExists(atPath: codex.deletingLastPathComponent().appendingPathComponent("args").path))
        guard case .unavailable = await cli.loginStatus() else { Issue.record("A sign-in check ran while quitting"); return }
    }

    /// Whether `pid` is gone within twenty seconds.
    private func exits(_ pid: pid_t) async -> Bool {
        for _ in 0..<200 {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    @Test func locatesCodexOnAPath() throws {
        let codex = try stub()
        defer { try? FileManager.default.removeItem(at: codex.deletingLastPathComponent()) }
        #expect(CodexCLI.locate(in: "/nonexistent:\(codex.deletingLastPathComponent().path)")?.path == codex.path)
        #expect(CodexCLI.locate(in: "/nonexistent") == nil)
    }
}

/// Answers every request with one canned response and records the requests.
private final class TransportDouble: HTTPTransport, @unchecked Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var body = Data()
    var error: Error?
    var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let error { throw error }
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

@Suite struct OpenRouterTests {
    @Test func sendsAStrictJSONSchemaRequestWithTheChosenModel() async throws {
        let transport = TransportDouble()
        transport.body = Data(#"{"choices":[{"message":{"content":"{\"blocks\":[]}"}}]}"#.utf8)
        let client = OpenRouterClient(key: "sk-or-secret", model: "  ", transport: transport)
        #expect(client.model == OpenRouterClient.defaultModel)
        #expect(try await client.complete(prompt: "PROMPT", schema: ClassificationRequest.responseSchema) == "{\"blocks\":[]}")
        let request = try #require(transport.requests.first)
        #expect(request.url == OpenRouterClient.completionsURL)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-secret")
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == OpenRouterClient.defaultModel)
        let format = try #require(body["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let schema = try #require(format["json_schema"] as? [String: Any])
        #expect(schema["strict"] as? Bool == true)
        #expect(schema["schema"] is [String: Any])
        #expect((body["messages"] as? [[String: String]])?.first?["content"] == "PROMPT")
        #expect((body["provider"] as? [String: Any])?["require_parameters"] as? Bool == true)
    }

    @Test func mapsFailuresWithoutRevealingTheKey() async throws {
        let transport = TransportDouble()
        let client = OpenRouterClient(key: "sk-or-secret", model: "m", transport: transport)
        let cases: [(Int, [String: String], ProviderError)] = [
            (401, [:], .unauthorized("OpenRouter rejected the key (HTTP 401)")),
            (429, ["Retry-After": "120"], .rateLimited(retryAfter: 120)),
            (503, [:], .network("OpenRouter returned HTTP 503")),
            (400, [:], .process("OpenRouter refused the request (HTTP 400)"))
        ]
        for (status, headers, expected) in cases {
            transport.status = status
            transport.headers = headers
            transport.body = Data("{\"error\":\"sk-or-secret\"}".utf8)
            await #expect(throws: expected) { try await client.complete(prompt: "p", schema: "{}") }
        }
        transport.error = URLError(.notConnectedToInternet)
        do {
            _ = try await client.complete(prompt: "p", schema: "{}")
            Issue.record("An offline request succeeded")
        } catch let error as ProviderError {
            guard case .network = error else { Issue.record("Expected a network error, got \(error)"); return }
            #expect(!String(describing: error).contains("sk-or-secret"))
        }
    }

    @Test func testKeyChecksTheKeyEndpointOnly() async throws {
        let transport = TransportDouble()
        let client = OpenRouterClient(key: "sk-or-secret", model: "m", transport: transport)
        try await client.testKey()
        #expect(transport.requests.map(\.url) == [OpenRouterClient.keyURL])
        #expect(transport.requests.first?.httpBody == nil)
        transport.status = 401
        await #expect(throws: ProviderError.unauthorized("OpenRouter rejected the key (HTTP 401)")) { try await client.testKey() }
    }
}

@Suite struct MemoryProfileTests {
    @Test func createsThePrivateTemplateOnceAndCapsWhatIsRead() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = MemoryProfile(directory: directory)
        #expect(memory.read() == MemoryProfile.template)
        #expect(try FileManager.default.attributesOfItem(atPath: memory.url.path)[.posixPermissions] as? Int == 0o600)
        try (String(repeating: "é", count: 5_000)).write(to: memory.url, atomically: true, encoding: .utf8)
        try memory.ensureExists()
        #expect(memory.read() == String(repeating: "é", count: 4_096))
    }
}

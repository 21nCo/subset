import Foundation
import Testing
@testable import PointInTimeCore

private let newYork: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}()

private func at(_ hour: Int, _ minute: Int = 0, day: Int = 20) -> Date {
    newYork.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
}

private enum Kind { case focus, neutral, drift, pending, failed, excludedOnly, correctedFocus, correctedDrift }

private func block(_ start: Date, _ kind: Kind) -> Block {
    let labeling: BlockLabeling = switch kind {
    case .focus: BlockLabeling(state: .classified, label: .focus)
    case .neutral: BlockLabeling(state: .classified, label: .neutral)
    case .drift: BlockLabeling(state: .classified, label: .drift)
    case .pending, .excludedOnly: .pending
    case .failed: BlockLabeling(state: .failed)
    case .correctedFocus: BlockLabeling(state: .corrected, label: .focus, provider: "user")
    case .correctedDrift: BlockLabeling(state: .corrected, label: .drift, provider: "user")
    }
    let active: Double = kind == .excludedOnly ? 0 : 180
    let apps = active > 0 ? [AppTime(bundleID: "com.example.app", appName: "App", seconds: active)] : []
    return Block(start: start, activeSeconds: active, excludedSeconds: kind == .excludedOnly ? 180 : 0, apps: apps,
                 dominantBundleID: apps.first?.bundleID, dominantAppName: apps.first?.appName, labeling: labeling)
}

/// Consecutive blocks from `start`, one per kind.
private func session(_ start: Date, _ kinds: [Kind]) -> [Block] {
    kinds.enumerated().map { block(start.addingTimeInterval(Double($0.offset) * Block.length), $0.element) }
}

/// The instant just after `blocks` end, as the companion sees it while the next block is being recorded.
private func justAfter(_ blocks: [Block]) -> Date { blocks.last!.end.addingTimeInterval(10) }

private func evaluate(_ blocks: [Block], now: Date? = nil, rule: DriftRule = DriftRule(), state: CompanionState = CompanionState()) -> DriftDecision {
    DriftDetector.evaluate(blocks, now: now ?? justAfter(blocks), rule: rule, state: state, calendar: newYork)
}

private func episodeStarts(_ decision: DriftDecision) -> [Date]? {
    switch decision {
    case .none: nil
    case .prompt(let episode), .alreadyPrompted(let episode), .suppressed(let episode): episode.blockStarts
    }
}

@Suite struct DriftRuleTests {
    @Test func twoDriftBlocksConfirmByDefaultAndOneDoesNot() {
        let blocks = session(at(10), [.focus, .drift, .drift])
        #expect(evaluate(Array(blocks.prefix(2))) == .none)
        #expect(episodeStarts(evaluate(blocks)) == [blocks[1].start, blocks[2].start])
        guard case .prompt = evaluate(blocks) else { Issue.record("expected a prompt"); return }
    }

    @Test func theThresholdIsConfigurableAndKeptBetweenTwoAndFive() {
        let blocks = session(at(10), [.drift, .drift, .drift, .drift])
        #expect(evaluate(Array(blocks.prefix(3)), rule: DriftRule(threshold: 4)) == .none)
        guard case .prompt = evaluate(blocks, rule: DriftRule(threshold: 4)) else { Issue.record("expected a prompt at four"); return }
        #expect(DriftRule(threshold: 1).threshold == 2)
        #expect(DriftRule(threshold: 9).threshold == 5)
        var rule = DriftRule()
        rule.threshold = 0
        #expect(rule.threshold == 2)
        // A threshold of one is never honored: a single drift block does not confirm.
        #expect(evaluate(Array(blocks.prefix(1)), rule: DriftRule(threshold: 1)) == .none)
    }

    @Test func aFocusBlockResetsTheCountButNeutralUnclassifiedAndExcludedBlocksDoNot() {
        #expect(evaluate(session(at(10), [.drift, .focus, .drift])) == .none)
        #expect(evaluate(session(at(10), [.drift, .correctedFocus, .drift])) == .none)
        for between in [Kind.neutral, .pending, .failed, .excludedOnly] {
            let blocks = session(at(10), [.drift, between, .drift])
            #expect(episodeStarts(evaluate(blocks)) == [blocks[0].start, blocks[2].start], "\(between)")
        }
        // A user's correction counts as the label, as in reports.
        let corrected = session(at(10), [.correctedDrift, .drift])
        #expect(episodeStarts(evaluate(corrected))?.count == 2)
        // Unclassified blocks alone are not drift.
        #expect(evaluate(session(at(10), [.pending, .failed, .excludedOnly, .neutral])) == .none)
    }

    @Test func aMissingBlockEndsTheSessionAndOnlyACurrentSessionCounts() {
        let before = session(at(10), [.drift])
        let after = session(at(10, 6), [.drift])  // 10:03–10:06 holds nothing.
        #expect(evaluate(before + after) == .none)
        let both = session(at(10), [.drift, .drift])
        // Its last block ended more than a block length ago: the user is away, so nothing is offered.
        #expect(evaluate(both, now: both.last!.end.addingTimeInterval(Block.length + 1)) == .none)
        guard case .prompt = evaluate(both, now: both.last!.end.addingTimeInterval(Block.length)) else {
            Issue.record("expected a prompt within one block length"); return
        }
        #expect(evaluate([], now: at(10)) == .none)
        // Out-of-order input is read in start order.
        guard case .prompt = evaluate(both.reversed(), now: justAfter(both)) else { Issue.record("expected a prompt"); return }
    }

    @Test func anEpisodeIsOfferedOnlyOnceEvenAsItGrowsOrIsPartlyRelabeled() {
        let blocks = session(at(10), [.focus, .drift, .drift, .drift, .drift])
        guard case .prompt(let episode) = evaluate(Array(blocks.prefix(3))) else { Issue.record("expected a prompt"); return }
        let state = CompanionState(promptedEpisode: episode.start)
        #expect(evaluate(Array(blocks.prefix(3)), state: state) == .alreadyPrompted(episode))
        guard case .alreadyPrompted = evaluate(blocks, state: state) else { Issue.record("a longer episode is the same one"); return }
        // The window relabels the first drift block neutral: the rest is still the episode already offered.
        var relabeled = blocks
        relabeled[1] = block(relabeled[1].start, .neutral)
        guard case .alreadyPrompted = evaluate(relabeled, state: state) else { Issue.record("a relabeled episode is the same one"); return }
        // A focus block ends it, and the next drift is a new episode.
        let later = blocks + session(blocks.last!.end, [.focus, .drift, .drift])
        guard case .prompt(let next) = evaluate(later, state: state) else { Issue.record("expected a new episode"); return }
        #expect(next.start == later[6].start)
        // So does a new session after a gap.
        let resumed = blocks + session(blocks.last!.end.addingTimeInterval(Block.length), [.drift, .drift])
        guard case .prompt = evaluate(resumed, state: state) else { Issue.record("expected a new session's episode"); return }
    }

    @Test func anEarlierBlockLabeledDriftLaterIsStillTheOfferedEpisode() {
        // Pending blocks are classified newest first, so a backlog can label the run's earlier blocks after the offer.
        let blocks = session(at(10), [.pending, .drift, .drift, .pending, .pending])
        guard case .prompt(let episode) = evaluate(blocks) else { Issue.record("expected a prompt"); return }
        #expect(episode.start == blocks[1].start)
        let state = CompanionState(promptedEpisode: episode.start)
        for kind in [Kind.drift, .correctedDrift] {
            var backfilled = blocks
            backfilled[0] = block(blocks[0].start, kind)
            guard case .alreadyPrompted(let same) = evaluate(backfilled, state: state) else {
                Issue.record("an earlier \(kind) block made the offered episode new"); return
            }
            #expect(same.start == blocks[0].start)
        }
        // An earlier neutral block the user corrects to drift is the same episode too.
        var corrected = session(at(10), [.neutral, .drift, .drift])
        guard case .prompt(let offered) = evaluate(corrected) else { Issue.record("expected a prompt"); return }
        corrected[0] = block(corrected[0].start, .correctedDrift)
        guard case .alreadyPrompted = evaluate(corrected, state: CompanionState(promptedEpisode: offered.start)) else {
            Issue.record("a correction to drift made the offered episode new"); return
        }
        // A focus block after the offer still starts a new episode.
        var reset = blocks
        reset[0] = block(blocks[0].start, .drift)
        reset[3] = block(blocks[3].start, .focus)
        reset += session(reset.last!.end, [.drift, .drift])
        guard case .prompt(let next) = evaluate(reset, state: state) else { Issue.record("expected a new episode after Focus"); return }
        #expect(next.start == reset[5].start)
    }

    @Test func aDriftIsRecordedAsOfferedOnlyOnceShownOrSent() {
        #expect(DriftOfferRoute(panelShown: true, fallbackEnabled: false, notificationsAllowed: nil) == .panel)
        #expect(DriftOfferRoute(panelShown: true, fallbackEnabled: true, notificationsAllowed: false) == .panel)
        #expect(DriftOfferRoute(panelShown: false, fallbackEnabled: false, notificationsAllowed: true) == .undelivered)
        #expect(DriftOfferRoute(panelShown: false, fallbackEnabled: true, notificationsAllowed: nil) == .awaitingPermission)
        #expect(DriftOfferRoute(panelShown: false, fallbackEnabled: true, notificationsAllowed: false) == .undelivered)
        #expect(DriftOfferRoute(panelShown: false, fallbackEnabled: true, notificationsAllowed: true) == .notification)

        let blocks = session(at(10), [.drift, .drift])
        guard case .prompt(let episode) = evaluate(blocks) else { Issue.record("expected a prompt"); return }
        // At launch, before macOS says whether notifications are allowed, nothing is shown: the drift stays eligible.
        for route in [DriftOfferRoute.awaitingPermission, .undelivered] {
            var state = CompanionState()
            let recorded = state.recordOffer(of: episode, by: route)
            #expect(!recorded)
            #expect(state.promptedEpisode == nil)
            #expect(evaluate(blocks, state: state) == .prompt(episode), "\(route)")
        }
        for route in [DriftOfferRoute.panel, .notification] {
            var state = CompanionState()
            let recorded = state.recordOffer(of: episode, by: route)
            #expect(recorded)
            #expect(evaluate(blocks, state: state) == .alreadyPrompted(episode), "\(route)")
        }
    }

    @Test func notADriftAsFocusEndsTheEpisodeAndAsNeutralLeavesNothingToOffer() {
        let blocks = session(at(10), [.drift, .drift])
        guard case .prompt(let episode) = evaluate(blocks) else { Issue.record("expected a prompt"); return }
        let state = CompanionState(promptedEpisode: episode.start)
        let asFocus = blocks.map { block($0.start, .correctedFocus) }
        #expect(evaluate(asFocus, state: state) == .none)
        let asNeutral = blocks.map { block($0.start, .neutral) }
        #expect(evaluate(asNeutral, state: state) == .none)
        // After Focus, two new drift blocks are a new episode.
        let more = asFocus + session(blocks.last!.end, [.drift, .drift])
        guard case .prompt = evaluate(more, state: state) else { Issue.record("expected a new episode after Focus"); return }
    }

    @Test func quietHoursHoldBackPromptsAndEndEpisodes() {
        let quiet = QuietHours(startMinute: 22 * 60, endMinute: 7 * 60)
        #expect(quiet.contains(at(22), calendar: newYork))
        #expect(quiet.contains(at(2), calendar: newYork))
        #expect(!quiet.contains(at(7), calendar: newYork))
        #expect(!quiet.contains(at(21, 59), calendar: newYork))
        let daytime = QuietHours(startMinute: 12 * 60, endMinute: 13 * 60)
        #expect(daytime.contains(at(12, 30), calendar: newYork))
        #expect(!daytime.contains(at(13), calendar: newYork))
        #expect(!QuietHours(startMinute: 600, endMinute: 600).contains(at(10), calendar: newYork))
        #expect(QuietHours(startMinute: -5, endMinute: 5_000) == QuietHours(startMinute: 0, endMinute: 1_439))

        let rule = DriftRule(quietHours: quiet)
        // Drift inside quiet hours is not counted, so nothing is offered; without them it would be.
        let night = session(at(23), [.drift, .drift])
        #expect(evaluate(night, rule: rule) == .none)
        guard case .prompt = evaluate(night) else { Issue.record("expected a prompt without quiet hours"); return }
        // Drift confirmed before quiet hours but labeled once they began is not offered either.
        let evening = session(at(21, 54), [.drift, .drift])
        guard case .suppressed = evaluate(evening, now: at(22, 1), rule: rule) else { Issue.record("expected suppression at 22:01"); return }
        // A block in quiet hours resets the count, so an episode never reaches across them.
        let across = session(at(6, 54), [.drift, .drift, .drift])  // 06:54, 06:57 in quiet hours; 07:00 after.
        let episode = DriftDetector.episode(in: across, now: justAfter(across), rule: rule, state: CompanionState(), calendar: newYork)
        #expect(episode?.blockStarts == [across[2].start])
        #expect(evaluate(across, rule: rule) == .none)
        let morning = across + session(across.last!.end, [.drift])
        guard case .prompt(let confirmed) = evaluate(morning, rule: rule) else { Issue.record("expected a morning prompt"); return }
        #expect(confirmed.blockStarts == [across[2].start, morning[3].start])
    }

    @Test func aFocusWindowOrBreakHoldsBackPromptsAndSettlesTheDriftBeforeIt() {
        let blocks = session(at(10), [.drift, .drift])
        var state = CompanionState()
        state.returnToFocus(at: at(10, 7))
        #expect(state.focusWindow == DateInterval(start: at(10, 7), duration: 25 * 60))
        #expect(state.isSuppressed(at: at(10, 31)))
        #expect(!state.isSuppressed(at: at(10, 32)))
        #expect(evaluate(blocks, now: at(10, 7), state: state) == .none)
        // Drift during the window is not counted, before or after the window ends.
        let during = session(at(10, 6), [.drift, .drift, .drift, .drift, .drift, .drift, .drift, .drift, .drift])
        #expect(evaluate(blocks + during, now: at(10, 32), state: state) == .none)
        // After it, drift counts again.
        let after = blocks + during + session(at(10, 33), [.drift, .drift])
        guard case .prompt(let episode) = evaluate(after, state: state) else { Issue.record("expected a prompt after the window"); return }
        #expect(episode.blockStarts == [at(10, 33), at(10, 36)])

        var resting = CompanionState()
        #expect(resting.takeBreak(for: 10 * 60, at: at(10, 7)) == at(10, 17))
        #expect(resting.suppressedUntil == at(10, 17))
        // A shorter break later does not cut a longer one short.
        resting.takeBreak(for: 5 * 60, at: at(10, 8))
        #expect(resting.breakUntil == at(10, 17))
        let afterBreak = session(at(10, 18), [.drift, .drift])
        guard case .prompt = evaluate(afterBreak, state: resting) else { Issue.record("expected a prompt after the break"); return }
        // During the break nothing is offered, even for drift confirmed before it began.
        #expect(evaluate(blocks, now: at(10, 9), state: resting) == .none)
    }

    @Test func endingAFocusWindowAllowsPromptsAgain() {
        var state = CompanionState()
        state.returnToFocus(at: at(10))
        #expect(state.activeFocusWindow(at: at(10, 10)) != nil)
        state.endFocusWindow(at: at(10, 10))
        #expect(state.activeFocusWindow(at: at(10, 10)) == nil)
        #expect(!state.isSuppressed(at: at(10, 10)))
        let blocks = session(at(10, 12), [.drift, .drift])
        guard case .prompt = evaluate(blocks, state: state) else { Issue.record("expected a prompt"); return }
    }

    @Test func theDriftOfferedIsForgottenOnceItsBlockIsDeletedOrOutOfRange() {
        let blocks = session(at(10), [.drift, .drift])
        func forgets(_ stored: [Block], readFrom: Date) -> Bool {
            var state = CompanionState(promptedEpisode: blocks[0].start)
            let changed = state.forgetOfferedEpisode(unlessIn: stored, readFrom: readFrom)
            #expect(changed == (state.promptedEpisode == nil))
            return changed
        }
        #expect(!forgets(blocks, readFrom: at(9)))
        // Relabeled blocks are still stored, so the offer stands.
        #expect(!forgets(blocks.map { block($0.start, .neutral) }, readFrom: at(9)))
        // Deleted, or older than the read.
        #expect(forgets(Array(blocks.dropFirst()), readFrom: at(9)))
        #expect(forgets(blocks, readFrom: at(10, 1)))
        var none = CompanionState()
        let changed = none.forgetOfferedEpisode(unlessIn: [], readFrom: at(9))
        #expect(!changed)
    }

    @Test func theRuleOffOffersNothing() {
        #expect(evaluate(session(at(10), [.drift, .drift, .drift]), rule: DriftRule(enabled: false)) == .none)
    }
}

@Suite struct FocusRingTests {
    @Test func aZeroDataDayDrawsAnEmptyRing() {
        let ring = FocusRing(today: at(12), blocks: [], calendar: newYork)
        #expect(ring.isEmpty)
        #expect(ring.arcs.isEmpty)
        #expect(ring.accessibilityText == "No classified time today")
    }

    @Test func aDayWithNothingClassifiedIsEmptyToo() {
        let ring = FocusRing(today: at(12), blocks: session(at(9), [.pending, .failed, .excludedOnly]), calendar: newYork)
        #expect(ring.isEmpty)
        #expect(ring.accessibilityText == "No classified time today")
    }

    @Test func sharesAreOfClassifiedTimeOnlyAndAddUpToTheWholeRing() {
        let blocks = session(at(9), [.focus, .focus, .focus, .neutral, .drift, .pending, .excludedOnly])
        let ring = FocusRing(today: at(12), blocks: blocks, calendar: newYork)
        #expect(!ring.isEmpty)
        #expect(ring.arcs.map(\.category) == [.focus, .neutral, .drift])
        #expect(ring.arcs.map(\.fraction) == [0.6, 0.2, 0.2])
        #expect(ring.arcs.reduce(0) { $0 + $1.fraction } == 1)
        #expect(ring.accessibilityText == "Focus 60%, Neutral 20%, Drift 20% today")
        // Categories with no time draw no arc but are still read.
        let focusOnly = FocusRing(today: at(12), blocks: session(at(9), [.focus]), calendar: newYork)
        #expect(focusOnly.arcs.map(\.category) == [.focus])
        #expect(focusOnly.accessibilityText == "Focus 100%, Neutral 0%, Drift 0% today")
    }

    @Test func theRingUsesTheSameDayTotalsAsTheWindow() {
        // Yesterday's blocks are not today's; a correction covers the block's excluded time as in reports.
        var corrected = block(at(9), .correctedDrift)
        corrected.excludedSeconds = 60
        let blocks = session(at(23, 57, day: 19), [.focus]) + [corrected] + session(at(9, 3), [.focus])
        let ring = FocusRing(today: at(12), blocks: blocks, calendar: newYork)
        let report = DayReport(day: at(12), blocks: blocks, calendar: newYork)
        #expect(ring.totals == report.totals)
        #expect(ring.totals.drift == 240)
        #expect(ring.totals.share(of: .focus) == 180.0 / 420.0)
        #expect(ring.accessibilityText == "Focus 43%, Neutral 0%, Drift 57% today")
        #expect(CategorySeconds().share(of: .focus) == nil)
    }
}

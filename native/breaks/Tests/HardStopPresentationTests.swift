import XCTest
// Mac only: the BreaksMacTests bundle compiles the shared sources and `Mac/HardStopPresentation.swift` directly.

final class HardStopPresentationTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private let locale = Locale(identifier: "en_GB")

    /// Monday 10 August 2026 at `hour`:`minute` UTC, plus `seconds`, `dayOffset` days later.
    private func at(_ hour: Int, _ minute: Int, _ seconds: Int = 0, dayOffset: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 10 + dayOffset, hour: hour, minute: minute, second: seconds))!
    }

    /// The key of the occurrence that starts at `hour`:`minute` on the day of `at(hour, minute, dayOffset:)`.
    private func key(_ hour: Int, _ minute: Int, dayOffset: Int = 0) -> Int {
        HardStop.Occurrence.key(year: 2026, month: 8, day: 10 + dayOffset, hour: hour, minute: minute)
    }

    private func lunch(
        end: HardStop.End = .after(30 * 60),
        escapeHatch: HardStop.EscapeHatch = .none,
        duringCalls: HardStop.CallBehavior = .waitForCallToEnd
    ) -> HardStop {
        HardStop(name: "Lunch", hour: 12, minute: 30, end: end, repeats: .weekdays([2]), warningMinutes: [10],
                 escapeHatch: escapeHatch, duringCalls: duringCalls)
    }

    private func makeScheduler(_ stops: [HardStop], start: Date? = nil) -> BreakScheduler {
        var settings = BreakSettings()
        settings.officeHours.isEnabled = false
        settings.plannedBreaks = []
        settings.workInterval = 8 * 3600
        settings.wellness.blinkEnabled = false
        settings.wellness.postureEnabled = false
        settings.hardStops = stops
        let start = start ?? at(12, 0)
        let snapshot = EngineSnapshot(
            phase: .focusing, focusStartedAt: start, nextBreakAt: start.addingTimeInterval(settings.workInterval),
            snoozeDay: calendar.startOfDay(for: start)
        )
        return BreakScheduler(settings: settings, snapshot: snapshot, records: [], calendar: calendar)
    }

    private func walk(
        hour: Int = 13,
        minute: Int = 5,
        end: HardStop.End = .after(30 * 60),
        warnings: [Int] = [10],
        escapeHatch: HardStop.EscapeHatch = .none
    ) -> HardStop {
        HardStop(name: "Walk", hour: hour, minute: minute, end: end, repeats: .weekdays([2]), warningMinutes: warnings,
                 escapeHatch: escapeHatch, duringCalls: .startAnyway)
    }

    private func present(
        _ scheduler: BreakScheduler,
        at now: Date,
        notice: HardStopPresentation.NoticeSubject? = nil,
        inCall: Bool = false
    ) -> HardStopPresentation {
        HardStopPresentation(scheduler: scheduler, noticeSubject: notice, inCall: inCall, now: now, locale: locale)
    }

    // MARK: - Warning notice

    func testWarningNoticeShowsNameTimeAndCountdownWithStartNow() {
        let stop = lunch()
        var scheduler = makeScheduler([stop])
        XCTAssertEqual(scheduler.tick(now: at(12, 20)), [.hardStopWarning(id: stop.id, occurrenceKey: key(12, 30), startsAt: at(12, 30), waitingForCall: false)])
        let subject = HardStopPresentation.NoticeSubject.warning(id: stop.id, occurrenceKey: key(12, 30))

        let notice = present(scheduler, at: at(12, 25, 30), notice: subject).notice
        XCTAssertEqual(notice?.title, "Lunch — hard stop at 12:30, in 04:30")
        XCTAssertEqual(notice?.spokenTitle, "Lunch, hard stop at 12:30, in \(TimeInterval(270).spokenDuration)")
        XCTAssertNil(notice?.detail)
        XCTAssertEqual(notice?.canStartNow, true)
        // No notice without a subject, and no overlay or menu bar status before the stop starts.
        let idle = present(scheduler, at: at(12, 25))
        XCTAssertNil(idle.notice)
        XCTAssertNil(idle.overlay)
        XCTAssertNil(idle.menuBar)

        // Once the stop starts, the notice is gone.
        _ = scheduler.tick(now: at(12, 30))
        XCTAssertNil(present(scheduler, at: at(12, 30), notice: subject).notice)
    }

    func testLongNameNeverHidesTheTimeAndCountdown() {
        let name = String(repeating: "Quarterly planning review with the whole team ", count: 4)
        var stop = lunch()
        stop.name = name
        var scheduler = makeScheduler([stop])
        _ = scheduler.tick(now: at(12, 20), inputs: .init(signals: [.meeting]))
        let subject = HardStopPresentation.NoticeSubject.warning(id: stop.id, occurrenceKey: key(12, 30))

        // The panel shows the name on a line of its own, cut short, and the time and countdown below it in full.
        let notice = present(scheduler, at: at(12, 25, 30), notice: subject).notice
        XCTAssertEqual(notice?.name, name)
        XCTAssertEqual(notice?.timing, "Hard stop at 12:30, in 04:30")
        XCTAssertEqual(notice?.title, "\(name) — hard stop at 12:30, in 04:30")
        XCTAssertEqual(notice?.spokenTitle, "\(name), hard stop at 12:30, in \(TimeInterval(270).spokenDuration)")

        _ = scheduler.tick(now: at(12, 30), inputs: .init(signals: [.meeting]))
        XCTAssertEqual(present(scheduler, at: at(12, 31), notice: subject, inCall: true).notice?.timing, "Hard stop at 12:30")
    }

    func testWarningNoticeWhileWaitingForACall() {
        let stop = lunch()
        var scheduler = makeScheduler([stop])
        // The meeting signal also pauses reminders.
        XCTAssertEqual(scheduler.tick(now: at(12, 20), inputs: .init(signals: [.meeting])),
                       [.hardStopWarning(id: stop.id, occurrenceKey: key(12, 30), startsAt: at(12, 30), waitingForCall: true), .paused(.meeting)])
        let subject = HardStopPresentation.NoticeSubject.warning(id: stop.id, occurrenceKey: key(12, 30))

        // Before the start, during a call: the countdown and the call note.
        let before = present(scheduler, at: at(12, 28), notice: subject, inCall: true).notice
        XCTAssertEqual(before?.title, "Lunch — hard stop at 12:30, in 02:00")
        XCTAssertEqual(before?.detail, "Starts when your call ends")
        // The call ended before the start: no call note.
        XCTAssertNil(present(scheduler, at: at(12, 28), notice: subject, inCall: false).notice?.detail)

        // Past the start, the stop waits: no countdown, the call note, and Start now starts it anyway.
        XCTAssertTrue(scheduler.tick(now: at(12, 30), inputs: .init(signals: [.meeting])).isEmpty)
        let waiting = present(scheduler, at: at(12, 31), notice: subject, inCall: true)
        XCTAssertEqual(waiting.notice?.title, "Lunch — hard stop at 12:30")
        XCTAssertEqual(waiting.notice?.detail, "Starts when your call ends")
        XCTAssertEqual(waiting.notice?.canStartNow, true)
        XCTAssertEqual(waiting.menuBar?.text, "Hard stop · after call")

        // A stop that starts anyway gets no call note, and past its start the notice is gone.
        let anyway = lunch(duringCalls: .startAnyway)
        var starts = makeScheduler([anyway])
        _ = starts.tick(now: at(12, 20), inputs: .init(signals: [.meeting]))
        let anywaySubject = HardStopPresentation.NoticeSubject.warning(id: anyway.id, occurrenceKey: key(12, 30))
        XCTAssertNil(present(starts, at: at(12, 25), notice: anywaySubject, inCall: true).notice?.detail)
        XCTAssertNil(present(starts, at: at(12, 30), notice: anywaySubject, inCall: true).notice)
    }

    func testWarningNoticeClosesWhenItsStopIsRemovedOrDisabled() {
        let stop = lunch()
        var scheduler = makeScheduler([stop])
        _ = scheduler.tick(now: at(12, 20))
        let subject = HardStopPresentation.NoticeSubject.warning(id: stop.id, occurrenceKey: key(12, 30))
        scheduler.settings.hardStops[0].isEnabled = false
        XCTAssertNil(present(scheduler, at: at(12, 21), notice: subject).notice)
        scheduler.settings.hardStops = []
        XCTAssertNil(present(scheduler, at: at(12, 21), notice: subject).notice)
    }

    func testStartNowStartsOnlyTheOccurrenceItsWarningNames() {
        // Monday's open-ended Lunch still waits for a call when Tuesday's warning comes.
        let stop = HardStop(name: "Lunch", hour: 12, minute: 30, end: .untilDismissed, repeats: .weekdays([2, 3]),
                            warningMinutes: [120], escapeHatch: .dismissEarly, duringCalls: .waitForCallToEnd)
        var scheduler = makeScheduler([stop])
        _ = scheduler.tick(now: at(12, 30), inputs: .init(signals: [.meeting]))
        XCTAssertEqual(scheduler.snapshot.hardStopsWaitingForCall[stop.id.uuidString], key(12, 30))
        XCTAssertTrue(scheduler.tick(now: at(10, 30, dayOffset: 1), inputs: .init(signals: [.meeting]))
            .contains(.hardStopWarning(id: stop.id, occurrenceKey: key(12, 30, dayOffset: 1), startsAt: at(12, 30, dayOffset: 1), waitingForCall: true)))

        // Tuesday's notice offers no Start now while Monday's occurrence comes first, and pressing it starts nothing.
        let tuesday = HardStopPresentation.NoticeSubject.warning(id: stop.id, occurrenceKey: key(12, 30, dayOffset: 1))
        let notice = present(scheduler, at: at(10, 31, dayOffset: 1), notice: tuesday, inCall: true).notice
        XCTAssertEqual(notice?.title, "Lunch — hard stop at 12:30, in 1:59:00")
        XCTAssertEqual(notice?.canStartNow, false)
        XCTAssertTrue(scheduler.startHardStopEarly(id: stop.id, occurrenceKey: key(12, 30, dayOffset: 1), now: at(10, 31, dayOffset: 1)).isEmpty)
        XCTAssertNil(scheduler.snapshot.activeHardStop)

        // Start now for an occurrence starts that one, with its own end.
        var timed = makeScheduler([lunch()])
        _ = timed.tick(now: at(12, 20))
        XCTAssertTrue(timed.startHardStopEarly(id: timed.settings.hardStops[0].id, occurrenceKey: key(12, 30, dayOffset: 7), now: at(12, 21)).isEmpty,
                      "Not next week's occurrence")
        XCTAssertEqual(timed.startHardStopEarly(id: timed.settings.hardStops[0].id, occurrenceKey: key(12, 30), now: at(12, 21)),
                       [.hardStopStarted(id: timed.settings.hardStops[0].id, endsAt: at(13, 0))])
    }

    func testWarningSurvivesATimeZoneChange() {
        let stop = lunch()
        var scheduler = makeScheduler([stop])
        _ = scheduler.tick(now: at(12, 20))
        var queue = HardStopNoticeQueue()
        queue.add(.warning(id: stop.id, occurrenceKey: key(12, 30)))

        // An hour west, 12:30 local is 13:30 UTC: the same occurrence, now further ahead.
        scheduler.calendar.timeZone = TimeZone(secondsFromGMT: -3600)!
        queue.prune(scheduler: scheduler, inCall: false, now: at(12, 21))
        XCTAssertEqual(queue.shown, .warning(id: stop.id, occurrenceKey: key(12, 30)))
        let notice = present(scheduler, at: at(12, 21), notice: queue.shown).notice
        XCTAssertEqual(notice?.title, "Lunch — hard stop at 12:30, in 1:09:00")
        XCTAssertEqual(notice?.canStartNow, true)
        XCTAssertEqual(scheduler.tick(now: at(12, 22)).filter { if case .hardStopWarning = $0 { true } else { false } }, [],
                       "The scheduler does not warn again, so the queued warning is the only one")
    }

    func testWarningForAnOccurrenceThatNoLongerExistsIsDropped() {
        // Lunch's 12:30 warning is queued, then the stop moves to 13:00, or to Tuesdays.
        let changes: [(String, (inout HardStop) -> Void)] = [
            ("time", { $0.hour = 13 }),
            ("days", { $0.repeats = .weekdays([3]) })
        ]
        for (change, apply) in changes {
            var scheduler = makeScheduler([lunch()])
            let id = scheduler.settings.hardStops[0].id
            _ = scheduler.tick(now: at(12, 20))
            var queue = HardStopNoticeQueue()
            queue.add(.warning(id: id, occurrenceKey: key(12, 30)))
            apply(&scheduler.settings.hardStops[0])
            let before = scheduler.snapshot

            queue.prune(scheduler: scheduler, inCall: false, now: at(12, 21))
            XCTAssertNil(queue.shown, "After a \(change) change")
            XCTAssertFalse(scheduler.canStartHardStopEarly(id: id, occurrenceKey: key(12, 30), now: at(12, 21)), "After a \(change) change")
            XCTAssertEqual(scheduler.startHardStopEarly(id: id, occurrenceKey: key(12, 30), now: at(12, 21)), [], "After a \(change) change")
            XCTAssertEqual(scheduler.snapshot, before, "After a \(change) change")
        }
    }

    func testWarningForAWindowThatDaylightSavingTimeSkipsIsDropped() {
        // Sunday 02:30–03:00, warned in UTC; in New York, clocks skip from 02:00 to 03:00 on Sunday 8 March 2026.
        let stop = HardStop(name: "Night", hour: 2, minute: 30, end: .at(hour: 3, minute: 0), repeats: .weekdays([1]),
                            warningMinutes: [120], escapeHatch: .none, duringCalls: .startAnyway)
        let utc = { (hour: Int) in self.calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: hour))! }
        let night = HardStop.Occurrence.key(year: 2026, month: 3, day: 8, hour: 2, minute: 30)
        var scheduler = makeScheduler([stop], start: utc(0))
        XCTAssertEqual(scheduler.tick(now: utc(0) + 30 * 60),
                       [.hardStopWarning(id: stop.id, occurrenceKey: night, startsAt: utc(2) + 30 * 60, waitingForCall: false)])
        var queue = HardStopNoticeQueue()
        queue.add(.warning(id: stop.id, occurrenceKey: night))

        scheduler.calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let before = scheduler.snapshot
        // 05:00 UTC is midnight in New York, two hours before the skipped window would begin.
        queue.prune(scheduler: scheduler, inCall: false, now: utc(5))
        XCTAssertNil(queue.shown)
        XCTAssertFalse(scheduler.canStartHardStopEarly(id: stop.id, occurrenceKey: night, now: utc(5)))
        XCTAssertEqual(scheduler.startHardStopEarly(id: stop.id, occurrenceKey: night, now: utc(5)), [])
        XCTAssertEqual(scheduler.snapshot, before)
    }

    func testWarningForALaterStopShowsWhileAStopRuns() {
        // Lunch 12:30–13:00 with one 15-minute extension; Walk at 13:05 with a 35-minute warning, due as Lunch starts.
        let lunch = lunch(escapeHatch: .extend(minutes: 15, times: 1))
        let walk = walk(warnings: [35])
        var scheduler = makeScheduler([lunch, walk])
        XCTAssertEqual(scheduler.tick(now: at(12, 30)), [
            .hardStopStarted(id: lunch.id, endsAt: at(13, 0)),
            .hardStopWarning(id: walk.id, occurrenceKey: key(13, 5), startsAt: at(13, 5), waitingForCall: false)
        ])
        let subject = HardStopPresentation.NoticeSubject.warning(id: walk.id, occurrenceKey: key(13, 5))

        // Under the overlay the notice still applies, without Start now while Lunch runs.
        let covered = present(scheduler, at: at(12, 31), notice: subject).notice
        XCTAssertEqual(covered?.title, "Walk — hard stop at 13:05, in 34:00")
        XCTAssertEqual(covered?.canStartNow, false)
        // During Lunch's extension, too.
        _ = scheduler.extendHardStop(now: at(12, 40))
        XCTAssertEqual(present(scheduler, at: at(12, 41), notice: subject).notice?.canStartNow, false)
        // Once Lunch has ended, Start now is offered.
        _ = scheduler.tick(now: at(12, 55))
        _ = scheduler.tick(now: at(13, 0))
        XCTAssertNil(scheduler.snapshot.activeHardStop)
        XCTAssertEqual(present(scheduler, at: at(13, 0), notice: subject).notice?.canStartNow, true)
    }

    func testWarningForAStopThatJoinsTheRunningOneDoesNotApply() {
        let lunch = lunch()
        let inside = walk(hour: 12, minute: 45)
        var scheduler = makeScheduler([lunch, inside])
        _ = scheduler.tick(now: at(12, 30))
        XCTAssertNil(present(scheduler, at: at(12, 40), notice: .warning(id: inside.id, occurrenceKey: key(12, 45))).notice)
    }

    // MARK: - Notice queue

    func testWarningWaitsBehindTheExtensionNoticeAndShowsAfterIt() {
        // Lunch 12:30–13:00 extended at 12:40 for 5 minutes; Walk at 13:05 warns 21 minutes ahead, at 12:44, just as
        // the notice before the extension runs out is due.
        let lunch = lunch(escapeHatch: .extend(minutes: 5, times: 2))
        let walk = walk(warnings: [21])
        var scheduler = makeScheduler([lunch, walk])
        _ = scheduler.tick(now: at(12, 30))
        _ = scheduler.extendHardStop(now: at(12, 40))
        XCTAssertEqual(scheduler.tick(now: at(12, 44)), [.hardStopWarning(id: walk.id, occurrenceKey: key(13, 5), startsAt: at(13, 5), waitingForCall: false)])
        XCTAssertEqual(HardStopPresentation.extensionWarningDue(scheduler, now: at(12, 44)), at(12, 45))

        // The controller queues the warning from the events, then the extension notice.
        var queue = HardStopNoticeQueue()
        let warning = HardStopPresentation.NoticeSubject.warning(id: walk.id, occurrenceKey: key(13, 5))
        queue.add(warning)
        queue.add(.extensionEnding)
        queue.prune(scheduler: scheduler, inCall: false, now: at(12, 44))
        XCTAssertEqual(queue.shown, .extensionEnding, "The warning does not replace the extension notice")
        XCTAssertEqual(queue.subjects, [.extensionEnding, warning])

        // The extension runs out: its notice no longer applies, and the warning takes its place.
        XCTAssertEqual(scheduler.tick(now: at(12, 45)), [.hardStopResumed(id: lunch.id)])
        queue.prune(scheduler: scheduler, inCall: false, now: at(12, 45))
        XCTAssertEqual(queue.shown, warning)
        // It stays until Walk starts.
        _ = scheduler.tick(now: at(13, 0))
        queue.prune(scheduler: scheduler, inCall: false, now: at(13, 0))
        XCTAssertEqual(queue.shown, warning)
        _ = scheduler.tick(now: at(13, 5))
        queue.prune(scheduler: scheduler, inCall: false, now: at(13, 5))
        XCTAssertNil(queue.shown)
    }

    func testNoticeQueueShowsTheEarliestStopAndTheNextAfterClosing() {
        let early = UUID(), late = UUID()
        var queue = HardStopNoticeQueue()
        queue.add(.warning(id: late, occurrenceKey: key(14, 0)))
        queue.add(.warning(id: early, occurrenceKey: key(13, 0)))
        XCTAssertEqual(queue.shown, .warning(id: early, occurrenceKey: key(13, 0)))
        queue.closeShown()
        XCTAssertEqual(queue.shown, .warning(id: late, occurrenceKey: key(14, 0)), "Closing one shows the next instead of dropping it")
        // A later warning time for the same stop shows it again once closed.
        queue.closeShown()
        XCTAssertNil(queue.shown)
        queue.add(.warning(id: late, occurrenceKey: key(14, 0)))
        queue.add(.warning(id: late, occurrenceKey: key(14, 0)))
        XCTAssertEqual(queue.subjects, [.warning(id: late, occurrenceKey: key(14, 0))])
    }

    // MARK: - Overlay

    func testOverlayTextForEachEndType() {
        func overlay(_ end: HardStop.End) -> HardStopPresentation.Overlay? {
            var scheduler = makeScheduler([lunch(end: end)])
            _ = scheduler.tick(now: at(12, 30))
            return present(scheduler, at: at(12, 40)).overlay
        }
        let fixed = overlay(.at(hour: 13, minute: 15))
        XCTAssertEqual(fixed?.name, "Lunch")
        XCTAssertEqual(fixed?.until, "Until 13:15")
        XCTAssertEqual(fixed?.remaining, 35 * 60)

        let length = overlay(.after(30 * 60))
        XCTAssertEqual(length?.until, "Until 13:00")
        XCTAssertEqual(length?.remaining, 20 * 60)

        let open = overlay(.untilDismissed)
        XCTAssertEqual(open?.until, "Until you dismiss it")
        XCTAssertNil(open?.remaining)
    }

    func testOverlayActionsFollowTheEscapeHatch() {
        func overlay(_ escapeHatch: HardStop.EscapeHatch, end: HardStop.End = .after(30 * 60)) -> HardStopPresentation.Overlay? {
            var scheduler = makeScheduler([lunch(end: end, escapeHatch: escapeHatch)])
            _ = scheduler.tick(now: at(12, 30))
            return present(scheduler, at: at(12, 31)).overlay
        }
        XCTAssertEqual(overlay(.none)?.actions, [])
        XCTAssertNil(overlay(.none)?.extensionsLeft)
        XCTAssertEqual(overlay(.dismissEarly)?.actions, [.dismiss])
        XCTAssertNil(overlay(.dismissEarly)?.extensionsLeft)
        XCTAssertEqual(overlay(.extend(minutes: 15, times: 2))?.actions, [.extend(minutes: 15)])
        XCTAssertEqual(overlay(.extend(minutes: 15, times: 2))?.extensionsLeft, "2 extensions left")
        // A stop without an end can always be dismissed.
        XCTAssertEqual(overlay(.none, end: .untilDismissed)?.actions, [.dismiss])
        XCTAssertEqual(overlay(.extend(minutes: 10, times: 1), end: .untilDismissed)?.actions, [.extend(minutes: 10), .dismiss])
        XCTAssertEqual(HardStopPresentation.OverlayAction.extend(minutes: 15).title, "Extend 15 min")
        XCTAssertEqual(HardStopPresentation.OverlayAction.dismiss.title, "Dismiss")
    }

    func testOverlayDropsExtendWhenExtensionsRunOut() {
        let stop = lunch(end: .after(60 * 60), escapeHatch: .extend(minutes: 5, times: 2))
        var scheduler = makeScheduler([stop])
        _ = scheduler.tick(now: at(12, 30))
        _ = scheduler.extendHardStop(now: at(12, 31))
        XCTAssertNil(present(scheduler, at: at(12, 32)).overlay, "Hidden while extended")
        _ = scheduler.tick(now: at(12, 36))
        XCTAssertEqual(present(scheduler, at: at(12, 36)).overlay?.extensionsLeft, "1 extension left")
        XCTAssertEqual(present(scheduler, at: at(12, 36)).overlay?.actions, [.extend(minutes: 5)])
        _ = scheduler.extendHardStop(now: at(12, 37))
        _ = scheduler.tick(now: at(12, 42))
        let spent = present(scheduler, at: at(12, 42)).overlay
        XCTAssertEqual(spent?.extensionsLeft, "No extensions left")
        XCTAssertEqual(spent?.actions, [])
    }

    func testOverlayFollowsAStopThatTookOverBeforeATick() {
        // Lunch 12:30–13:00 with one 5-minute extension; Walk starts inside it at 12:45, ends 13:30 and so takes over
        // the escape hatch with two 10-minute extensions. No tick runs between 12:30 and 12:46.
        let lunch = lunch(escapeHatch: .extend(minutes: 5, times: 1))
        let walk = walk(hour: 12, minute: 45, end: .at(hour: 13, minute: 30), escapeHatch: .extend(minutes: 10, times: 2))
        var scheduler = makeScheduler([lunch, walk])
        _ = scheduler.tick(now: at(12, 30))
        let before = present(scheduler, at: at(12, 44)).overlay
        XCTAssertEqual(before?.actions, [.extend(minutes: 5)])

        let overlay = present(scheduler, at: at(12, 46)).overlay
        XCTAssertEqual(overlay?.actions, [.extend(minutes: 10)])
        XCTAssertEqual(overlay?.extensionsLeft, "2 extensions left")
        XCTAssertEqual(overlay?.until, "Until 13:30")
        XCTAssertEqual(overlay?.context.endsAt, at(13, 30))
        XCTAssertEqual(present(scheduler, at: at(12, 46)).menuBar?.text, "Hard stop · until 13:30")
        XCTAssertNil(scheduler.snapshot.activeHardStop?.merged.first, "Presenting does not merge")

        // A confirmation of the old "Extend 5 min" does nothing; the one on screen extends by its 10 minutes.
        let stale = HardStopConfirmation.Target(context: before!.context, action: .extend(minutes: 5))
        XCTAssertTrue(HardStopPresentation.perform(stale, on: &scheduler, now: at(12, 46)).isEmpty)
        XCTAssertNil(scheduler.snapshot.activeHardStop?.extendedUntil)
        let shown = HardStopConfirmation.Target(context: overlay!.context, action: .extend(minutes: 10))
        XCTAssertEqual(HardStopPresentation.perform(shown, on: &scheduler, now: at(12, 46)),
                       [.hardStopExtended(id: lunch.id, until: at(12, 56))])
    }

    func testMalformedSavedExtensionCountsNeverCrash() {
        // Lunch 12:30–13:30 with two extensions; Walk joins at 12:45, ends 14:00 and takes over with its own two.
        let lunch = lunch(end: .after(60 * 60), escapeHatch: .extend(minutes: 5, times: 2))
        let walk = walk(hour: 12, minute: 45, end: .at(hour: 14, minute: 0), escapeHatch: .extend(minutes: 10, times: 2))
        var running = makeScheduler([lunch, walk])
        _ = running.tick(now: at(12, 30))
        _ = running.tick(now: at(12, 45))
        XCTAssertEqual(running.snapshot.activeHardStop?.escapeHatchOwner, 0)

        func restored(_ edit: (inout ActiveHardStop) -> Void) -> BreakScheduler {
            var snapshot = running.snapshot
            edit(&snapshot.activeHardStop!)
            return BreakScheduler(settings: running.settings, snapshot: snapshot, records: [], calendar: calendar)
        }
        // The stop's own count, then the count of the stop that took over the escape hatch.
        let direct = restored { $0.escapeHatchOwner = nil; $0.extensionsUsed = .min }
        XCTAssertEqual(present(direct, at: at(12, 46)).overlay?.extensionsLeft, "2 extensions left")
        let merged = restored { $0.merged[0].extensionsUsed = .min }
        XCTAssertEqual(present(merged, at: at(12, 46)).overlay?.extensionsLeft, "2 extensions left")
        let spent = restored { $0.merged[0].extensionsUsed = .max }
        XCTAssertEqual(present(spent, at: at(12, 46)).overlay?.extensionsLeft, "No extensions left")
        XCTAssertEqual(HardStopPresentation.extensionsLeft(times: .min, used: .max), 0)
        XCTAssertEqual(HardStopPresentation.extensionsLeft(times: 3, used: .min), 3)

        // A relaunch brings the saved counts and escape hatch back into range before anything uses them.
        var relaunched = restored {
            $0.merged[0].extensionsUsed = .min
            $0.escapeHatch = .extend(minutes: .max, times: .max)
        }
        relaunched.reconcileRestoredState(now: at(12, 46))
        XCTAssertEqual(relaunched.snapshot.activeHardStop?.ownerExtensionsUsed, 0)
        XCTAssertEqual(relaunched.snapshot.activeHardStop?.escapeHatch, .extend(minutes: 60, times: 5))
        XCTAssertEqual(relaunched.extendHardStop(now: at(12, 46)), [.hardStopExtended(id: lunch.id, until: at(13, 46))])
        XCTAssertEqual(relaunched.snapshot.activeHardStop?.ownerExtensionsUsed, 1)
    }

    // MARK: - Extension ending

    func testNoticeBeforeAnExtensionEnds() {
        let stop = lunch(escapeHatch: .extend(minutes: 15, times: 1))
        var scheduler = makeScheduler([stop])
        _ = scheduler.tick(now: at(12, 30))
        _ = scheduler.extendHardStop(now: at(12, 31))
        XCTAssertNil(HardStopPresentation.extensionWarningDue(scheduler, now: at(12, 44, 59)))
        XCTAssertEqual(HardStopPresentation.extensionWarningDue(scheduler, now: at(12, 45)), at(12, 46))
        let notice = present(scheduler, at: at(12, 45), notice: .extensionEnding).notice
        XCTAssertEqual(notice?.title, "Lunch — hard stop at 12:46, in 01:00")
        XCTAssertEqual(notice?.canStartNow, true)

        // Start now shows the stop again; the notice is gone.
        XCTAssertEqual(scheduler.endHardStopExtension(now: at(12, 45, 10)), [.hardStopResumed(id: stop.id)])
        XCTAssertNil(present(scheduler, at: at(12, 45, 10), notice: .extensionEnding).notice)
        XCTAssertNil(HardStopPresentation.extensionWarningDue(scheduler, now: at(12, 45, 10)))

        // An extension that outlasts the stop's end gets no notice: the stop ends instead of coming back.
        var outlasts = makeScheduler([stop])
        _ = outlasts.tick(now: at(12, 30))
        _ = outlasts.extendHardStop(now: at(12, 50))
        XCTAssertNil(HardStopPresentation.extensionWarningDue(outlasts, now: at(12, 59, 30)))
        XCTAssertNil(present(outlasts, at: at(12, 59, 30), notice: .extensionEnding).notice)
    }

    func testExtensionNoticeOffersStartNowOnlyWhileTheStopCanComeBack() {
        let stop = lunch(escapeHatch: .extend(minutes: 15, times: 1))
        var scheduler = makeScheduler([stop])
        _ = scheduler.tick(now: at(12, 30))
        _ = scheduler.extendHardStop(now: at(12, 41))
        let due = present(scheduler, at: at(12, 55), notice: .extensionEnding).notice
        XCTAssertEqual(due?.title, "Lunch — hard stop at 12:56, in 01:00")
        XCTAssertEqual(due?.canStartNow, true)

        // Ticks run late: the stop's end has passed but no tick has ended it yet. Start now would do nothing.
        XCTAssertFalse(scheduler.canEndHardStopExtension(now: at(13, 0, 30)))
        XCTAssertEqual(scheduler.endHardStopExtension(now: at(13, 0, 30)), [])
        XCTAssertNil(present(scheduler, at: at(13, 0, 30), notice: .extensionEnding).notice)
    }

    func testExtensionNoticeClosesWhenTheExtensionRunsOut() {
        let stop = lunch(escapeHatch: .extend(minutes: 15, times: 1))
        var scheduler = makeScheduler([stop])
        _ = scheduler.tick(now: at(12, 30))
        _ = scheduler.extendHardStop(now: at(12, 41))
        var queue = HardStopNoticeQueue()
        queue.add(.extensionEnding)
        XCTAssertEqual(present(scheduler, at: at(12, 55, 59), notice: .extensionEnding).notice?.canStartNow, true)

        // The extension ran out at 12:56 and the stop ends at 13:00, but no tick has shown the stop again yet.
        for now in [at(12, 56), at(12, 57)] {
            XCTAssertNil(present(scheduler, at: now, notice: .extensionEnding).notice)
            XCTAssertFalse(scheduler.canEndHardStopExtension(now: now))
            let before = scheduler.snapshot
            XCTAssertEqual(scheduler.endHardStopExtension(now: now), [])
            XCTAssertEqual(scheduler.snapshot, before)
            queue.prune(scheduler: scheduler, inCall: false, now: now)
            XCTAssertNil(queue.shown)
        }
        // The tick shows it again.
        XCTAssertEqual(scheduler.tick(now: at(12, 57)), [.hardStopResumed(id: stop.id)])
    }

    func testStopThatEndedWhileTheAppWasOffEndsWithoutAChime() {
        let stop = lunch()
        var running = makeScheduler([stop])
        _ = running.tick(now: at(12, 30))

        // Relaunched after the end: the first tick ends the restored stop, and that end is silent.
        var restored = BreakScheduler(settings: running.settings, snapshot: running.snapshot, records: running.records,
                                      calendar: calendar)
        restored.reconcileRestoredState(now: at(13, 20))
        XCTAssertEqual(restored.tick(now: at(13, 20)), [.hardStopEnded(id: stop.id, reason: .ended)])
        XCTAssertFalse(HardStopPresentation.chimesOnEnd(.ended, scheduledEnd: at(13, 0), now: at(13, 20), afterRelaunch: true))
        XCTAssertFalse(HardStopPresentation.chimesOnEnd(.ended, scheduledEnd: at(13, 0), now: at(13, 0, 1), afterRelaunch: true))

        // An end reached while the app runs chimes; a dismissal or a missed stop never does.
        let end = running.snapshot.activeHardStop?.endsAt
        XCTAssertEqual(end, at(13, 0))
        XCTAssertEqual(running.tick(now: at(13, 0, 1)), [.hardStopEnded(id: stop.id, reason: .ended)])
        XCTAssertTrue(HardStopPresentation.chimesOnEnd(.ended, scheduledEnd: end, now: at(13, 0, 1), afterRelaunch: false))
        XCTAssertFalse(HardStopPresentation.chimesOnEnd(.dismissed, scheduledEnd: end, now: at(12, 40), afterRelaunch: false))
        XCTAssertFalse(HardStopPresentation.chimesOnEnd(.missed, scheduledEnd: end, now: at(13, 0, 1), afterRelaunch: false))
    }

    func testStopThatEndedWhileTheMacSleptEndsWithoutAChime() {
        let stop = lunch()
        var scheduler = makeScheduler([stop])
        _ = scheduler.tick(now: at(12, 30))
        let end = scheduler.snapshot.activeHardStop?.endsAt
        // Asleep from 12:50 to 15:00: the first tick after the wake, whether the timer or the wake notice runs it,
        // ends the stop, and that end is silent.
        _ = scheduler.tick(now: at(12, 50))
        XCTAssertEqual(scheduler.tick(now: at(15, 0)), [.hardStopEnded(id: stop.id, reason: .ended)])
        XCTAssertFalse(HardStopPresentation.chimesOnEnd(.ended, scheduledEnd: end, now: at(15, 0), afterRelaunch: false))
        XCTAssertFalse(HardStopPresentation.chimesOnEnd(.ended, scheduledEnd: end, now: at(13, 1, 1), afterRelaunch: false))
        // A tick a little late, as the timer may be while awake, still chimes.
        XCTAssertTrue(HardStopPresentation.chimesOnEnd(.ended, scheduledEnd: end, now: at(13, 1), afterRelaunch: false))
    }

    func testFadingOverlayKeepsTheHardStopScreenAfterItsStopEnds() throws {
        var scheduler = makeScheduler([lunch(escapeHatch: .dismissEarly)])
        _ = scheduler.tick(now: at(12, 30))
        let running = try XCTUnwrap(present(scheduler, at: at(12, 31)).overlay)
        XCTAssertEqual(HardStopPresentation.overlayScreen(current: running, last: nil, isClosing: false), running)

        // Dismissed: the windows fading out keep the stop's last screen instead of the regular break's.
        _ = scheduler.dismissHardStop(now: at(12, 32))
        let after = present(scheduler, at: at(12, 32)).overlay
        XCTAssertNil(after)
        XCTAssertEqual(HardStopPresentation.overlayScreen(current: after, last: running, isClosing: true), running)
        // A window that is not closing shows the regular break once no stop runs.
        XCTAssertNil(HardStopPresentation.overlayScreen(current: after, last: running, isClosing: false))
        // A window that only ever showed a regular break fades out with it.
        XCTAssertNil(HardStopPresentation.overlayScreen(current: nil, last: nil, isClosing: true))
    }

    func testHardStopNoticeDueUnderTheOverlayGoesAboveIt() {
        // Walk's 10-minute warning comes due at 12:55, while Lunch (12:30–13:00) covers the screen.
        let lunch = lunch()
        let walk = walk(hour: 13, minute: 5)
        var scheduler = makeScheduler([lunch, walk])
        _ = scheduler.tick(now: at(12, 30))
        XCTAssertEqual(scheduler.tick(now: at(12, 55)), [.hardStopWarning(id: walk.id, occurrenceKey: key(13, 5), startsAt: at(13, 5), waitingForCall: false)])
        let shown = present(scheduler, at: at(12, 55), notice: .warning(id: walk.id, occurrenceKey: key(13, 5)))
        XCTAssertNotNil(shown.overlay)
        XCTAssertNotNil(shown.notice)
        XCTAssertEqual(HardStopPresentation.noticeLayer(showsHardStopNotice: shown.notice != nil, overlayVisible: shown.overlay != nil),
                       .aboveOverlay)

        // Without the overlay, and always for the regular heads-up, the panel floats above other apps only.
        XCTAssertEqual(HardStopPresentation.noticeLayer(showsHardStopNotice: true, overlayVisible: false), .floating)
        XCTAssertEqual(HardStopPresentation.noticeLayer(showsHardStopNotice: false, overlayVisible: true), .floating)
    }

    func testOnlyAHeadsUpTheHardStopNoticeDisplacedComesBack() {
        // Held back: due while a hard-stop notice is open, shown once that notice closes.
        var heldBack = DisplacedHeadsUp()
        XCTAssertFalse(heldBack.headsUpDue(hardStopNoticeOpen: true))
        XCTAssertTrue(heldBack.restore(stillDue: true))
        XCTAssertFalse(heldBack.restore(stillDue: true))

        // On screen when the hard-stop notice took the panel: comes back.
        var visible = DisplacedHeadsUp()
        XCTAssertTrue(visible.headsUpDue(hardStopNoticeOpen: false))
        visible.hardStopNoticeShown(regularHeadsUpVisible: true)
        XCTAssertTrue(visible.restore(stillDue: true))

        // Dismissed by the user before the hard-stop notice: stays hidden.
        var dismissed = DisplacedHeadsUp()
        XCTAssertTrue(dismissed.headsUpDue(hardStopNoticeOpen: false))
        dismissed.withdraw()
        dismissed.hardStopNoticeShown(regularHeadsUpVisible: false)
        XCTAssertFalse(dismissed.restore(stillDue: true))

        // Never shown: nothing comes back.
        var never = DisplacedHeadsUp()
        never.hardStopNoticeShown(regularHeadsUpVisible: false)
        XCTAssertFalse(never.restore(stillDue: true))

        // Held back, then its break started (or it was cancelled): stays hidden, also once the next one is due.
        var withdrawn = DisplacedHeadsUp()
        XCTAssertFalse(withdrawn.headsUpDue(hardStopNoticeOpen: true))
        withdrawn.withdraw()
        XCTAssertFalse(withdrawn.restore(stillDue: true))
        // Held back, but its break is no longer coming when the notice closes.
        var stale = DisplacedHeadsUp()
        XCTAssertFalse(stale.headsUpDue(hardStopNoticeOpen: true))
        XCTAssertFalse(stale.restore(stillDue: false))
    }

    // MARK: - Menu bar

    func testMenuBarLabelInEachState() {
        var timed = makeScheduler([lunch(escapeHatch: .extend(minutes: 15, times: 1))])
        _ = timed.tick(now: at(12, 30))
        let shown = present(timed, at: at(12, 31)).menuBar
        XCTAssertEqual(shown?.text, "Hard stop · until 13:00")
        XCTAssertEqual(shown?.statusLine, "Lunch, until 13:00")

        _ = timed.extendHardStop(now: at(12, 31))
        let extended = present(timed, at: at(12, 32, 30)).menuBar
        XCTAssertEqual(extended?.text, "Extended · 13:30")
        XCTAssertEqual(extended?.statusLine, "Lunch extended, back in \(TimeInterval(810).spokenDuration)")

        var open = makeScheduler([lunch(end: .untilDismissed)])
        _ = open.tick(now: at(12, 30))
        XCTAssertEqual(present(open, at: at(12, 31)).menuBar?.text, "Hard stop")
        XCTAssertEqual(present(open, at: at(12, 31)).menuBar?.statusLine, "Lunch, until you dismiss it")

        _ = open.dismissHardStop(now: at(12, 32))
        XCTAssertNil(present(open, at: at(12, 32)).menuBar, "The regular label returns after the stop")
    }

    func testMenuBarNamesTheEarliestWaitingStop() {
        // Their ids sort in the opposite order to their starts.
        let first = HardStop(id: UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000000")!, name: "Lunch", hour: 12, minute: 30,
                             repeats: .weekdays([2]), warningMinutes: [], escapeHatch: .none, duringCalls: .waitForCallToEnd)
        let second = HardStop(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, name: "Stretch", hour: 12, minute: 40,
                              repeats: .weekdays([2]), warningMinutes: [], escapeHatch: .none, duringCalls: .waitForCallToEnd)
        var scheduler = makeScheduler([first, second])
        _ = scheduler.tick(now: at(12, 30), inputs: .init(signals: [.meeting]))
        _ = scheduler.tick(now: at(12, 40), inputs: .init(signals: [.meeting]))
        XCTAssertEqual(scheduler.snapshot.hardStopsWaitingForCall.count, 2)
        let menuBar = present(scheduler, at: at(12, 41), inCall: true).menuBar
        XCTAssertEqual(menuBar?.text, "Hard stop · after call")
        XCTAssertEqual(menuBar?.statusLine, "Lunch starts when your call ends")
    }

    func testMenuBarIgnoresTheWaitOfADisabledStop() {
        let first = HardStop(name: "Lunch", hour: 12, minute: 30, repeats: .weekdays([2]), warningMinutes: [],
                             escapeHatch: .none, duringCalls: .waitForCallToEnd)
        let second = HardStop(name: "Stretch", hour: 12, minute: 40, repeats: .weekdays([2]), warningMinutes: [],
                              escapeHatch: .none, duringCalls: .waitForCallToEnd)
        var scheduler = makeScheduler([first, second])
        _ = scheduler.tick(now: at(12, 30), inputs: .init(signals: [.meeting]))
        _ = scheduler.tick(now: at(12, 40), inputs: .init(signals: [.meeting]))

        // Disabled with no tick since: its wait is still saved, but the menu bar names the other stop.
        scheduler.settings.hardStops[0].isEnabled = false
        scheduler.normalizeSettings()
        XCTAssertEqual(scheduler.snapshot.hardStopsWaitingForCall.count, 2)
        XCTAssertEqual(present(scheduler, at: at(12, 41), inCall: true).menuBar?.statusLine, "Stretch starts when your call ends")

        scheduler.settings.hardStops[1].isEnabled = false
        scheduler.normalizeSettings()
        XCTAssertNil(present(scheduler, at: at(12, 41), inCall: true).menuBar)
    }

    func testRelaunchBringsBackTheNoticeOfAStopWaitingForACall() {
        let stop = lunch()
        var scheduler = makeScheduler([stop])
        _ = scheduler.tick(now: at(12, 20), inputs: .init(signals: [.meeting]))
        _ = scheduler.tick(now: at(12, 30), inputs: .init(signals: [.meeting]))
        XCTAssertEqual(scheduler.snapshot.hardStopsWaitingForCall[stop.id.uuidString], key(12, 30))
        func relaunch(_ change: (inout BreakSettings) -> Void = { _ in /* as saved */ }) -> BreakScheduler {
            var settings = scheduler.settings
            change(&settings)
            var relaunched = BreakScheduler(settings: settings, snapshot: scheduler.snapshot, records: [], calendar: calendar)
            relaunched.reconcileRestoredState(now: at(12, 35))
            return relaunched
        }

        // Relaunched during the call: its start has passed, so no warning comes again, and the notice is rebuilt.
        var relaunched = relaunch()
        var queue = HardStopNoticeQueue()
        let events = relaunched.tick(now: at(12, 35), inputs: .init(signals: [.meeting]))
        XCTAssertFalse(events.contains { if case .hardStopWarning = $0 { true } else { false } })
        queue.addWaits(of: relaunched)
        XCTAssertTrue(queue.prune(scheduler: relaunched, inCall: true, now: at(12, 35)))
        let subject = HardStopPresentation.NoticeSubject.warning(id: stop.id, occurrenceKey: key(12, 30))
        XCTAssertEqual(queue.subjects, [subject])
        let notice = present(relaunched, at: at(12, 35), notice: subject, inCall: true).notice
        XCTAssertEqual(notice?.title, "Lunch — hard stop at 12:30")
        XCTAssertEqual(notice?.detail, "Starts when your call ends")
        XCTAssertEqual(notice?.canStartNow, true)
        // Start now starts that occurrence, and the notice closes.
        XCTAssertTrue(relaunched.startHardStopEarly(id: stop.id, occurrenceKey: key(12, 30), now: at(12, 36))
            .contains(.hardStopStarted(id: stop.id, endsAt: at(13, 0))))
        queue.prune(scheduler: relaunched, inCall: true, now: at(12, 36))
        XCTAssertNil(queue.shown)

        // Relaunched after the call ended: the first tick starts the stop, and the notice goes.
        var ended = relaunch()
        var endedQueue = HardStopNoticeQueue()
        XCTAssertTrue(ended.tick(now: at(12, 35)).contains(.hardStopStarted(id: stop.id, endsAt: at(13, 0))))
        endedQueue.addWaits(of: ended)
        XCTAssertFalse(endedQueue.prune(scheduler: ended, inCall: false, now: at(12, 35)))
        XCTAssertNil(endedQueue.shown)

        // A disabled stop's wait gets no notice.
        let disabled = relaunch { $0.hardStops[0].isEnabled = false }
        var disabledQueue = HardStopNoticeQueue()
        disabledQueue.addWaits(of: disabled)
        XCTAssertFalse(disabledQueue.prune(scheduler: disabled, inCall: true, now: at(12, 35)))
        XCTAssertNil(disabledQueue.shown)
    }

    func testAWaitTheFirstTickAfterARelaunchCreatesGetsItsNotice() {
        let stop = lunch()
        var scheduler = makeScheduler([stop])
        // Quit at 12:00, before the warning, so the saved snapshot has no wait.
        _ = scheduler.tick(now: at(12, 0))
        var relaunched = BreakScheduler(settings: scheduler.settings, snapshot: scheduler.snapshot, records: [], calendar: calendar)
        relaunched.reconcileRestoredState(now: at(12, 35))
        var queue = HardStopNoticeQueue()
        queue.addWaits(of: relaunched)
        XCTAssertTrue(queue.subjects.isEmpty)
        // Relaunched at 12:35 during a call: the first tick makes the stop wait, with no warning, and the notice comes.
        let events = relaunched.tick(now: at(12, 35), inputs: .init(signals: [.meeting]))
        XCTAssertFalse(events.contains { if case .hardStopWarning = $0 { true } else { false } })
        XCTAssertEqual(relaunched.snapshot.hardStopsWaitingForCall[stop.id.uuidString], key(12, 30))
        queue.addWaits(of: relaunched)
        XCTAssertTrue(queue.prune(scheduler: relaunched, inCall: true, now: at(12, 35)))
        let subject = HardStopPresentation.NoticeSubject.warning(id: stop.id, occurrenceKey: key(12, 30))
        XCTAssertEqual(queue.subjects, [subject])
        let notice = present(relaunched, at: at(12, 35), notice: subject, inCall: true).notice
        XCTAssertEqual(notice?.detail, "Starts when your call ends")
        XCTAssertEqual(notice?.canStartNow, true)
        XCTAssertTrue(relaunched.startHardStopEarly(id: stop.id, occurrenceKey: key(12, 30), now: at(12, 36))
            .contains(.hardStopStarted(id: stop.id, endsAt: at(13, 0))))
    }

    func testAStopThatStartsWaitingForACallGetsItsNoticeOnce() {
        // No warnings, so only the wait can bring the notice.
        let stop = HardStop(name: "Lunch", hour: 12, minute: 30, repeats: .weekdays([2]), warningMinutes: [],
                            escapeHatch: .none, duringCalls: .waitForCallToEnd)
        var scheduler = makeScheduler([stop])
        var queue = HardStopNoticeQueue()
        _ = scheduler.tick(now: at(12, 29), inputs: .init(signals: [.meeting]))
        queue.addWaits(of: scheduler)
        XCTAssertFalse(queue.prune(scheduler: scheduler, inCall: true, now: at(12, 29)))
        _ = scheduler.tick(now: at(12, 30), inputs: .init(signals: [.meeting]))
        queue.addWaits(of: scheduler)
        XCTAssertTrue(queue.prune(scheduler: scheduler, inCall: true, now: at(12, 30)), "The wait begins while the app runs")
        let subject = HardStopPresentation.NoticeSubject.warning(id: stop.id, occurrenceKey: key(12, 30))
        XCTAssertEqual(queue.subjects, [subject])
        // Later ticks keep it without bringing it to the front again.
        _ = scheduler.tick(now: at(12, 31), inputs: .init(signals: [.meeting]))
        queue.addWaits(of: scheduler)
        XCTAssertFalse(queue.prune(scheduler: scheduler, inCall: true, now: at(12, 31)))
        XCTAssertEqual(queue.shown, subject)
        // Closed: later ticks of the same wait do not bring it back.
        queue.closeShown()
        for minute in 32...33 {
            _ = scheduler.tick(now: at(12, minute), inputs: .init(signals: [.meeting]))
            queue.addWaits(of: scheduler)
            XCTAssertFalse(queue.prune(scheduler: scheduler, inCall: true, now: at(12, minute)))
        }
        XCTAssertNil(queue.shown)
        // The call ends and the stop starts: nothing is queued.
        XCTAssertTrue(scheduler.tick(now: at(12, 34)).contains(.hardStopStarted(id: stop.id, endsAt: at(13, 0))))
        queue.addWaits(of: scheduler)
        XCTAssertFalse(queue.prune(scheduler: scheduler, inCall: false, now: at(12, 34)))
        XCTAssertNil(queue.shown)
        // The next occurrence waits for a call: its notice comes once, although the last wait's notice was closed.
        _ = scheduler.tick(now: at(13, 0))
        _ = scheduler.tick(now: at(12, 30, dayOffset: 7), inputs: .init(signals: [.meeting]))
        queue.addWaits(of: scheduler)
        XCTAssertTrue(queue.prune(scheduler: scheduler, inCall: true, now: at(12, 30, dayOffset: 7)))
        XCTAssertEqual(queue.shown, .warning(id: stop.id, occurrenceKey: key(12, 30, dayOffset: 7)))
    }

    /// Lunch waits for the call; Walk, which ignores calls, starts at 12:45 and runs until 13:00 while the call goes on.
    private func waitAndRunningStop() -> (waiting: HardStop, scheduler: BreakScheduler) {
        let waiting = HardStop(name: "Lunch", hour: 12, minute: 30, end: .after(90 * 60), repeats: .weekdays([2]),
                               warningMinutes: [], escapeHatch: .none, duringCalls: .waitForCallToEnd)
        let other = HardStop(name: "Walk", hour: 12, minute: 45, end: .after(15 * 60), repeats: .weekdays([2]),
                             warningMinutes: [], escapeHatch: .none, duringCalls: .startAnyway)
        return (waiting, makeScheduler([waiting, other]))
    }

    /// One tick during the call and the controller's notice sync after it; returns whether the panel comes to the front.
    private func step(_ scheduler: inout BreakScheduler, _ queue: inout HardStopNoticeQueue, _ now: Date) -> Bool {
        _ = scheduler.tick(now: now, inputs: .init(signals: [.meeting]))
        queue.addWaits(of: scheduler)
        return queue.prune(scheduler: scheduler, inCall: true, now: now)
    }

    func testAWaitNoticeHiddenWhileAnotherStopRunsComesBackWhenItEnds() {
        let (waiting, saved) = waitAndRunningStop()
        var scheduler = saved
        var queue = HardStopNoticeQueue()
        let subject = HardStopPresentation.NoticeSubject.warning(id: waiting.id, occurrenceKey: key(12, 30))
        XCTAssertTrue(step(&scheduler, &queue, at(12, 30)))
        XCTAssertEqual(queue.shown, subject)
        // Walk runs: Lunch starts before Walk ends, so its notice does not apply and is not brought up on any tick.
        for minute in [45, 50, 55] {
            XCTAssertFalse(step(&scheduler, &queue, at(12, minute)))
            XCTAssertNotNil(scheduler.snapshot.activeHardStop)
            XCTAssertNil(queue.shown)
        }
        // Walk ends while the call goes on, and Lunch still waits: its notice comes back once, with Start now.
        XCTAssertTrue(step(&scheduler, &queue, at(13, 0)))
        XCTAssertNil(scheduler.snapshot.activeHardStop)
        XCTAssertEqual(scheduler.snapshot.hardStopsWaitingForCall[waiting.id.uuidString], key(12, 30))
        XCTAssertEqual(queue.shown, subject)
        XCTAssertFalse(step(&scheduler, &queue, at(13, 1)))
        XCTAssertEqual(queue.shown, subject)
        let notice = present(scheduler, at: at(13, 1), notice: subject, inCall: true).notice
        XCTAssertEqual(notice?.detail, "Starts when your call ends")
        XCTAssertEqual(notice?.canStartNow, true)
        XCTAssertTrue(scheduler.startHardStopEarly(id: waiting.id, occurrenceKey: key(12, 30), now: at(13, 2))
            .contains(.hardStopStarted(id: waiting.id, endsAt: at(14, 0))))
    }

    func testAWaitRestoredDuringAnotherStopGetsItsNoticeWhenThatStopEnds() {
        let (waiting, saved) = waitAndRunningStop()
        var scheduler = saved
        _ = scheduler.tick(now: at(12, 30), inputs: .init(signals: [.meeting]))
        _ = scheduler.tick(now: at(12, 45), inputs: .init(signals: [.meeting]))
        // Relaunched at 12:50 while Walk runs and Lunch waits.
        var relaunched = BreakScheduler(settings: scheduler.settings, snapshot: scheduler.snapshot, records: [], calendar: calendar)
        relaunched.reconcileRestoredState(now: at(12, 50))
        var queue = HardStopNoticeQueue()
        XCTAssertFalse(step(&relaunched, &queue, at(12, 50)))
        XCTAssertNil(queue.shown)
        XCTAssertTrue(step(&relaunched, &queue, at(13, 0)))
        XCTAssertEqual(queue.shown, .warning(id: waiting.id, occurrenceKey: key(12, 30)))
    }

    func testAWaitNoticeTheUserClosedStaysClosedAfterAnotherStopRuns() {
        var scheduler = waitAndRunningStop().scheduler
        var queue = HardStopNoticeQueue()
        XCTAssertTrue(step(&scheduler, &queue, at(12, 30)))
        queue.closeShown()
        for minute in [31, 45, 50] { XCTAssertFalse(step(&scheduler, &queue, at(12, minute))) }
        for minute in [0, 1, 10] { XCTAssertFalse(step(&scheduler, &queue, at(13, minute))) }
        XCTAssertNil(scheduler.snapshot.activeHardStop)
        XCTAssertNil(queue.shown)
    }

    // MARK: - Confirmation

    private let lunchContext = HardStopPresentation.StopContext(id: UUID(), occurrenceKey: 1, endsAt: nil)
    private func target(_ action: HardStopPresentation.OverlayAction) -> HardStopConfirmation.Target {
        HardStopConfirmation.Target(context: lunchContext, action: action)
    }

    func testPointerHoldConfirmsAfterThreeSeconds() {
        let start = at(12, 0)
        var confirmation = HardStopConfirmation()
        confirmation.pressBegan(target(.dismiss), at: start, sleeps: 0)
        XCTAssertEqual(confirmation.holdProgress(of: target(.dismiss), now: start.addingTimeInterval(1.5)), 0.5)
        XCTAssertEqual(confirmation.holdProgress(of: target(.extend(minutes: 5)), now: start.addingTimeInterval(1.5)), 0)
        XCTAssertNil(confirmation.update(now: start.addingTimeInterval(2.9), sleeps: 0))
        XCTAssertEqual(confirmation.update(now: start.addingTimeInterval(3), sleeps: 0), target(.dismiss))
        // Reported once: neither a later update nor the release runs it again.
        XCTAssertNil(confirmation.update(now: start.addingTimeInterval(3.5), sleeps: 0))
        XCTAssertNil(confirmation.pressEnded(at: start.addingTimeInterval(4), sleeps: 0))
        XCTAssertEqual(confirmation.state, .idle)

        // A release at 3 seconds that comes before the update still confirms, once.
        confirmation.pressBegan(target(.extend(minutes: 15)), at: start, sleeps: 0)
        XCTAssertEqual(confirmation.pressEnded(at: start.addingTimeInterval(3), sleeps: 0), target(.extend(minutes: 15)))
        XCTAssertNil(confirmation.update(now: start.addingTimeInterval(3.1), sleeps: 0))
    }

    func testReleasingEarlyCancelsTheHold() {
        let start = at(12, 0)
        var confirmation = HardStopConfirmation()
        confirmation.pressBegan(target(.extend(minutes: 15)), at: start, sleeps: 0)
        XCTAssertNil(confirmation.pressEnded(at: start.addingTimeInterval(2.5), sleeps: 0))
        XCTAssertEqual(confirmation.state, .idle)
        XCTAssertNil(confirmation.update(now: start.addingTimeInterval(3), sleeps: 0))
        XCTAssertEqual(confirmation.holdProgress(of: target(.extend(minutes: 15)), now: start.addingTimeInterval(3)), 0)
        // A click is a cancelled hold too: it does not arm the keyboard confirmation.
        XCTAssertNil(confirmation.confirm(at: start.addingTimeInterval(3)))
    }

    func testInterruptedHoldNeverConfirms() {
        let start = at(12, 0)
        var confirmation = HardStopConfirmation()
        confirmation.pressBegan(target(.dismiss), at: start, sleeps: 0)
        confirmation.pressCancelled()
        XCTAssertEqual(confirmation.state, .idle)
        // Neither the deadline nor a later release runs it, even past 3 seconds.
        XCTAssertNil(confirmation.update(now: start.addingTimeInterval(3), sleeps: 0))
        XCTAssertNil(confirmation.pressEnded(at: start.addingTimeInterval(10), sleeps: 0))
        XCTAssertEqual(confirmation.holdProgress(of: target(.dismiss), now: start.addingTimeInterval(2)), 0)

        // The next press starts a fresh hold.
        let again = start.addingTimeInterval(4)
        confirmation.pressBegan(target(.extend(minutes: 15)), at: again, sleeps: 0)
        XCTAssertEqual(confirmation.holdProgress(of: target(.extend(minutes: 15)), now: again.addingTimeInterval(1.5)), 0.5)
        XCTAssertNil(confirmation.update(now: again.addingTimeInterval(2.9), sleeps: 0))
        XCTAssertEqual(confirmation.update(now: again.addingTimeInterval(3), sleeps: 0), target(.extend(minutes: 15)))

        // A pending Confirm is not a press, so it stays.
        confirmation.activate(target(.dismiss), at: start)
        confirmation.pressCancelled()
        XCTAssertEqual(confirmation.confirm(at: start.addingTimeInterval(1)), target(.dismiss))
    }

    func testSleepDuringAHoldCancelsItEvenIfTheDeadlineComesFirst() {
        let start = at(12, 0)
        var confirmation = HardStopConfirmation()
        // The Mac slept during the hold, and the deadline runs after the wake before the view hears of the sleep.
        confirmation.pressBegan(target(.dismiss), at: start, sleeps: 0)
        XCTAssertNil(confirmation.update(now: start.addingTimeInterval(3), sleeps: 1))
        XCTAssertEqual(confirmation.state, .idle)
        XCTAssertNil(confirmation.update(now: start.addingTimeInterval(3600), sleeps: 1))
        XCTAssertNil(confirmation.pressEnded(at: start.addingTimeInterval(3600), sleeps: 1))
        // Nor does a release after a sleep, however long the hold lasted.
        confirmation.pressBegan(target(.dismiss), at: start, sleeps: 1)
        XCTAssertNil(confirmation.pressEnded(at: start.addingTimeInterval(4), sleeps: 2))
        // Before the sleep is counted: a deadline or release far past the hold means the app was suspended.
        confirmation.pressBegan(target(.dismiss), at: start, sleeps: 2)
        XCTAssertNil(confirmation.update(now: start.addingTimeInterval(3600), sleeps: 2))
        XCTAssertEqual(confirmation.state, .idle)
        confirmation.pressBegan(target(.dismiss), at: start, sleeps: 2)
        XCTAssertNil(confirmation.pressEnded(at: start.addingTimeInterval(5.1), sleeps: 2))
        confirmation.pressBegan(target(.dismiss), at: start, sleeps: 2)
        XCTAssertEqual(confirmation.update(now: start.addingTimeInterval(5), sleeps: 2), target(.dismiss), "A slightly late deadline")

        // The next press is a fresh 3-second hold.
        let again = start.addingTimeInterval(10)
        confirmation.pressBegan(target(.extend(minutes: 15)), at: again, sleeps: 2)
        XCTAssertNil(confirmation.update(now: again.addingTimeInterval(2.9), sleeps: 2))
        XCTAssertEqual(confirmation.update(now: again.addingTimeInterval(3), sleeps: 2), target(.extend(minutes: 15)))
    }

    func testHoldPressBeginsOnlyOverTheButton() {
        var press = HoldPress()
        // The first update is outside: no press, and coming back over the button does not start one.
        XCTAssertNil(press.changed(inside: false))
        XCTAssertNil(press.changed(inside: true))
        XCTAssertNil(press.ended())
        XCTAssertNil(press.changed(inside: false))
        XCTAssertNil(press.cancelled())
        // The next drag that starts over the button is a press.
        XCTAssertEqual(press.changed(inside: true), .began)
        XCTAssertEqual(press.ended(), .ended)
    }

    func testHoldPressReportsAnInterruptedDragAsCancelled() {
        var press = HoldPress()
        XCTAssertEqual(press.changed(inside: true), .began)
        XCTAssertNil(press.changed(inside: true))
        // Interrupted: cancelled, never a release, and the press is reset.
        XCTAssertEqual(press.cancelled(), .cancelled)
        XCTAssertEqual(press, HoldPress())
        XCTAssertNil(press.ended())
        // The next drag is a new press.
        XCTAssertEqual(press.changed(inside: true), .began)
        // Leaving the button ends it once; coming back does not start another.
        XCTAssertEqual(press.changed(inside: false), .ended)
        XCTAssertNil(press.changed(inside: true))
        XCTAssertNil(press.ended())
        // A release ends it once; the gesture reset after it reports nothing.
        XCTAssertEqual(press.changed(inside: true), .began)
        XCTAssertEqual(press.ended(), .ended)
        XCTAssertNil(press.cancelled())
    }

    func testKeyboardConfirmsInTwoStepsWithinFiveSeconds() {
        let start = at(12, 0)
        var confirmation = HardStopConfirmation()
        XCTAssertNil(confirmation.confirm(at: start), "Confirm does nothing before the button is activated")
        confirmation.activate(target(.dismiss), at: start)
        XCTAssertEqual(confirmation.state, .awaitingConfirm(target(.dismiss), until: start.addingTimeInterval(5)))
        XCTAssertEqual(confirmation.confirmSecondsLeft(now: start.addingTimeInterval(0.5)), 5)
        XCTAssertNil(confirmation.update(now: start.addingTimeInterval(4.9), sleeps: 0))
        XCTAssertEqual(confirmation.confirm(at: start.addingTimeInterval(4.9)), target(.dismiss))
        XCTAssertEqual(confirmation.state, .idle)
        XCTAssertNil(confirmation.confirm(at: start.addingTimeInterval(4.95)), "Confirmed once")
    }

    func testConfirmWindowExpires() {
        let start = at(12, 0)
        var confirmation = HardStopConfirmation()
        confirmation.activate(target(.extend(minutes: 15)), at: start)
        XCTAssertNil(confirmation.confirm(at: start.addingTimeInterval(5)), "Too late")
        XCTAssertEqual(confirmation.state, .idle)

        confirmation.activate(target(.extend(minutes: 15)), at: start)
        XCTAssertNil(confirmation.update(now: start.addingTimeInterval(5), sleeps: 0))
        XCTAssertEqual(confirmation.state, .idle, "The window closes on its own")
        XCTAssertNil(confirmation.confirmSecondsLeft(now: start.addingTimeInterval(5)))
        XCTAssertNil(confirmation.confirm(at: start.addingTimeInterval(5.1)))
    }

    func testConfirmationLapsesWhenAnotherStopTakesTheScreen() {
        // Lunch 12:30–13:00 and Walk 13:00–13:30, both dismissable: Walk starts in the same tick that ends Lunch.
        let lunch = lunch(escapeHatch: .dismissEarly)
        let walk = walk(hour: 13, minute: 0, escapeHatch: .dismissEarly)
        var scheduler = makeScheduler([lunch, walk])
        _ = scheduler.tick(now: at(12, 30))
        let lunchOverlay = present(scheduler, at: at(12, 59, 58)).overlay!
        let dismissLunch = HardStopConfirmation.Target(context: lunchOverlay.context, action: .dismiss)

        var held = HardStopConfirmation()
        held.pressBegan(dismissLunch, at: at(12, 59, 58), sleeps: 0)
        var pending = HardStopConfirmation()
        pending.activate(dismissLunch, at: at(12, 59, 58))
        XCTAssertFalse(held.keep(only: lunchOverlay), "Still Lunch's Dismiss")

        XCTAssertEqual(scheduler.tick(now: at(13, 0)).last, .hardStopStarted(id: walk.id, endsAt: at(13, 30)))
        let walkOverlay = present(scheduler, at: at(13, 0)).overlay!
        XCTAssertEqual(walkOverlay.actions, [.dismiss])
        XCTAssertTrue(held.keep(only: walkOverlay))
        XCTAssertNil(held.update(now: at(13, 0, 1), sleeps: 0), "The hold on Lunch does not finish on Walk")
        XCTAssertTrue(pending.keep(only: walkOverlay))
        XCTAssertNil(pending.confirm(at: at(13, 0, 1)), "Nor does a pending Confirm")

        // Even a confirmation that reaches the controller does nothing to Walk.
        XCTAssertTrue(HardStopPresentation.perform(dismissLunch, on: &scheduler, now: at(13, 0, 1)).isEmpty)
        XCTAssertEqual(scheduler.snapshot.activeHardStop?.id, walk.id)
        let dismissWalk = HardStopConfirmation.Target(context: walkOverlay.context, action: .dismiss)
        XCTAssertEqual(HardStopPresentation.perform(dismissWalk, on: &scheduler, now: at(13, 0, 4)),
                       [.hardStopEnded(id: walk.id, reason: .dismissed)])
    }

    func testConfirmationLapsesWhenItsActionIsNoLongerOffered() {
        let stop = lunch(end: .after(60 * 60), escapeHatch: .extend(minutes: 5, times: 1))
        var scheduler = makeScheduler([stop])
        _ = scheduler.tick(now: at(12, 30))
        let overlay = present(scheduler, at: at(12, 31)).overlay!
        var confirmation = HardStopConfirmation()
        confirmation.activate(HardStopConfirmation.Target(context: overlay.context, action: .extend(minutes: 5)), at: at(12, 31))
        // The overlay changes without dropping the action (its countdown): the confirmation stays.
        XCTAssertFalse(confirmation.keep(only: present(scheduler, at: at(12, 32)).overlay))
        // The extension is used elsewhere and Extend goes away.
        var spent = overlay
        spent.actions = []
        XCTAssertTrue(confirmation.keep(only: spent))
        XCTAssertEqual(confirmation.state, .idle)
        // Hidden by an extension: no overlay, nothing pending.
        confirmation.activate(HardStopConfirmation.Target(context: overlay.context, action: .extend(minutes: 5)), at: at(12, 33))
        XCTAssertTrue(confirmation.keep(only: nil))
    }
}

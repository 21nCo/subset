import XCTest
// Mac only: the BreaksMacTests bundle compiles the shared sources and `Mac/HardStopPresentation.swift` directly.

final class HardStopPresentationTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private let locale = Locale(identifier: "en_GB")

    /// Monday 10 August 2026 at `hour`:`minute` UTC, plus `seconds`.
    private func at(_ hour: Int, _ minute: Int, _ seconds: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: hour, minute: minute, second: seconds))!
    }

    private func lunch(
        end: HardStop.End = .after(30 * 60),
        escapeHatch: HardStop.EscapeHatch = .none,
        duringCalls: HardStop.CallBehavior = .waitForCallToEnd
    ) -> HardStop {
        HardStop(name: "Lunch", hour: 12, minute: 30, end: end, repeats: .weekdays([2]), warningMinutes: [10],
                 escapeHatch: escapeHatch, duringCalls: duringCalls)
    }

    private func makeScheduler(_ stops: [HardStop]) -> BreakScheduler {
        var settings = BreakSettings()
        settings.officeHours.isEnabled = false
        settings.plannedBreaks = []
        settings.workInterval = 8 * 3600
        settings.wellness.blinkEnabled = false
        settings.wellness.postureEnabled = false
        settings.hardStops = stops
        let start = at(12, 0)
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
        XCTAssertEqual(scheduler.tick(now: at(12, 20)), [.hardStopWarning(id: stop.id, startsAt: at(12, 30), waitingForCall: false)])
        let subject = HardStopPresentation.NoticeSubject.warning(id: stop.id, startsAt: at(12, 30))

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

    func testWarningNoticeWhileWaitingForACall() {
        let stop = lunch()
        var scheduler = makeScheduler([stop])
        // The meeting signal also pauses reminders.
        XCTAssertEqual(scheduler.tick(now: at(12, 20), inputs: .init(signals: [.meeting])),
                       [.hardStopWarning(id: stop.id, startsAt: at(12, 30), waitingForCall: true), .paused(.meeting)])
        let subject = HardStopPresentation.NoticeSubject.warning(id: stop.id, startsAt: at(12, 30))

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
        let anywaySubject = HardStopPresentation.NoticeSubject.warning(id: anyway.id, startsAt: at(12, 30))
        XCTAssertNil(present(starts, at: at(12, 25), notice: anywaySubject, inCall: true).notice?.detail)
        XCTAssertNil(present(starts, at: at(12, 30), notice: anywaySubject, inCall: true).notice)
    }

    func testWarningNoticeClosesWhenItsStopIsRemovedOrDisabled() {
        let stop = lunch()
        var scheduler = makeScheduler([stop])
        _ = scheduler.tick(now: at(12, 20))
        let subject = HardStopPresentation.NoticeSubject.warning(id: stop.id, startsAt: at(12, 30))
        scheduler.settings.hardStops[0].isEnabled = false
        XCTAssertNil(present(scheduler, at: at(12, 21), notice: subject).notice)
        scheduler.settings.hardStops = []
        XCTAssertNil(present(scheduler, at: at(12, 21), notice: subject).notice)
    }

    func testWarningForALaterStopShowsWhileAStopRuns() {
        // Lunch 12:30–13:00 with one 15-minute extension; Walk at 13:05 with a 35-minute warning, due as Lunch starts.
        let lunch = lunch(escapeHatch: .extend(minutes: 15, times: 1))
        let walk = walk(warnings: [35])
        var scheduler = makeScheduler([lunch, walk])
        XCTAssertEqual(scheduler.tick(now: at(12, 30)), [
            .hardStopStarted(id: lunch.id, endsAt: at(13, 0)),
            .hardStopWarning(id: walk.id, startsAt: at(13, 5), waitingForCall: false)
        ])
        let subject = HardStopPresentation.NoticeSubject.warning(id: walk.id, startsAt: at(13, 5))

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
        XCTAssertNil(present(scheduler, at: at(12, 40), notice: .warning(id: inside.id, startsAt: at(12, 45))).notice)
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
        XCTAssertEqual(scheduler.tick(now: at(12, 44)), [.hardStopWarning(id: walk.id, startsAt: at(13, 5), waitingForCall: false)])
        XCTAssertEqual(HardStopPresentation.extensionWarningDue(scheduler, now: at(12, 44)), at(12, 45))

        // The controller queues the warning from the events, then the extension notice.
        var queue = HardStopNoticeQueue()
        let warning = HardStopPresentation.NoticeSubject.warning(id: walk.id, startsAt: at(13, 5))
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
        queue.add(.warning(id: late, startsAt: at(14, 0)))
        queue.add(.warning(id: early, startsAt: at(13, 0)))
        XCTAssertEqual(queue.shown, .warning(id: early, startsAt: at(13, 0)))
        queue.closeShown()
        XCTAssertEqual(queue.shown, .warning(id: late, startsAt: at(14, 0)), "Closing one shows the next instead of dropping it")
        // A later warning time for the same stop shows it again once closed.
        queue.closeShown()
        XCTAssertNil(queue.shown)
        queue.add(.warning(id: late, startsAt: at(14, 0)))
        queue.add(.warning(id: late, startsAt: at(14, 0)))
        XCTAssertEqual(queue.subjects, [.warning(id: late, startsAt: at(14, 0))])
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

    func testStopThatEndedWhileTheAppWasOffEndsWithoutAChime() {
        let stop = lunch()
        var running = makeScheduler([stop])
        _ = running.tick(now: at(12, 30))

        // Relaunched after the end: the first tick ends the restored stop, and that end is silent.
        var restored = BreakScheduler(settings: running.settings, snapshot: running.snapshot, records: running.records,
                                      calendar: calendar)
        restored.reconcileRestoredState(now: at(13, 20))
        XCTAssertEqual(restored.tick(now: at(13, 20)), [.hardStopEnded(id: stop.id, reason: .ended)])
        XCTAssertFalse(HardStopPresentation.chimesOnEnd(.ended, afterRelaunch: true))

        // An end reached while the app runs chimes; a dismissal or a missed stop never does.
        XCTAssertEqual(running.tick(now: at(13, 0)), [.hardStopEnded(id: stop.id, reason: .ended)])
        XCTAssertTrue(HardStopPresentation.chimesOnEnd(.ended, afterRelaunch: false))
        XCTAssertFalse(HardStopPresentation.chimesOnEnd(.dismissed, afterRelaunch: false))
        XCTAssertFalse(HardStopPresentation.chimesOnEnd(.missed, afterRelaunch: false))
    }

    func testHardStopNoticeDueUnderTheOverlayGoesAboveIt() {
        // Walk's 10-minute warning comes due at 12:55, while Lunch (12:30–13:00) covers the screen.
        let lunch = lunch()
        let walk = walk(hour: 13, minute: 5)
        var scheduler = makeScheduler([lunch, walk])
        _ = scheduler.tick(now: at(12, 30))
        XCTAssertEqual(scheduler.tick(now: at(12, 55)), [.hardStopWarning(id: walk.id, startsAt: at(13, 5), waitingForCall: false)])
        let shown = present(scheduler, at: at(12, 55), notice: .warning(id: walk.id, startsAt: at(13, 5)))
        XCTAssertNotNil(shown.overlay)
        XCTAssertNotNil(shown.notice)
        XCTAssertEqual(HardStopPresentation.noticeLayer(showsHardStopNotice: shown.notice != nil, overlayVisible: shown.overlay != nil),
                       .aboveOverlay)

        // Without the overlay, and always for the regular heads-up, the panel floats above other apps only.
        XCTAssertEqual(HardStopPresentation.noticeLayer(showsHardStopNotice: true, overlayVisible: false), .floating)
        XCTAssertEqual(HardStopPresentation.noticeLayer(showsHardStopNotice: false, overlayVisible: true), .floating)
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

    // MARK: - Confirmation

    private let lunchContext = HardStopPresentation.StopContext(id: UUID(), occurrenceKey: 1, endsAt: nil)
    private func target(_ action: HardStopPresentation.OverlayAction) -> HardStopConfirmation.Target {
        HardStopConfirmation.Target(context: lunchContext, action: action)
    }

    func testPointerHoldConfirmsAfterThreeSeconds() {
        let start = at(12, 0)
        var confirmation = HardStopConfirmation()
        confirmation.pressBegan(target(.dismiss), at: start)
        XCTAssertEqual(confirmation.holdProgress(of: target(.dismiss), now: start.addingTimeInterval(1.5)), 0.5)
        XCTAssertEqual(confirmation.holdProgress(of: target(.extend(minutes: 5)), now: start.addingTimeInterval(1.5)), 0)
        XCTAssertNil(confirmation.update(now: start.addingTimeInterval(2.9)))
        XCTAssertEqual(confirmation.update(now: start.addingTimeInterval(3)), target(.dismiss))
        // Reported once: neither a later update nor the release runs it again.
        XCTAssertNil(confirmation.update(now: start.addingTimeInterval(3.5)))
        XCTAssertNil(confirmation.pressEnded(at: start.addingTimeInterval(4)))
        XCTAssertEqual(confirmation.state, .idle)

        // A release at 3 seconds that comes before the update still confirms, once.
        confirmation.pressBegan(target(.extend(minutes: 15)), at: start)
        XCTAssertEqual(confirmation.pressEnded(at: start.addingTimeInterval(3)), target(.extend(minutes: 15)))
        XCTAssertNil(confirmation.update(now: start.addingTimeInterval(3.1)))
    }

    func testReleasingEarlyCancelsTheHold() {
        let start = at(12, 0)
        var confirmation = HardStopConfirmation()
        confirmation.pressBegan(target(.extend(minutes: 15)), at: start)
        XCTAssertNil(confirmation.pressEnded(at: start.addingTimeInterval(2.5)))
        XCTAssertEqual(confirmation.state, .idle)
        XCTAssertNil(confirmation.update(now: start.addingTimeInterval(3)))
        XCTAssertEqual(confirmation.holdProgress(of: target(.extend(minutes: 15)), now: start.addingTimeInterval(3)), 0)
        // A click is a cancelled hold too: it does not arm the keyboard confirmation.
        XCTAssertNil(confirmation.confirm(at: start.addingTimeInterval(3)))
    }

    func testKeyboardConfirmsInTwoStepsWithinFiveSeconds() {
        let start = at(12, 0)
        var confirmation = HardStopConfirmation()
        XCTAssertNil(confirmation.confirm(at: start), "Confirm does nothing before the button is activated")
        confirmation.activate(target(.dismiss), at: start)
        XCTAssertEqual(confirmation.state, .awaitingConfirm(target(.dismiss), until: start.addingTimeInterval(5)))
        XCTAssertEqual(confirmation.confirmSecondsLeft(now: start.addingTimeInterval(0.5)), 5)
        XCTAssertNil(confirmation.update(now: start.addingTimeInterval(4.9)))
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
        XCTAssertNil(confirmation.update(now: start.addingTimeInterval(5)))
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
        held.pressBegan(dismissLunch, at: at(12, 59, 58))
        var pending = HardStopConfirmation()
        pending.activate(dismissLunch, at: at(12, 59, 58))
        XCTAssertFalse(held.keep(only: lunchOverlay), "Still Lunch's Dismiss")

        XCTAssertEqual(scheduler.tick(now: at(13, 0)).last, .hardStopStarted(id: walk.id, endsAt: at(13, 30)))
        let walkOverlay = present(scheduler, at: at(13, 0)).overlay!
        XCTAssertEqual(walkOverlay.actions, [.dismiss])
        XCTAssertTrue(held.keep(only: walkOverlay))
        XCTAssertNil(held.update(now: at(13, 0, 1)), "The hold on Lunch does not finish on Walk")
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

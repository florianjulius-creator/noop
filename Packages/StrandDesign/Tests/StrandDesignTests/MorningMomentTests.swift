import XCTest
@testable import StrandDesign

final class MorningMomentTests: XCTestCase {

    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c }
    private var now: Date { cal.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 7, minute: 0))! }

    private func snapshot(scoreDay: String? = "2026-09-04", charge: Double? = 78, rest: Double? = 84,
                          asOf: Date? = nil) -> WatchScoreSnapshot {
        var s = WatchScoreSnapshot(charge: charge, chargeCalibrating: false,
                                   effort: 40, effortCalibrating: false,
                                   rest: rest, restCalibrating: false,
                                   hr: 52, sleepSummary: "", asOf: asOf ?? now.addingTimeInterval(-600),
                                   scoreDay: scoreDay, hrvMs: 62)
        s.restingHr = 49; s.restingHrBaseline = 51; s.hrvBaselineMs = 58
        s.sleepMin = 432; s.sleepEfficiencyPct = 91
        s.briefing = "Vol gas."; s.briefingDay = "2026-09-04"; s.briefingStatus = "OK 06:52"
        return s
    }

    // MARK: scores

    func testFreshWhenScoreDayIsToday() {
        let m = MorningMoment(snapshot: snapshot(), now: now, calendar: cal)
        XCTAssertEqual(m.scores, .fresh(recovery: 78, sleep: 84))
        XCTAssertEqual(m.verdict, "KLAAR")
        XCTAssertEqual(m.briefing, "Vol gas.")
    }

    func testNotScoredWhenScoreDayIsYesterday() {
        let m = MorningMoment(snapshot: snapshot(scoreDay: "2026-09-03"), now: now, calendar: cal)
        XCTAssertEqual(m.scores, .notScored)
        XCTAssertNil(m.verdict)
        XCTAssertNil(m.briefing)
        XCTAssertNil(m.hrvDeltaPct)
        XCTAssertNil(m.bars.hrv)
    }

    func testNotScoredWhenSnapshotStaleOrMissing() {
        let stale = snapshot(asOf: now.addingTimeInterval(-40 * 3600))
        XCTAssertEqual(MorningMoment(snapshot: stale, now: now, calendar: cal).scores, .notScored)
        XCTAssertEqual(MorningMoment(snapshot: nil, now: now, calendar: cal).scores, .notScored)
    }

    func testYesterdaysBriefingIsSuppressed() {
        var s = snapshot(); s.briefingDay = "2026-09-03"
        XCTAssertNil(MorningMoment(snapshot: s, now: now, calendar: cal).briefing)
    }

    // MARK: verdict

    func testVerdictThresholds() {
        XCTAssertEqual(MorningMoment.verdict(recovery: 67), "KLAAR")
        XCTAssertEqual(MorningMoment.verdict(recovery: 66.9), "MATIG")
        XCTAssertEqual(MorningMoment.verdict(recovery: 34), "MATIG")
        XCTAssertEqual(MorningMoment.verdict(recovery: 33.9), "RUST")
        XCTAssertEqual(MorningMoment.verdictLine(for: "KLAAR"), "Klaar voor volle training")
        XCTAssertEqual(MorningMoment.verdictLine(for: "MATIG"), "Rustig aan vandaag")
        XCTAssertEqual(MorningMoment.verdictLine(for: "RUST"), "Rust is verstandig")
    }

    // MARK: HRV delta + bars

    func testHrvDeltaAndBars() {
        let m = MorningMoment(snapshot: snapshot(), now: now, calendar: cal)
        XCTAssertEqual(m.hrvDeltaPct, 7)                       // (62-58)/58 = 6.9 → 7
        XCTAssertEqual(m.bars.hrv!, 62.0 / (1.25 * 58.0), accuracy: 1e-9)
        XCTAssertEqual(m.bars.rhr!, 1.0, accuracy: 1e-9)       // 51/49 clamps to 1
        XCTAssertEqual(m.bars.sleep!, 0.84, accuracy: 1e-9)
    }

    func testHrvDeltaNilWithoutBaseline() {
        var s = snapshot(); s.hrvBaselineMs = nil
        let m = MorningMoment(snapshot: s, now: now, calendar: cal)
        XCTAssertNil(m.hrvDeltaPct)
        XCTAssertNil(m.bars.hrv)
    }

    // MARK: status text

    func testBriefingStatusText() {
        XCTAssertEqual(BriefingStatus.ok(time: "06:52").text, "OK 06:52")
        XCTAssertEqual(BriefingStatus.disabled.text, "uitgeschakeld")
        XCTAssertEqual(BriefingStatus.noKey.text, "geen API-key")
        XCTAssertEqual(BriefingStatus.noScoredNight.text, "geen gescoorde nacht")
        XCTAssertEqual(BriefingStatus.tooEarly.text, "te vroeg (< 06:00)")
        XCTAssertEqual(BriefingStatus.emptyReply.text, "leeg antwoord")
        XCTAssertEqual(BriefingStatus.apiError("401").text, "API-fout: 401")
    }

    // MARK: schedule

    func testNextFireIsTodayWhenStillAhead() {
        let at = cal.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 5, minute: 30))!
        let fire = MorningSchedule.nextFire(after: at, hour: 7, minute: 0, calendar: cal)
        XCTAssertEqual(fire, cal.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 7, minute: 0))!)
    }

    func testNextFireRollsToTomorrowOnceElapsed() {
        let at = cal.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 7, minute: 0))!
        let fire = MorningSchedule.nextFire(after: at, hour: 7, minute: 0, calendar: cal)
        XCTAssertEqual(fire, cal.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 7, minute: 0))!)
    }

    func testRefreshDateWalksTheStagesThenRollsToTomorrow() {
        let fire = cal.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 7, minute: 0))!
        let evening = cal.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 22))!
        // Long before: the first stage, T − 25.
        XCTAssertEqual(MorningSchedule.refreshDate(for: fire, now: evening, calendar: cal),
                       fire.addingTimeInterval(-1500))
        // Inside the first stage's window: the second stage, T − 5.
        let between = fire.addingTimeInterval(-1400)
        XCTAssertEqual(MorningSchedule.refreshDate(for: fire, now: between, calendar: cal),
                       fire.addingTimeInterval(-300))
        // Just before T: the first slot AFTER T (the night is scored once the user is up).
        let late = fire.addingTimeInterval(-120)
        XCTAssertEqual(MorningSchedule.refreshDate(for: fire, now: late, calendar: cal),
                       fire.addingTimeInterval(600))
        // After the last post-T stage: tomorrow's first stage, never a slot minutes away.
        let afternoon = fire.addingTimeInterval(4 * 3600)
        XCTAssertEqual(MorningSchedule.refreshDate(for: fire, now: afternoon, calendar: cal),
                       fire.addingTimeInterval(86_400 - 1500))
    }

    func testFireTodayIsTodaysTimeEvenWhenPassed() {
        let at = cal.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 9, minute: 30))!
        XCTAssertEqual(MorningSchedule.fireToday(now: at, hour: 7, minute: 0, calendar: cal),
                       cal.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 7, minute: 0))!)
    }

    // MARK: plan

    func testPlanFiresNowWhenScoredAfterT() {
        let fire = cal.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: 7, minute: 0))!
        XCTAssertEqual(MorningPlan.decide(scored: true, now: fire.addingTimeInterval(900), fire: fire,
                                          shownToday: false, firedToday: false), .fireNow)
    }

    func testPlanSchedulesAtTWhenScoredEarly() {
        let fire = cal.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: 7, minute: 0))!
        XCTAssertEqual(MorningPlan.decide(scored: true, now: fire.addingTimeInterval(-1200), fire: fire,
                                          shownToday: false, firedToday: false), .scheduleAt(fire))
    }

    func testPlanWaitsWithFallbackWhenNotScored() {
        let fire = cal.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: 7, minute: 0))!
        XCTAssertEqual(MorningPlan.decide(scored: false, now: fire.addingTimeInterval(60), fire: fire,
                                          shownToday: false, firedToday: false),
                       .waitForScore(fallbackAt: fire.addingTimeInterval(5400)))
    }

    func testPlanIsDoneOnceFiredOrShown() {
        let fire = cal.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: 7, minute: 0))!
        XCTAssertEqual(MorningPlan.decide(scored: true, now: fire, fire: fire, shownToday: false, firedToday: true), .done)
        XCTAssertEqual(MorningPlan.decide(scored: false, now: fire, fire: fire, shownToday: true, firedToday: false), .done)
    }
}

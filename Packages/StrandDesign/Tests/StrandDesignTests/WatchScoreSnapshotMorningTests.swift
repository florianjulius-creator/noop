import XCTest
@testable import StrandDesign

/// The morning moment rides on eight OPTIONAL fields added to the phone→watch snapshot. They must
/// round-trip, and a payload from an older phone build (without them) must still decode with them nil.
final class WatchScoreSnapshotMorningTests: XCTestCase {

    func testMorningFieldsRoundTrip() throws {
        var snap = WatchScoreSnapshot(charge: 78, chargeCalibrating: false,
                                      effort: 40, effortCalibrating: false,
                                      rest: 84, restCalibrating: false,
                                      hr: 52, sleepSummary: "7h 12m · 91%",
                                      asOf: Date(timeIntervalSince1970: 1_700_000_000),
                                      scoreDay: "2026-09-04", hrvMs: 62)
        snap.restingHr = 49
        snap.restingHrBaseline = 51
        snap.hrvBaselineMs = 58
        snap.sleepMin = 432
        snap.sleepEfficiencyPct = 91
        snap.briefing = "Je staat er goed voor."
        snap.briefingDay = "2026-09-04"
        snap.briefingStatus = "OK 06:52"

        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(WatchScoreSnapshot.self, from: data)
        XCTAssertEqual(back, snap)
        XCTAssertEqual(back.restingHr, 49)
        XCTAssertEqual(back.restingHrBaseline, 51)
        XCTAssertEqual(back.hrvBaselineMs, 58)
        XCTAssertEqual(back.sleepMin, 432)
        XCTAssertEqual(back.sleepEfficiencyPct, 91)
        XCTAssertEqual(back.briefing, "Je staat er goed voor.")
        XCTAssertEqual(back.briefingDay, "2026-09-04")
        XCTAssertEqual(back.briefingStatus, "OK 06:52")
    }

    func testLegacyPayloadDecodesMorningFieldsAsNil() throws {
        let legacy = """
        {"charge":72,"chargeCalibrating":false,"effort":61,"effortCalibrating":false,
         "rest":84,"restCalibrating":false,"hr":58,"sleepSummary":"7h 12m","asOf":700000000}
        """.data(using: .utf8)!
        let snap = try JSONDecoder().decode(WatchScoreSnapshot.self, from: legacy)
        XCTAssertNil(snap.restingHr)
        XCTAssertNil(snap.restingHrBaseline)
        XCTAssertNil(snap.hrvBaselineMs)
        XCTAssertNil(snap.sleepMin)
        XCTAssertNil(snap.sleepEfficiencyPct)
        XCTAssertNil(snap.briefing)
        XCTAssertNil(snap.briefingDay)
        XCTAssertNil(snap.briefingStatus)
    }

    func testLocalDayKeyUsesGregorianYearMonthDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let date = cal.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 7))!
        XCTAssertEqual(WatchScoreSnapshot.localDayKey(date), "2026-09-04")
    }
}

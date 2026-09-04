# Ochtendmoment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A watch-local notification at a user-chosen time whose custom long look animates Recovery + Sleep rings and scrolls to Recovery / Sleep / Ochtendrapport blocks, with the Watch waking the iPhone for the briefing and no iPhone push.

**Architecture:** Shared `WatchScoreSnapshot` (StrandDesign) grows eight optional fields plus pure models (`MorningMoment`, `BriefingStatus`, `MorningSchedule`) that are unit-tested in the package. The iPhone fills the fields, records a briefing status on every exit path, answers a `requestMorning` message and pushes with a once-a-day complication wake. The Watch owns scheduling: a background refresh at T − 10 min wakes the iPhone, a repeating calendar notification at T fires a `WKNotificationScene` whose controller shows `MorningMomentView`; a fifth deck page holds the settings.

**Tech Stack:** Swift 5 / SwiftUI, WatchKit (`WKApplicationDelegateAdaptor`, `WKUserNotificationHostingController`), UserNotifications, WatchConnectivity, WidgetKit reload, XCTest via `swift test`, xcodegen + xcodebuild (Xcode-beta 27).

Spec: `docs/superpowers/specs/2026-09-04-ochtendmoment-design.md`. Branch: `hrv-complication`. Commit with explicit paths, never `git add -A`.

Build/test commands used throughout (run from the repo root `/Users/airflo/Documents/Trading/noop`):

```bash
# package tests (fast)
(cd Packages/StrandDesign && swift test 2>&1 | tail -3)
# regenerate the Xcode project after adding/removing source files (Strand.xcodeproj is NOT git-tracked)
xcodegen generate
# watch app compile check (unsigned)
env DEVELOPER_DIR=/Applications/Xcode-beta.app xcodebuild -project Strand.xcodeproj -scheme NOOPWatch -configuration Release -destination 'generic/platform=watchOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD" | tail -5
# iOS app compile check (unsigned)
env DEVELOPER_DIR=/Applications/Xcode-beta.app xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -configuration Release -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD" | tail -5
```

---

## File structure

| File | Responsibility |
|---|---|
| `Packages/StrandDesign/Sources/StrandDesign/WatchScoreSnapshot.swift` | + 8 optional wire fields, `localDayKey(_:)` |
| `Packages/StrandDesign/Sources/StrandDesign/MorningMoment.swift` (new) | `BriefingStatus`, `MorningMoment` (snapshot → display state), `MorningSchedule` (fire/refresh dates) |
| `Packages/StrandDesign/Tests/StrandDesignTests/WatchScoreSnapshotMorningTests.swift` (new) | wire round-trip + legacy decode |
| `Packages/StrandDesign/Tests/StrandDesignTests/MorningMomentTests.swift` (new) | states, verdict, HRV delta, bars, status text, schedule |
| `Strand/Data/WatchSessionBridge.swift` | fill fields, `baselines`, `force`/`wakeWatch` push, `requestMorning` message |
| `StrandiOS/App/MorningBriefing.swift` | status recording, no push, returns whether it generated |
| `StrandiOS/App/StrandiOSApp.swift` | wire bridge callback in `init`, push after generation |
| `NOOPWatch/WatchScoreStore.swift` | singleton, userInfo, `requestLatest` / `requestMorning`, pending-until-activated |
| `NOOPWatch/MorningScheduler.swift` (new) | `MorningSettings`, `MorningScheduler`, `MorningRefresh` |
| `NOOPWatch/MorningNotificationController.swift` (new) | long-look controller |
| `NOOPWatch/MorningMomentView.swift` (new) | rings, sparks, blocks |
| `NOOPWatch/WatchMorningSettingsView.swift` (new) | page 5 |
| `NOOPWatch/NOOPWatchApp.swift` | delegate adaptor, notification scene, shared store, richer demo snapshot |
| `NOOPWatch/WatchRootView.swift` | add page 5 |

---

### Task 1: Snapshot wire fields

**Files:**
- Modify: `Packages/StrandDesign/Sources/StrandDesign/WatchScoreSnapshot.swift`
- Create: `Packages/StrandDesign/Tests/StrandDesignTests/WatchScoreSnapshotMorningTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/airflo/Documents/Trading/noop/Packages/StrandDesign && swift test --filter WatchScoreSnapshotMorningTests 2>&1 | tail -5`
Expected: compile error `value of type 'WatchScoreSnapshot' has no member 'restingHr'`.

- [ ] **Step 3: Add the fields and the day-key helper**

In `WatchScoreSnapshot.swift`, after the `hrvMs` property (before `sleepSummary`), add:

```swift
    // MARK: Morning-moment fields (2026-09). All optional + decode as nil when absent so older
    // phone builds stay on the wire. The Watch long look reads these; nothing else does.

    /// Resting heart rate for the anchor day (bpm).
    public var restingHr: Int?
    /// 30-day average resting heart rate (bpm), the baseline the RHR contributor bar compares against.
    public var restingHrBaseline: Int?
    /// 30-day average overnight HRV (whole ms), the baseline `hrvMs` is compared against.
    public var hrvBaselineMs: Int?
    /// Total sleep for the anchor day, whole minutes.
    public var sleepMin: Int?
    /// Sleep efficiency for the anchor day, whole percent (0…100).
    public var sleepEfficiencyPct: Int?
    /// The AI morning briefing text (Dutch), or nil when none was produced.
    public var briefing: String?
    /// The local day key the briefing describes ("YYYY-MM-DD"). The Watch only shows `briefing`
    /// when this equals `scoreDay`, so yesterday's text never sits under today's rings.
    public var briefingDay: String?
    /// Why the iPhone did or did not produce a briefing, already phrased for the Watch settings page
    /// ("OK 06:52", "geen API-key", …). See `BriefingStatus`.
    public var briefingStatus: String?
```

Add a public day-key helper next to `dayKeyFormatter` (keep the formatter private):

```swift
    /// "YYYY-MM-DD" local day key for `date`, the same shape the phone writes into `scoreDay`.
    public static func localDayKey(_ date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }
```

The memberwise-style `init` is unchanged (the new fields default to nil as `var`s).

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/airflo/Documents/Trading/noop/Packages/StrandDesign && swift test --filter WatchScoreSnapshotMorningTests 2>&1 | tail -3`
Expected: `Executed 3 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd /Users/airflo/Documents/Trading/noop
git add Packages/StrandDesign/Sources/StrandDesign/WatchScoreSnapshot.swift Packages/StrandDesign/Tests/StrandDesignTests/WatchScoreSnapshotMorningTests.swift
git commit -m "feat(watch): morning-moment fields on the phone→watch snapshot"
```

---

### Task 2: Pure models — `BriefingStatus`, `MorningMoment`, `MorningSchedule`

**Files:**
- Create: `Packages/StrandDesign/Sources/StrandDesign/MorningMoment.swift`
- Create: `Packages/StrandDesign/Tests/StrandDesignTests/MorningMomentTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
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
        XCTAssertEqual(m.bars.rhr!, 51.0 / 49.0 > 1 ? 1 : 51.0 / 49.0, accuracy: 1e-9)
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

    func testRefreshDateIsTenMinutesBeforeFireButNeverInThePast() {
        let fire = cal.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 7, minute: 0))!
        let early = cal.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 22))!
        XCTAssertEqual(MorningSchedule.refreshDate(for: fire, now: early), fire.addingTimeInterval(-600))
        let late = fire.addingTimeInterval(-120)
        XCTAssertEqual(MorningSchedule.refreshDate(for: fire, now: late), late.addingTimeInterval(60))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/airflo/Documents/Trading/noop/Packages/StrandDesign && swift test --filter MorningMomentTests 2>&1 | tail -5`
Expected: compile error `cannot find 'MorningMoment' in scope`.

- [ ] **Step 3: Write the models**

`Packages/StrandDesign/Sources/StrandDesign/MorningMoment.swift`:

```swift
import Foundation

// MARK: - BriefingStatus
//
// Why the iPhone did (not) produce this morning's AI briefing. Recorded on EVERY exit path of the
// generator and shipped to the Watch as plain text, so a silent failure is impossible: the Watch
// settings page always shows the last reason. Dutch on purpose — it is read on the wrist.
public enum BriefingStatus: Equatable, Sendable {
    case ok(time: String)
    case disabled
    case noKey
    case noScoredNight
    case tooEarly
    case emptyReply
    case apiError(String)

    public var text: String {
        switch self {
        case .ok(let time):      return "OK \(time)"
        case .disabled:          return "uitgeschakeld"
        case .noKey:             return "geen API-key"
        case .noScoredNight:     return "geen gescoorde nacht"
        case .tooEarly:          return "te vroeg (< 06:00)"
        case .emptyReply:        return "leeg antwoord"
        case .apiError(let msg): return "API-fout: \(msg)"
        }
    }
}

// MARK: - MorningMoment
//
// Everything the morning long look shows, derived from one snapshot with no SwiftUI involved, so the
// honesty rules are testable: numbers only when the snapshot describes TODAY and is not stale; the
// briefing only when it describes the same day; nothing borrowed from yesterday.
public struct MorningMoment: Equatable, Sendable {

    public enum Scores: Equatable, Sendable {
        case fresh(recovery: Double?, sleep: Double?)
        case notScored
    }

    public struct Bars: Equatable, Sendable {
        public let hrv: Double?
        public let rhr: Double?
        public let sleep: Double?
    }

    public let scores: Scores
    /// "KLAAR" / "MATIG" / "RUST", nil when there is no fresh recovery number.
    public let verdict: String?
    public let hrvMs: Int?
    public let hrvBaselineMs: Int?
    public let hrvDeltaPct: Int?
    public let restingHr: Int?
    public let restingHrBaseline: Int?
    public let sleepMin: Int?
    public let sleepEfficiencyPct: Int?
    public let briefing: String?
    public let briefingStatus: String?
    public let bars: Bars

    public init(snapshot: WatchScoreSnapshot?, now: Date = Date(), calendar: Calendar = .current) {
        briefingStatus = snapshot?.briefingStatus
        guard let snap = snapshot, !snap.isStale(now: now),
              let day = snap.scoreDay, day == WatchScoreSnapshot.localDayKey(now) else {
            scores = .notScored
            verdict = nil; hrvMs = nil; hrvBaselineMs = nil; hrvDeltaPct = nil
            restingHr = nil; restingHrBaseline = nil; sleepMin = nil; sleepEfficiencyPct = nil
            briefing = nil
            bars = Bars(hrv: nil, rhr: nil, sleep: nil)
            return
        }
        scores = .fresh(recovery: snap.charge, sleep: snap.rest)
        verdict = snap.charge.map(Self.verdict(recovery:))
        hrvMs = snap.hrvMs
        hrvBaselineMs = snap.hrvBaselineMs
        restingHr = snap.restingHr
        restingHrBaseline = snap.restingHrBaseline
        sleepMin = snap.sleepMin
        sleepEfficiencyPct = snap.sleepEfficiencyPct
        briefing = (snap.briefingDay == day) ? snap.briefing : nil

        if let hrv = snap.hrvMs, let base = snap.hrvBaselineMs, base > 0 {
            hrvDeltaPct = Int((Double(hrv - base) / Double(base) * 100).rounded())
        } else {
            hrvDeltaPct = nil
        }
        func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
        let hrvBar: Double? = {
            guard let hrv = snap.hrvMs, let base = snap.hrvBaselineMs, base > 0 else { return nil }
            return clamp(Double(hrv) / (1.25 * Double(base)))
        }()
        let rhrBar: Double? = {
            guard let rhr = snap.restingHr, let base = snap.restingHrBaseline, rhr > 0 else { return nil }
            return clamp(Double(base) / Double(rhr))
        }()
        bars = Bars(hrv: hrvBar, rhr: rhrBar, sleep: snap.rest.map { clamp($0 / 100) })
    }

    /// WHOOP-style zones: green ≥ 67, yellow 34…66, red < 34.
    public static func verdict(recovery: Double) -> String {
        if recovery >= 67 { return "KLAAR" }
        if recovery >= 34 { return "MATIG" }
        return "RUST"
    }

    /// The one-line reading under the verdict in the Recovery block.
    public static func verdictLine(for verdict: String) -> String {
        switch verdict {
        case "KLAAR": return "Klaar voor volle training"
        case "MATIG": return "Rustig aan vandaag"
        default:      return "Rust is verstandig"
        }
    }
}

// MARK: - MorningSchedule
//
// Pure date math for the Watch scheduler: the next hour:minute strictly after `now`, and the
// background-refresh slot ten minutes ahead of it (never in the past, never sooner than a minute).
public enum MorningSchedule {
    public static func nextFire(after now: Date, hour: Int, minute: Int, calendar: Calendar = .current) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        let today = calendar.date(from: comps) ?? now
        if today > now { return today }
        return calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }

    public static func refreshDate(for fire: Date, now: Date) -> Date {
        let preferred = fire.addingTimeInterval(-10 * 60)
        return preferred > now ? preferred : now.addingTimeInterval(60)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/airflo/Documents/Trading/noop/Packages/StrandDesign && swift test 2>&1 | tail -3`
Expected: all StrandDesign tests pass, `MorningMomentTests` executed 11 tests with 0 failures.

- [ ] **Step 5: Commit**

```bash
cd /Users/airflo/Documents/Trading/noop
git add Packages/StrandDesign/Sources/StrandDesign/MorningMoment.swift Packages/StrandDesign/Tests/StrandDesignTests/MorningMomentTests.swift
git commit -m "feat(watch): pure morning-moment, briefing-status and schedule models"
```

---

### Task 3: iPhone — fill the fields, force/wake push, `requestMorning`

**Files:**
- Modify: `Strand/Data/WatchSessionBridge.swift`

- [ ] **Step 1: Add the baselines helper and fill the fields in `buildSnapshot`**

After `static func sleepSummary(for:)`, add:

```swift
    /// 30-day trailing averages for HRV (ms) and resting HR (bpm), rounded to whole numbers. The
    /// morning briefing context and the watch snapshot both read THESE so the wrist and the coach
    /// never quote different baselines.
    static func baselines(days: [DailyMetric]) -> (hrvMs: Int?, restingHr: Int?) {
        let trailing = days.suffix(30)
        func avg(_ values: [Double]) -> Double? {
            values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        let hrv = avg(trailing.compactMap(\.avgHrv))
        let rhr = avg(trailing.compactMap(\.restingHr).map(Double.init))
        return (hrv.map { Int($0.rounded()) }, rhr.map { Int($0.rounded()) })
    }
```

In `buildSnapshot(from:)`, change `let snap = WatchScoreSnapshot(` to `var snap = WatchScoreSnapshot(` and, right before `return snap`, add:

```swift
        // Morning-moment fields. Baselines off the same trailing window the briefing coach uses;
        // the briefing text/status straight from MorningBriefing's storage keys.
        let base = baselines(days: days)
        snap.restingHr = day?.restingHr
        snap.restingHrBaseline = base.restingHr
        snap.hrvBaselineMs = base.hrvMs
        snap.sleepMin = day?.totalSleepMin.map { Int($0.rounded()) }
        snap.sleepEfficiencyPct = day?.efficiency.map { eff in Int((eff <= 1 ? eff * 100 : eff).rounded()) }
        let defaults = UserDefaults.standard
        snap.briefing = defaults.string(forKey: MorningBriefing.lastTextKey)
        snap.briefingDay = defaults.string(forKey: MorningBriefing.lastDayKey)
        snap.briefingStatus = defaults.string(forKey: MorningBriefing.lastStatusKey)
```

(`MorningBriefing.lastStatusKey` is added in Task 4; both files compile in the NOOPiOS target only.)

- [ ] **Step 2: Extend `headlineChanged`**

Replace the `return last.charge != next.charge` chain with:

```swift
        return last.charge != next.charge
            || last.chargeCalibrating != next.chargeCalibrating
            || last.effort != next.effort
            || last.effortCalibrating != next.effortCalibrating
            || last.rest != next.rest
            || last.restCalibrating != next.restCalibrating
            || last.sleepSummary != next.sleepSummary
            || last.scoreDay != next.scoreDay
            || last.hrvMs != next.hrvMs
            || last.restingHr != next.restingHr
            || last.restingHrBaseline != next.restingHrBaseline
            || last.hrvBaselineMs != next.hrvBaselineMs
            || last.sleepMin != next.sleepMin
            || last.sleepEfficiencyPct != next.sleepEfficiencyPct
            || last.briefingDay != next.briefingDay
            || last.briefing != next.briefing
```

(`briefingStatus` is deliberately not headline: a status flip alone never earns a transfer.)

- [ ] **Step 3: `force` + `wakeWatch` on the push path**

Replace `sendLatest(from:)` and `pushLatest(from:)` with:

```swift
    func sendLatest(from model: AppModel, force: Bool = false, wakeWatch: Bool = false) async {
        let snap = await Self.buildSnapshot(from: model)
        let contentless = snap.scoreDay == nil && snap.charge == nil && snap.effort == nil
            && snap.rest == nil && snap.sleepSummary.isEmpty
        if contentless { return }
        let now = Date()
        // `force` (the morning path only) skips the 30-minute spacing gate but still requires substance.
        guard force ? Self.headlineChanged(from: lastSent, to: snap) : shouldPush(snap, now: now) else { return }
        lastPushedAt = now
        send(snap, wakeWatch: wakeWatch)
    }

    func pushLatest(from model: AppModel, force: Bool = false, wakeWatch: Bool = false) async {
        await sendLatest(from: model, force: force, wakeWatch: wakeWatch)
    }
```

Replace `func send(_ snap: WatchScoreSnapshot)` with:

```swift
    func send(_ snap: WatchScoreSnapshot, wakeWatch: Bool = false) {
        lastSent = snap
        snap.save()

        guard let session, session.activationState == .activated else { return }
        isWatchReachable = session.isReachable
        do {
            let data = try JSONEncoder().encode(snap)
            try session.updateApplicationContext([Self.contextKey: data])
            // The morning wake: ONE complication transfer per local day launches the watch app in the
            // background so it persists today's snapshot before the wrist notification fires. Only
            // meaningful (and only budgeted) while a complication is on the active face.
            let today = WatchScoreSnapshot.localDayKey(Date())
            if wakeWatch, session.isComplicationEnabled,
               UserDefaults.standard.string(forKey: Self.lastWakeDayKey) != today {
                UserDefaults.standard.set(today, forKey: Self.lastWakeDayKey)
                session.transferCurrentComplicationUserInfo([Self.contextKey: data])
            }
        } catch {
            // Non-fatal: the app-group mirror carries the value; the next refresh retries.
        }
    }

    static let lastWakeDayKey = "watch.lastWakeDay"
```

- [ ] **Step 4: Handle `requestMorning`**

Add next to `requestLatestKey`:

```swift
    /// The watch's "make this morning's briefing now" request (background refresh or the settings page).
    static let requestMorningKey = "requestMorning"
    static let forceKey = "force"
    /// Set by the app entry: generate the briefing (day-guarded unless forced) and push the wrist.
    var onMorningRequested: ((Bool) async -> Void)?
```

Replace the `didReceiveMessage` delegate method with:

```swift
    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        let wantsLatest = message[Self.requestLatestKey] != nil
        let wantsMorning = message[Self.requestMorningKey] != nil
        guard wantsLatest || wantsMorning else {
            replyHandler([:])
            return
        }
        // Reply at once with the mirrored snapshot so the watch has SOMETHING before the reply
        // window closes; the briefing is generated afterwards and pushed as context.
        if let snap = WatchScoreSnapshot.load(), let data = try? JSONEncoder().encode(snap) {
            replyHandler([Self.contextKey: data])
        } else {
            replyHandler([:])
        }
        if wantsMorning {
            let force = message[Self.forceKey] as? Bool ?? false
            Task { @MainActor in
                await self.onMorningRequested?(force)
            }
        }
    }
```

- [ ] **Step 5: Compile check (expect one error until Task 4)**

Run: `cd /Users/airflo/Documents/Trading/noop && env DEVELOPER_DIR=/Applications/Xcode-beta.app xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -configuration Release -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:" | head -3`
Expected: exactly one error, `type 'MorningBriefing' has no member 'lastStatusKey'` (fixed in Task 4). No other errors.

- [ ] **Step 6: Continue to Task 4 before committing** (the two files compile together).

---

### Task 4: iPhone — `MorningBriefing` records status, no push, returns `Bool`

**Files:**
- Modify: `StrandiOS/App/MorningBriefing.swift`
- Modify: `StrandiOS/App/StrandiOSApp.swift`

- [ ] **Step 1: Rewrite generation + delivery**

In `MorningBriefing.swift`:

1. Change `import UserNotifications` to `import StrandDesign` (for `BriefingStatus`).
2. Add after `lastTextKey`:

```swift
    /// The last outcome, as `BriefingStatus.text` (Dutch), shipped to the Watch settings page.
    static let lastStatusKey = "briefing.lastStatus"

    private static func record(_ status: BriefingStatus) {
        UserDefaults.standard.set(status.text, forKey: lastStatusKey)
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "nl_NL")
        f.dateFormat = "HH:mm"
        return f
    }()
```

3. Replace `generateIfDue` with (note the `@discardableResult Bool`):

```swift
    /// Generate once per local day. Returns true when a NEW briefing was produced by this call, so the
    /// caller knows to push the wrist right away. Every exit records a `BriefingStatus`.
    @discardableResult
    static func generateIfDue(model: AppModel, force: Bool = false, now: Date = Date()) async -> Bool {
        guard enabled else { record(.disabled); return false }
        let todayKey = Repository.localDayKey(now)
        let defaults = UserDefaults.standard
        // Already done today: keep the OK status as it is.
        if !force, defaults.string(forKey: lastDayKey) == todayKey { return false }
        if !force, Calendar.current.component(.hour, from: now) < 6 { record(.tooEarly); return false }
        guard let key = AIKeyStore.read(), !key.isEmpty else { record(.noKey); return false }
        guard let context = buildContext(model: model, todayKey: todayKey) else {
            record(.noScoredNight); return false
        }

        let provider = UserDefaults.standard.string(forKey: "ai.provider")
            .flatMap(AIProvider.init(rawValue:)) ?? .anthropic
        let storedModel = UserDefaults.standard.string(forKey: "ai.model") ?? ""
        let modelId = storedModel.isEmpty ? provider.defaultModel : storedModel

        let reply: String
        do {
            reply = try await provider.client.send(
                key: key,
                model: modelId,
                systemPrompt: Self.systemPrompt,
                messages: [(role: .user, content: context)],
                session: .shared)
        } catch {
            record(.apiError(error.localizedDescription)); return false
        }
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { record(.emptyReply); return false }
        defaults.set(todayKey, forKey: lastDayKey)
        defaults.set(text, forKey: lastTextKey)
        record(.ok(time: clock.string(from: now)))
        return true
    }
```

4. In `buildContext`, replace the local `trailing` / `avg` / `hrvBase` / `rhrBase` block with:

```swift
        let base = WatchSessionBridge.baselines(days: days)
        let yesterday = days.last(where: { $0.day < day.day })
```

and the two baseline lines with:

```swift
        add("hrv_baseline_30d_ms", base.hrvMs.map(String.init))
        add("rustpols_baseline_30d_bpm", base.restingHr.map(String.init))
```

5. Delete the whole `// MARK: - Delivery` section (`notify(_:dayKey:)`). Update the header comment's last paragraph to: `// - No notification is posted on the iPhone any more: the text travels to the Watch inside the WatchScoreSnapshot and is read there (the morning moment).`

- [ ] **Step 2: Wire the app entry**

In `StrandiOSApp.swift`:

1. In `init()`, right after `_model = StateObject(wrappedValue: model)` (line ~34), add:

```swift
        // The watch link comes up in init, not in a view `.task`: a WatchConnectivity message from the
        // wrist can launch this app in the BACKGROUND (no scene, no `.task`), and the delegate must
        // already be set for that message to be delivered. Same reason MorningBriefing.model is set here.
        let bridge = WatchSessionBridge()
        bridge.activate()
        bridge.onMorningRequested = { [weak model, weak bridge] force in
            guard let model, let bridge else { return }
            let fresh = await MorningBriefing.generateIfDue(model: model, force: force)
            await bridge.pushLatest(from: model, force: true, wakeWatch: fresh || force)
        }
        _watch = StateObject(wrappedValue: bridge)
        MorningBriefing.model = model
```

and change the declaration `@StateObject private var watch = WatchSessionBridge()` to `@StateObject private var watch: WatchSessionBridge`.

2. In the launch `.task` (lines ~278–288) replace the body with:

```swift
                .task {
                    watch.activate()
                    // Arm tomorrow's fallback run, catch up today's briefing if due, THEN push the
                    // wrist (forced when a briefing was just produced so the text lands immediately).
                    MorningBriefing.scheduleNext()
                    let fresh = await MorningBriefing.generateIfDue(model: model)
                    await watch.pushLatest(from: model, force: fresh, wakeWatch: fresh)
                }
```

3. In the `.active` scenePhase block, replace

```swift
                    await MorningBriefing.generateIfDue(model: model)
                    await WidgetSnapshot.publish(from: model)
                    ...
                    await watch.pushLatest(from: model)
```

with

```swift
                    let fresh = await MorningBriefing.generateIfDue(model: model)
                    await WidgetSnapshot.publish(from: model)
                    // Push the wrist on the SAME refresh as the Home-screen widget so the watch, the
                    // widget and Today never disagree about which day they describe. Forced when a
                    // briefing was just produced so the text lands immediately.
                    await watch.pushLatest(from: model, force: fresh, wakeWatch: fresh)
```

(Keep the existing comment lines that remain accurate; drop the old "Without this the watch only ever holds placeholder data" sentence if it now reads wrong.)

- [ ] **Step 3: Compile the iOS app**

Run: `cd /Users/airflo/Documents/Trading/noop && env DEVELOPER_DIR=/Applications/Xcode-beta.app xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -configuration Release -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD" | tail -5`
Expected: `** BUILD SUCCEEDED **`, no `error:` lines.

- [ ] **Step 4: Run the package + macOS gate that touches shared code**

Run: `cd /Users/airflo/Documents/Trading/noop/Packages/StrandDesign && swift test 2>&1 | tail -2`
Expected: 0 failures.

- [ ] **Step 5: Commit Tasks 3 + 4 together**

```bash
cd /Users/airflo/Documents/Trading/noop
git add Strand/Data/WatchSessionBridge.swift StrandiOS/App/MorningBriefing.swift StrandiOS/App/StrandiOSApp.swift
git commit -m "feat(iphone): briefing status + fields on the watch snapshot, requestMorning, no iPhone push"
```

---

### Task 5: Watch — shared store with messaging

**Files:**
- Modify: `NOOPWatch/WatchScoreStore.swift`
- Modify: `NOOPWatch/NOOPWatchApp.swift` (store instance + demo snapshot)

- [ ] **Step 1: Make the store a singleton and add messaging**

Replace the whole class body of `WatchScoreStore` (keep the file header comment, append one paragraph: `// Since the morning moment the store is ONE shared instance: the app scene, the notification scene and the background refresh all read and write the same object, and the watch can now ASK the phone for data (requestLatest / requestMorning) instead of only waiting for a push.`) with:

```swift
final class WatchScoreStore: NSObject, ObservableObject, WCSessionDelegate {

    /// The one store every scene shares.
    static let shared = WatchScoreStore()

    @Published private(set) var snapshot: WatchScoreSnapshot?

    static let suiteName: String = WatchScoreSnapshot.appGroupId
    static let storageKey = WatchScoreSnapshot.storageKey

    /// Message keys — must match `WatchSessionBridge` on the phone.
    static let contextKey = "snapshot"
    static let requestLatestKey = "requestLatest"
    static let requestMorningKey = "requestMorning"
    static let forceKey = "force"

    private typealias Pending = (message: [String: Any], completion: (WatchScoreSnapshot?) -> Void)
    /// Messages queued while WCSession is still activating (a background launch sends before the
    /// activation callback lands). Main-thread only.
    private var pending: [Pending] = []

    private override init() {
        super.init()
        snapshot = Self.loadPersisted()
        activate()
    }

    private func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: Persistence (shared with the complication)

    static func loadPersisted() -> WatchScoreSnapshot? {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: storageKey),
              let snap = try? JSONDecoder().decode(WatchScoreSnapshot.self, from: data) else { return nil }
        return snap
    }

    private func persist(_ snap: WatchScoreSnapshot) {
        guard let defaults = UserDefaults(suiteName: Self.suiteName),
              let data = try? JSONEncoder().encode(snap) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// Apply a snapshot unless it is OLDER than the one we hold (a late reply must never roll back a
    /// fresher context). Persists, publishes, reloads the complication. Main actor.
    private func apply(_ snap: WatchScoreSnapshot) {
        DispatchQueue.main.async {
            if let current = self.snapshot, snap.asOf < current.asOf { return }
            self.persist(snap)
            self.snapshot = snap
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Re-read the app group (a background wake may have persisted a newer snapshot from another
    /// launch of this process). Safe to call anytime.
    func reloadFromAppGroup() {
        if let persisted = Self.loadPersisted() { apply(persisted) }
    }

    private func decode(from payload: [String: Any]) -> WatchScoreSnapshot? {
        guard let data = payload[Self.contextKey] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchScoreSnapshot.self, from: data)
    }

    // MARK: Asking the phone

    /// Ask for the phone's latest mirrored snapshot (cheap; the reply applies itself).
    func requestLatest() {
        send([Self.requestLatestKey: true]) { _ in }
    }

    /// Ask the phone to make this morning's briefing now (day-guarded there unless `force`) and push.
    /// `completion` always runs exactly once: with the reply snapshot, or nil when unreachable/failed.
    func requestMorning(force: Bool, completion: @escaping (WatchScoreSnapshot?) -> Void) {
        send([Self.requestMorningKey: true, Self.forceKey: force], completion: completion)
    }

    private func send(_ message: [String: Any], completion: @escaping (WatchScoreSnapshot?) -> Void) {
        guard WCSession.isSupported() else { completion(nil); return }
        let session = WCSession.default
        guard session.activationState == .activated else {
            pending.append((message, completion))
            return
        }
        guard session.isReachable else { completion(nil); return }
        session.sendMessage(message, replyHandler: { [weak self] reply in
            let snap = self?.decode(from: reply)
            if let snap { self?.apply(snap) }
            completion(snap)
        }, errorHandler: { _ in
            completion(nil)
        })
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if let snap = decode(from: session.receivedApplicationContext) {
            apply(snap)
        }
        DispatchQueue.main.async {
            let queued = self.pending
            self.pending = []
            for item in queued { self.send(item.message, completion: item.completion) }
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if let snap = decode(from: applicationContext) { apply(snap) }
    }

    /// The phone's once-a-day complication transfer (the morning wake) lands here.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let snap = decode(from: userInfo) { apply(snap) }
    }

    #if os(watchOS)
    func sessionReachabilityDidChange(_ session: WCSession) {}
    #endif
}
```

- [ ] **Step 2: Use the shared store in the App and enrich the demo snapshot**

In `NOOPWatchApp.swift`:

- `@StateObject private var store = WatchScoreStore()` → `@StateObject private var store = WatchScoreStore.shared`
- Replace `seedDemoSnapshotIfNeeded` body with:

```swift
    static func seedDemoSnapshotIfNeeded() {
        guard WatchScoreSnapshot.load() == nil else { return }
        let today = WatchScoreSnapshot.localDayKey(Date())
        var demo = WatchScoreSnapshot(charge: 78, chargeCalibrating: false,
                                      effort: 61, effortCalibrating: false,
                                      rest: 84, restCalibrating: false,
                                      hr: 58, sleepSummary: "7h 12m · 91%",
                                      asOf: Date(), scoreDay: today, hrvMs: 62)
        demo.restingHr = 49
        demo.restingHrBaseline = 51
        demo.hrvBaselineMs = 58
        demo.sleepMin = 432
        demo.sleepEfficiencyPct = 91
        demo.briefing = "Je staat er goed voor: HRV boven je baseline en rustpols lager dan gemiddeld, met een volle nacht. De geplande JOIN-training kan vol."
        demo.briefingDay = today
        demo.briefingStatus = "OK 06:52"
        demo.save()
    }
```

- [ ] **Step 3: Compile the watch app**

Run: `cd /Users/airflo/Documents/Trading/noop && env DEVELOPER_DIR=/Applications/Xcode-beta.app xcodebuild -project Strand.xcodeproj -scheme NOOPWatch -configuration Release -destination 'generic/platform=watchOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD" | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd /Users/airflo/Documents/Trading/noop
git add NOOPWatch/WatchScoreStore.swift NOOPWatch/NOOPWatchApp.swift
git commit -m "feat(watch): shared score store that can ask the phone (requestLatest/requestMorning)"
```

---

### Task 6: Watch — settings, scheduler, background refresh

**Files:**
- Create: `NOOPWatch/MorningScheduler.swift`
- Modify: `NOOPWatch/NOOPWatchApp.swift` (delegate adaptor)

- [ ] **Step 1: Write `MorningScheduler.swift`**

```swift
import Foundation
import UserNotifications
import WatchKit
import StrandDesign

// MARK: - MorningSettings — the user's choices, on the watch
enum MorningSettings {
    static let enabledKey = "morning.enabled"
    static let hourKey = "morning.hour"
    static let minuteKey = "morning.minute"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
    static var hour: Int {
        get { UserDefaults.standard.object(forKey: hourKey) as? Int ?? 7 }
        set { UserDefaults.standard.set(newValue, forKey: hourKey) }
    }
    static var minute: Int {
        get { UserDefaults.standard.object(forKey: minuteKey) as? Int ?? 0 }
        set { UserDefaults.standard.set(newValue, forKey: minuteKey) }
    }

    /// Today at hour:minute, for the DatePicker.
    static func timeAsDate(now: Date = Date()) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = minute
        return Calendar.current.date(from: comps) ?? now
    }

    static func set(time: Date) {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        hour = comps.hour ?? 7
        minute = comps.minute ?? 0
    }
}

// MARK: - MorningScheduler — the notification + the background refresh ahead of it
//
// The Watch owns the morning clock. Two things are armed from here, idempotently, on launch and after
// every settings change: the repeating calendar notification at T (category MORNING → the custom long
// look), and a background app refresh at T − 10 min whose only job is to wake the phone for today's
// scores + briefing (MorningRefresh). "Test nu" arms a one-shot copy 10 s out.
enum MorningScheduler {
    static let category = "MORNING"
    static let notificationId = "morning-moment"
    static let testId = "morning-test"

    static func rearm() async {
        await scheduleNotification()
        scheduleRefresh()
    }

    static func scheduleNotification() async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationId])
        guard MorningSettings.enabled else { return }
        await requestAuthorizationIfNeeded(center)
        var comps = DateComponents()
        comps.hour = MorningSettings.hour
        comps.minute = MorningSettings.minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        let request = UNNotificationRequest(identifier: notificationId, content: content(), trigger: trigger)
        try? await center.add(request)
    }

    static func scheduleTest() async {
        let center = UNUserNotificationCenter.current()
        await requestAuthorizationIfNeeded(center)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 10, repeats: false)
        let request = UNNotificationRequest(identifier: testId, content: content(), trigger: trigger)
        try? await center.add(request)
    }

    static func scheduleRefresh(now: Date = Date()) {
        guard MorningSettings.enabled else { return }
        let fire = MorningSchedule.nextFire(after: now, hour: MorningSettings.hour, minute: MorningSettings.minute)
        let preferred = MorningSchedule.refreshDate(for: fire, now: now)
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: preferred, userInfo: nil) { _ in }
    }

    private static func content() -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = String(localized: "Goedemorgen")
        c.body = String(localized: "Je ochtendrapport staat klaar")
        c.categoryIdentifier = category
        c.sound = .default
        return c
    }

    private static func requestAuthorizationIfNeeded(_ center: UNUserNotificationCenter) async {
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }
}

// MARK: - MorningRefresh — the T − 10 min background run
//
// Sends requestMorning to the phone (reachable from a background refresh task), applies whatever comes
// back, re-arms the next slot, and completes the WatchKit task exactly once — on reply, on error, or on
// a 25 s timeout so the task budget is never blown.
@MainActor
final class MorningRefresh {
    private var finished = false
    private let completion: () -> Void

    private init(completion: @escaping () -> Void) {
        self.completion = completion
    }

    static func run(completion: @escaping () -> Void) {
        let run = MorningRefresh(completion: completion)
        WatchScoreStore.shared.requestMorning(force: false) { _ in
            Task { @MainActor in run.finish() }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            run.finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        MorningScheduler.scheduleRefresh()
        completion()
    }
}

// MARK: - WatchAppDelegate — launch hook + background task dispatch
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        Task { await MorningScheduler.rearm() }
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let refresh = task as? WKApplicationRefreshBackgroundTask {
                Task { @MainActor in
                    MorningRefresh.run { refresh.setTaskCompletedWithSnapshot(false) }
                }
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}
```

- [ ] **Step 2: Attach the delegate**

In `NOOPWatchApp.swift`, inside `struct NOOPWatchApp: App`, add before the `@StateObject` lines:

```swift
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
```

- [ ] **Step 3: Regenerate the project and compile**

Run:
```bash
cd /Users/airflo/Documents/Trading/noop && xcodegen generate 2>&1 | tail -1 && env DEVELOPER_DIR=/Applications/Xcode-beta.app xcodebuild -project Strand.xcodeproj -scheme NOOPWatch -configuration Release -destination 'generic/platform=watchOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD" | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd /Users/airflo/Documents/Trading/noop
git add NOOPWatch/MorningScheduler.swift NOOPWatch/NOOPWatchApp.swift
git commit -m "feat(watch): morning notification scheduler + T-10 background refresh that wakes the phone"
```

---

### Task 7: Watch — the long look (`MorningMomentView` + controller + scene)

**Files:**
- Create: `NOOPWatch/MorningMomentView.swift`
- Create: `NOOPWatch/MorningNotificationController.swift`
- Modify: `NOOPWatch/NOOPWatchApp.swift` (notification scene)

- [ ] **Step 1: Write `MorningMomentView.swift`**

```swift
import SwiftUI
import WatchKit
import StrandDesign

// MARK: - MorningMomentView — the full-screen morning long look
//
// Rendered by the MORNING notification's custom long look AND by the settings page's preview. Two
// concentric rings (Recovery outside in the recovery colour, Sleep inside in the app blue) sweep in with
// a spark trail and a burst on arrival; below, the Crown scrolls to the Recovery / Slaap / Ochtendrapport
// blocks. Every number comes from `MorningMoment`, so a not-scored morning is an empty track + a dash,
// never yesterday's figures. Reduce Motion: no sweep, no sparks, haptic kept.
struct MorningMomentView: View {
    @ObservedObject var store: WatchScoreStore
    var celebrate: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var moment: MorningMoment { MorningMoment(snapshot: store.snapshot) }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                MorningRingsView(moment: moment, animated: celebrate && !reduceMotion)
                switch moment.scores {
                case .fresh: blocks
                case .notScored: notScored
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            if celebrate { WKInterfaceDevice.current().play(.notification) }
        }
    }

    @ViewBuilder private var blocks: some View {
        MorningBlock(title: "RECOVERY", accent: recoveryColor) {
            if let verdict = moment.verdict {
                Text(MorningMoment.verdictLine(for: verdict))
                    .font(StrandFont.rounded(15, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            if let hrv = moment.hrvMs {
                ContributorBar(label: hrvLabel(hrv), value: moment.bars.hrv, color: recoveryColor)
            }
            if let rhr = moment.restingHr {
                ContributorBar(label: "Rustpols \(rhr)", value: moment.bars.rhr, color: recoveryColor)
            }
            if let min = moment.sleepMin {
                ContributorBar(label: "Slaap \(min / 60)u\(String(format: "%02d", min % 60))",
                               value: moment.bars.sleep, color: recoveryColor)
            }
        }
        MorningBlock(title: "SLAAP", accent: StrandPalette.restLine) {
            if let min = moment.sleepMin {
                Text("\(min / 60)u \(min % 60)m")
                    .font(StrandFont.rounded(22, weight: .heavy))
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            HStack(spacing: 6) {
                if let eff = moment.sleepEfficiencyPct { Text("Efficiëntie \(eff)%") }
                if case .fresh(_, let sleep) = moment.scores, let sleep {
                    Text("·")
                    Text("Rest \(Int(sleep.rounded()))")
                }
            }
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textSecondary)
        }
        if let text = moment.briefing {
            MorningBlock(title: "OCHTENDRAPPORT", accent: StrandPalette.textTertiary) {
                Text(text)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var notScored: some View {
        MorningBlock(title: "NACHT", accent: StrandPalette.textTertiary) {
            Text("Nog niet gesynct. Open The Machine op je iPhone.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var recoveryColor: Color {
        if case .fresh(let recovery, _) = moment.scores, let recovery {
            return StrandPalette.recoveryColor(recovery)
        }
        return StrandPalette.textTertiary
    }

    private func hrvLabel(_ hrv: Int) -> String {
        if let delta = moment.hrvDeltaPct {
            return "HRV \(hrv) ms (\(delta >= 0 ? "+" : "")\(delta)%)"
        }
        return "HRV \(hrv) ms"
    }
}

// MARK: - MorningRingsView — two concentric rings, sweep + number + verdict

struct MorningRingsView: View {
    let moment: MorningMoment
    let animated: Bool
    @State private var appeared = false

    private let outer: CGFloat = 150
    private let inner: CGFloat = 106
    private let width: CGFloat = 15

    private var recovery: Double? {
        if case .fresh(let r, _) = moment.scores { return r }
        return nil
    }
    private var sleep: Double? {
        if case .fresh(_, let s) = moment.scores { return s }
        return nil
    }
    private var recoveryColor: Color {
        recovery.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textTertiary
    }
    private var recoveryFill: CGFloat { appeared ? CGFloat((recovery ?? 0) / 100) : 0 }
    private var sleepFill: CGFloat { appeared ? CGFloat((sleep ?? 0) / 100) : 0 }
    private var shownRecovery: Double { appeared ? (recovery ?? 0) : 0 }

    var body: some View {
        ZStack {
            track(outer)
            track(inner)
            arc(fill: recoveryFill, color: recoveryColor, diameter: outer)
            arc(fill: sleepFill, color: StrandPalette.restLine, diameter: inner)
            if animated && appeared && recovery != nil {
                SparkLayer(outerRadius: outer / 2, innerRadius: inner / 2,
                           outerFraction: CGFloat((recovery ?? 0) / 100),
                           innerFraction: CGFloat((sleep ?? 0) / 100),
                           outerColor: recoveryColor, innerColor: StrandPalette.restLine)
            }
            center
        }
        .frame(width: outer + 10, height: outer + 10)
        .animation(animated ? .spring(response: 1.1, dampingFraction: 0.85) : nil, value: appeared)
        .onAppear {
            if animated {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { appeared = true }
            } else {
                appeared = true
            }
        }
    }

    private func track(_ diameter: CGFloat) -> some View {
        Circle()
            .stroke(Color.white.opacity(0.09), style: StrokeStyle(lineWidth: width, lineCap: .round))
            .frame(width: diameter, height: diameter)
    }

    private func arc(fill: CGFloat, color: Color, diameter: CGFloat) -> some View {
        Circle()
            .trim(from: 0, to: max(0.0001, fill))
            .rotation(.degrees(-90))
            .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
            .frame(width: diameter, height: diameter)
    }

    @ViewBuilder private var center: some View {
        VStack(spacing: 1) {
            if let recovery {
                Text("\(Int(shownRecovery.rounded()))")
                    .font(StrandFont.rounded(40, weight: .heavy))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(animated ? .easeOut(duration: 1.0) : nil, value: shownRecovery)
                Text("RECOVERY")
                    .font(StrandFont.overlineScaled(8))
                    .tracking(1.2)
                    .foregroundStyle(StrandPalette.textTertiary)
                if let verdict = moment.verdict {
                    Text(verdict)
                        .font(StrandFont.rounded(10, weight: .heavy))
                        .tracking(0.6)
                        .foregroundStyle(StrandPalette.recoveryColor(recovery))
                }
            } else {
                Text("–")
                    .font(StrandFont.rounded(40, weight: .heavy))
                    .foregroundStyle(StrandPalette.textTertiary)
                Text("RECOVERY")
                    .font(StrandFont.overlineScaled(8))
                    .tracking(1.2)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }
}

// MARK: - SparkLayer — comet tail during the sweep, burst on arrival, gone after 3 s

struct SparkLayer: View {
    struct Spark {
        let ring: Int          // 0 outer, 1 inner
        let born: Double       // seconds after start
        let angleJitter: Double
        let speed: Double
        let drift: Double
        let size: Double
    }

    let outerRadius: CGFloat
    let innerRadius: CGFloat
    let outerFraction: CGFloat
    let innerFraction: CGFloat
    let outerColor: Color
    let innerColor: Color

    private let sparks: [Spark]
    private let start = Date()
    private static let sweep = 1.2
    private static let life = 0.9
    private static let end = 3.0

    init(outerRadius: CGFloat, innerRadius: CGFloat, outerFraction: CGFloat, innerFraction: CGFloat,
         outerColor: Color, innerColor: Color) {
        self.outerRadius = outerRadius
        self.innerRadius = innerRadius
        self.outerFraction = outerFraction
        self.innerFraction = innerFraction
        self.outerColor = outerColor
        self.innerColor = innerColor
        var made: [Spark] = []
        for i in 0..<120 {
            // First 70 trail the moving tip; the rest burst together the moment the sweep lands.
            let born = i < 70 ? Double.random(in: 0.1...Self.sweep) : Self.sweep
            made.append(Spark(ring: i % 2, born: born,
                              angleJitter: Double.random(in: -0.08...0.08),
                              speed: Double.random(in: 14...40),
                              drift: Double.random(in: -0.6...0.6),
                              size: Double.random(in: 1.0...2.2)))
        }
        sparks = made
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            Canvas { context, size in
                guard t < Self.end else { return }
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                for spark in sparks where t >= spark.born && t - spark.born < Self.life {
                    let age = (t - spark.born) / Self.life
                    let radius = Double(spark.ring == 0 ? outerRadius : innerRadius)
                    let fraction = Double(spark.ring == 0 ? outerFraction : innerFraction)
                    let progress = min(1, spark.born / Self.sweep)
                    let eased = 1 - pow(1 - progress, 3)
                    let angle = -Double.pi / 2 + 2 * Double.pi * fraction * eased + spark.angleJitter
                    let r = radius + spark.speed * age
                    let a = angle + spark.drift * age
                    let p = CGPoint(x: centre.x + cos(a) * r, y: centre.y + sin(a) * r)
                    let color = (spark.ring == 0 ? outerColor : innerColor).opacity(1 - age)
                    let rect = CGRect(x: p.x - spark.size / 2, y: p.y - spark.size / 2,
                                      width: spark.size, height: spark.size)
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Blocks

struct MorningBlock<Content: View>: View {
    let title: String
    let accent: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(StrandFont.overlineScaled(8))
                .tracking(1.2)
                .foregroundStyle(accent)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ContributorBar: View {
    let label: String
    let value: Double?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
            if let value {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.10))
                        Capsule().fill(color).frame(width: geo.size.width * value)
                    }
                }
                .frame(height: 3)
            }
        }
    }
}
```

- [ ] **Step 2: Write `MorningNotificationController.swift`**

```swift
import SwiftUI
import UserNotifications
import WatchKit

// MARK: - MorningNotificationController — the MORNING category's custom long look
//
// watchOS shows this SwiftUI view full screen when the wrist stays raised after the short look (or when
// the notification is opened from Notification Center). It reads the shared store, nudges it to re-read
// the app group (a background wake may have written a newer snapshot) and asks the phone for the latest
// mirror when reachable; the view observes the store, so a reply that lands a second later updates the
// rings in place. The system's own Dismiss button suffices — no custom actions.
final class MorningNotificationController: WKUserNotificationHostingController<MorningMomentView> {

    override var body: MorningMomentView {
        MorningMomentView(store: WatchScoreStore.shared, celebrate: true)
    }

    override func didReceive(_ notification: UNNotification) {
        WatchScoreStore.shared.reloadFromAppGroup()
        WatchScoreStore.shared.requestLatest()
    }
}
```

- [ ] **Step 3: Register the notification scene**

In `NOOPWatchApp.swift`, change `var body: some Scene` to:

```swift
    var body: some Scene {
        WindowGroup {
            rootView
                .environmentObject(store)
                .environmentObject(liveHR)
                .preferredColorScheme(.dark)
        }
        // The morning long look: any local notification with category MORNING renders
        // MorningMomentView instead of the plain title/body.
        WKNotificationScene(controller: MorningNotificationController.self,
                            category: MorningScheduler.category)
    }
```

(Keep the existing comment above `.preferredColorScheme`.)

- [ ] **Step 4: Regenerate + compile**

Run:
```bash
cd /Users/airflo/Documents/Trading/noop && xcodegen generate 2>&1 | tail -1 && env DEVELOPER_DIR=/Applications/Xcode-beta.app xcodebuild -project Strand.xcodeproj -scheme NOOPWatch -configuration Release -destination 'generic/platform=watchOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD" | tail -5
```
Expected: `** BUILD SUCCEEDED **`. If `StrandPalette.recoveryColor` or `restLine` is unavailable on watchOS, check `Palette.swift` `#if os(watchOS)` guards and use `StrandPalette.chargeColor` / `StrandPalette.restColor` instead — note the substitution in the commit message.

- [ ] **Step 5: Commit**

```bash
cd /Users/airflo/Documents/Trading/noop
git add NOOPWatch/MorningMomentView.swift NOOPWatch/MorningNotificationController.swift NOOPWatch/NOOPWatchApp.swift
git commit -m "feat(watch): morning long look — rings, sparks, blocks, notification scene"
```

---

### Task 8: Watch — settings page (deck page 5)

**Files:**
- Create: `NOOPWatch/WatchMorningSettingsView.swift`
- Modify: `NOOPWatch/WatchRootView.swift`

- [ ] **Step 1: Write the settings page**

```swift
import SwiftUI
import StrandDesign

// MARK: - WatchMorningSettingsView — deck page 5: when the morning moment fires, and how it is doing
struct WatchMorningSettingsView: View {
    @EnvironmentObject private var store: WatchScoreStore
    @State private var enabled = MorningSettings.enabled
    @State private var time = MorningSettings.timeAsDate()
    @State private var preview = false
    @State private var testArmed = false
    @State private var requesting = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Toggle(isOn: $enabled) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Ochtendmoment")
                        Text("Notificatie op de Watch")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .onChange(of: enabled) { _, value in
                    MorningSettings.enabled = value
                    rearm()
                }

                DatePicker("Tijd", selection: $time, displayedComponents: .hourAndMinute)
                    .onChange(of: time) { _, value in
                        MorningSettings.set(time: value)
                        rearm()
                    }

                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Rapport")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                        Text(store.snapshot?.briefingStatus ?? "–")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                    }
                    Spacer()
                    Button(requesting ? "…" : "Nu") {
                        requesting = true
                        store.requestMorning(force: true) { _ in
                            DispatchQueue.main.async { requesting = false }
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(StrandPalette.chargeColor)
                    .disabled(requesting)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))

                Button(testArmed ? "Komt over 10 s…" : "Test nu (10 s)") {
                    Task {
                        await MorningScheduler.scheduleTest()
                        testArmed = true
                        try? await Task.sleep(nanoseconds: 12_000_000_000)
                        testArmed = false
                    }
                }
                .disabled(testArmed)

                Button("Bekijk vandaag") { preview = true }
                    .tint(StrandPalette.chargeColor)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $preview) {
            MorningMomentView(store: store, celebrate: true)
        }
    }

    private func rearm() {
        Task { await MorningScheduler.rearm() }
    }
}
```

- [ ] **Step 2: Add the page to the deck**

In `WatchRootView.swift`, add `WatchMorningSettingsView()` after `WatchIntervalView()` inside the `TabView`, and extend the header comment's first sentence: `…then the three on-watch active features, then the morning-moment settings.`

- [ ] **Step 3: Regenerate + compile**

Run:
```bash
cd /Users/airflo/Documents/Trading/noop && xcodegen generate 2>&1 | tail -1 && env DEVELOPER_DIR=/Applications/Xcode-beta.app xcodebuild -project Strand.xcodeproj -scheme NOOPWatch -configuration Release -destination 'generic/platform=watchOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD" | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit (include the auto-extracted string catalog if the build touched it)**

```bash
cd /Users/airflo/Documents/Trading/noop
git status --short NOOPWatch/Localizable.xcstrings
git add NOOPWatch/WatchMorningSettingsView.swift NOOPWatch/WatchRootView.swift NOOPWatch/Localizable.xcstrings
git commit -m "feat(watch): morning-moment settings page (time, status, test, preview)"
```

---

### Task 9: Full gate + device install + verification

**Files:** none new.

- [ ] **Step 1: Package tests**

Run: `cd /Users/airflo/Documents/Trading/noop && for p in Packages/*/; do (cd "$p" && swift test 2>&1 | tail -1 | sed "s|^|$p: |"); done`
Expected: every line ends `with 0 failures`.

- [ ] **Step 2: iOS + watch Release compile**

Run both xcodebuild commands from the header. Expected: `** BUILD SUCCEEDED **` twice.

- [ ] **Step 3: Install on the phone (watch app rides along)**

Run: `cd /Users/airflo/Documents/Trading/noop && Tools/install-device.sh 2>&1 | tail -5`
Expected: install success on the iPhone. If `CoreDeviceError 4016`, the phone is locked — retry until it is unlocked (see memory: took ~40 min last time).

- [ ] **Step 4: On-device checks (report each outcome verbatim to the user)**

1. Open The Machine on the Watch → swipe to page 5. Expect toggle ON, time 07:00, status row shows "–" or the last status.
2. Tap "Nu". Expect the status row to change within ~15 s to `OK HH:mm`, or to a reason (`geen API-key`, `geen gescoorde nacht`, `API-fout: …`). Report the reason; `geen API-key` means Settings → AI Coach on the iPhone still needs the Anthropic key.
3. Tap "Test nu (10 s)", lower the wrist, raise it when the tap comes. Expect: short look → automatic full-screen long look with the rings sweeping in, sparks, number counting up, verdict word; Crown scrolls to the three blocks.
4. "Bekijk vandaag" shows the same view in-app.
5. Next morning at the set time: real run. If the notification shows "Nog niet gesynct", check page 5's status row and the iPhone's WatchConnectivity reachability (phone nearby, Bluetooth on).

- [ ] **Step 5: Update memory + planbord**

Update `project_noop_whoop_watch.md` (canonical memory store) with a dated "Ochtendmoment" paragraph: what was built, the watch-as-trigger decision, the removed iPhone push, the status row, verification results. Run `bash ~/.claude/scripts/memory-index.sh`. Add a planbord item under project `noop`.

---

## Self-review

- **Spec coverage**: eight fields (Task 1), `MorningMoment`/`BriefingStatus`/`MorningSchedule` (Task 2), phone fill + baselines + force/wake + `requestMorning` (Task 3), status recording + push removal + app wiring in `init` (Task 4), store singleton + userInfo + messaging (Task 5), settings + scheduler + refresh + delegate (Task 6), notification scene + view (Task 7), page 5 (Task 8), gate + device (Task 9). The spec's "7 fields" became 8 (`restingHrBaseline` was needed for the RHR bar) — spec updated to match.
- **Placeholders**: none; every code step is complete.
- **Type consistency**: `requestMorning(force:completion:)` (Task 5) is what `MorningRefresh` (Task 6) and the settings page (Task 8) call; `WatchScoreStore.shared` everywhere; `MorningScheduler.category` used by the scene (Task 7); `MorningBriefing.lastStatusKey` defined in Task 4 and read in Task 3; `pushLatest(from:force:wakeWatch:)` matches its call sites; `MorningMoment.verdictLine(for:)` and `.bars` match the tests.

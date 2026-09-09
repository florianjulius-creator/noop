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
// Pure date math for the Watch scheduler: the next hour:minute strictly after `now`, today's T, and the
// background-refresh slots around it. Five stages per morning: T − 25 and T − 5 wake the phone for the
// strap offload + re-score before T; T + 10, T + 25 and T + 45 keep pulling AFTER T, because the night
// is only scorable once the user is up (the strap offloads the finished sleep, the phone scores it) and
// the moment fires when that score lands. Past the last stage the next slot is tomorrow's first, so a
// refresh handler that re-arms can never loop.
public enum MorningSchedule {
    /// Seconds AHEAD of the fire time, in order; negative = after it.
    public static let refreshStages: [TimeInterval] = [25 * 60, 5 * 60, -10 * 60, -25 * 60, -45 * 60]

    /// Today's hour:minute, whether or not it has passed.
    public static func fireToday(now: Date, hour: Int, minute: Int, calendar: Calendar = .current) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        return calendar.date(from: comps) ?? now
    }

    public static func nextFire(after now: Date, hour: Int, minute: Int, calendar: Calendar = .current) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        let today = calendar.date(from: comps) ?? now
        if today > now { return today }
        return calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }

    /// The next refresh slot strictly ahead of `now` (at least 30 s out): the first of `refreshStages`
    /// around `fire` (today's T) that is still ahead, else the first stage before the following day's fire.
    public static func refreshDate(for fire: Date, now: Date, calendar: Calendar = .current) -> Date {
        for stage in refreshStages {
            let slot = fire.addingTimeInterval(-stage)
            if slot > now.addingTimeInterval(30) { return slot }
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: fire) ?? fire.addingTimeInterval(86_400)
        return tomorrow.addingTimeInterval(-refreshStages[0])
    }
}

// MARK: - MorningAlert — the notification contract both devices share
//
// The morning notification is sent by whichever device knows the score first (the iPhone computes it,
// so normally the iPhone; the Watch keeps its own path as a second route). Both use THIS identifier
// and category, so watchOS deduplicates them instead of alerting twice, and both carry the snapshot in
// `userInfo` — the long look then renders today's numbers even when the watch app's own store has not
// caught up yet, which is exactly the "nog niet gesynct" screen this removes.
public enum MorningAlert {
    /// Same on both devices: watchOS dedupes a mirrored iPhone notification against the watch's own.
    public static let identifier = "morning-moment"
    public static let category = "MORNING"
    /// userInfo key carrying the JSON-encoded `WatchScoreSnapshot`.
    public static let snapshotKey = "snapshot"

    /// The one-line body, so the numbers are readable even in the short look / on the phone.
    /// "Recovery 72 · Slaap 83 · HRV 31 ms"
    public static func body(for snap: WatchScoreSnapshot) -> String {
        var parts: [String] = []
        if let charge = snap.charge { parts.append("Recovery \(Int(charge.rounded()))") }
        if let rest = snap.rest { parts.append("Slaap \(Int(rest.rounded()))") }
        if let hrv = snap.hrvMs { parts.append("HRV \(hrv) ms") }
        return parts.isEmpty ? "Je ochtendoverzicht staat klaar" : parts.joined(separator: " · ")
    }

    /// Encode a snapshot for `UNMutableNotificationContent.userInfo` (property-list safe).
    public static func userInfo(for snap: WatchScoreSnapshot) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(snap) else { return [:] }
        return [snapshotKey: data]
    }

    /// Decode the snapshot a notification carries, if any.
    public static func snapshot(from userInfo: [AnyHashable: Any]) -> WatchScoreSnapshot? {
        guard let data = userInfo[snapshotKey] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchScoreSnapshot.self, from: data)
    }

    /// Whether `snap` carries a usable recovery score for the local day of `now`.
    public static func isScored(_ snap: WatchScoreSnapshot?, now: Date = Date()) -> Bool {
        guard let snap, let day = snap.scoreDay, day == WatchScoreSnapshot.localDayKey(now) else { return false }
        return snap.charge != nil
    }
}

// MARK: - MorningPlan
//
// The moment is DATA-driven: it fires when today's recovery has landed on the Watch, never before the
// user's chosen time T, and never with empty content (07-09-2026: a fixed 07:00 alert read "nog niet
// gesynct" because the night had not been scored yet — useless on the wrist). When nothing has landed by
// T, the Watch waits; a fallback notice at T + 90 min says so honestly if it is still waiting then.
public enum MorningPlan {
    /// Message keys the Watch uses to tell the phone when its morning is (the phone owns the alert).
    public static let hourKey = "morningHour"
    public static let minuteKey = "morningMinute"
    public static let enabledKey = "morningEnabled"

    public enum Decision: Equatable, Sendable {
        /// Today's score is here and T has passed: alert now.
        case fireNow
        /// Today's score is here before T: alert at T.
        case scheduleAt(Date)
        /// No score yet: keep nothing at T, arm the fallback notice for `fallbackAt`.
        case waitForScore(fallbackAt: Date)
        /// Today's moment already fired or was seen: nothing more today.
        case done
    }

    public static let fallbackDelay: TimeInterval = 90 * 60

    public static func decide(scored: Bool, now: Date, fire: Date,
                              shownToday: Bool, firedToday: Bool) -> Decision {
        if shownToday || firedToday { return .done }
        if scored { return now >= fire ? .fireNow : .scheduleAt(fire) }
        return .waitForScore(fallbackAt: fire.addingTimeInterval(fallbackDelay))
    }
}

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

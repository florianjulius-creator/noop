import WidgetKit
import SwiftUI
import StrandDesign

// MARK: - Machine Sleep complication
//
// Fourth face complication: Rest (sleep performance) on the wrist, completing the WHOOP-style
// quartet (Sleep / Recovery / Strain / HRV). Same architecture as the others — render-only over the
// shared app-group snapshot, honesty rules intact (calibrating or stale = dash, never a number).
//
// Families: accessoryCircular (gauge ring + %), accessoryCorner (bed glyph + number, curved gauge),
// accessoryInline (Sleep + the phone-formatted sleep summary), accessoryRectangular (Sleep % with
// the summary line under the recency header).

// MARK: - Timeline

struct SleepEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchScoreSnapshot?
}

struct SleepProvider: TimelineProvider {
    func placeholder(in context: Context) -> SleepEntry {
        SleepEntry(date: Date(), snapshot: .sleepPreview)
    }

    func getSnapshot(in context: Context, completion: @escaping (SleepEntry) -> Void) {
        let snap = context.isPreview ? WatchScoreSnapshot.sleepPreview : WatchSnapshotAccess.load()
        completion(SleepEntry(date: Date(), snapshot: snap))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SleepEntry>) -> Void) {
        let snap = WatchSnapshotAccess.load()
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date())
            ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [SleepEntry(date: Date(), snapshot: snap)], policy: .after(next)))
    }
}

// MARK: - Preview snapshot

private extension WatchScoreSnapshot {
    static var sleepPreview: WatchScoreSnapshot {
        WatchScoreSnapshot(
            charge: 74, chargeCalibrating: false,
            effort: 41, effortCalibrating: false,
            rest: 81, restCalibrating: false,
            hr: 58,
            sleepSummary: "7h 12m · 88%",
            asOf: Date(),
            hrvMs: 64
        )
    }
}

// MARK: - The complication view

struct NOOPSleepView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SleepEntry

    private var isStale: Bool {
        guard let snap = entry.snapshot else { return false }
        return snap.isStale(now: entry.date)
    }

    /// Rest (0–100), or nil for the dash. Calibrating and stale both collapse to nil.
    private var rest: Int? {
        if isStale { return nil }
        guard let snap = entry.snapshot, !snap.restCalibrating else { return nil }
        return snap.rest.map { Int($0.rounded()) }
    }

    private var restFraction: Double? {
        rest.map { min(max(Double($0) / 100, 0), 1) }
    }

    /// The phone-formatted sleep line ("7h 12m · 88%"); empty means hide.
    private var summary: String {
        guard !isStale, let snap = entry.snapshot else { return "" }
        return snap.sleepSummary
    }

    private var noSnapshot: Bool { entry.snapshot == nil }

    private var freshness: String? {
        guard let snap = entry.snapshot else { return nil }
        return snap.freshnessText(now: entry.date)
    }

    private var isFreshToday: Bool {
        entry.snapshot?.isFreshToday(now: entry.date) ?? false
    }

    var body: some View {
        switch family {
        case .accessoryCircular:    circular
        case .accessoryCorner:      corner
        case .accessoryInline:      Text(inlineText)
        case .accessoryRectangular: rectangular
        default:                    circular
        }
    }

    /// The Sleep colour world: the slate blue the iOS overview widget's sleep ring uses.
    private static let sleepBlue = Color(red: 0.49, green: 0.64, blue: 0.79)
    private static let sleepGradient = Gradient(colors: [Color(red: 0.62, green: 0.74, blue: 0.86),
                                                         Color(red: 0.49, green: 0.64, blue: 0.79)])

    // MARK: accessoryCircular — sleep gauge ring with the % centred

    private var circular: some View {
        Gauge(value: restFraction ?? 0, in: 0...1) {
            EmptyView()
        } currentValueLabel: {
            VStack(spacing: 0) {
                Text(rest.map(String.init) ?? "–")
                    .font(StrandFont.rounded(15, weight: .semibold))
                    .foregroundStyle(rest == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    .minimumScaleFactor(0.5)
                Text("%")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .gaugeStyle(.accessoryCircular)
        .tint(rest == nil ? Gradient(colors: [StrandPalette.textTertiary]) : Self.sleepGradient)
        .widgetLabel(circularLabel)
        .widgetAccentable()
        .accessibilityLabel(accessibilitySleep)
    }

    private var circularLabel: String {
        guard let fresh = freshness else { return String(localized: "Sleep") }
        if isStale { return String(localized: "Sleep · \(fresh)") }
        if isFreshToday { return String(localized: "Sleep") }
        return String(localized: "Sleep · \(fresh)")
    }

    // MARK: accessoryCorner — bed glyph + number, gauge along the bezel

    private var corner: some View {
        // Large-content mode: with NO widgetLabel attached the corner renders its content at full
        // size — the only way a third-party complication matches the big digits of Apple's own
        // battery corner. With a gauge or label, watchOS locks the inner content to a small fixed
        // circle and ignores requested fonts (see Apple forums 718053/707827). Default SF matches
        // the system corners' typeface; the metric identifies itself through its colour.
        Text(rest.map(String.init) ?? "–")
            .font(.system(.title).weight(.semibold))
            .foregroundStyle(rest == nil ? StrandPalette.textTertiary : Self.sleepBlue)
            .widgetAccentable()
            .accessibilityLabel(accessibilitySleep)
    }

    // MARK: accessoryInline — one line: Sleep % + the summary

    private var inlineText: String {
        if noSnapshot { return String(localized: "Machine · open on iPhone") }
        if isStale {
            let fresh = freshness ?? String(localized: "old")
            return String(localized: "Sleep stale · \(fresh)")
        }
        let suffix = inlineFreshnessSuffix
        switch (rest, summary.isEmpty) {
        case let (.some(r), false):
            return String(localized: "Sleep \(r)% · \(summary)\(suffix)")
        case let (.some(r), true):
            return String(localized: "Sleep \(r)%\(suffix)")
        case (nil, false):
            return String(localized: "Sleep – · \(summary)\(suffix)")
        default:
            return String(localized: "Sleep –")
        }
    }

    private var inlineFreshnessSuffix: String {
        guard let fresh = freshness, !isFreshToday else { return "" }
        return " · \(fresh)"
    }

    // MARK: accessoryRectangular — Sleep % + summary line under the recency header

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("MACHINE")
                    .font(StrandFont.rounded(11, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 0)
                Text(headerTrailing)
                    .font(.system(size: 10))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(rest.map { "\($0)%" } ?? "–")
                    .font(StrandFont.rounded(18, weight: .semibold))
                    .foregroundStyle(rest == nil ? StrandPalette.textTertiary : Self.sleepBlue)
                Text(String(localized: "Sleep"))
                    .font(.system(size: 9))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            if !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .widgetAccentable()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityRectangular)
    }

    private var headerTrailing: String {
        guard let snap = entry.snapshot else { return String(localized: "open iPhone") }
        return snap.freshnessText(now: entry.date)
    }

    // MARK: Accessibility

    private var accessibilitySleep: String {
        if isStale {
            let fresh = freshness ?? String(localized: "a while ago")
            return String(localized: "Sleep out of date, last synced \(fresh). Open The Machine on iPhone.")
        }
        if let rest { return String(localized: "Sleep \(rest) percent") }
        return noSnapshot ? String(localized: "No data, open The Machine on iPhone")
                          : String(localized: "Sleep unavailable")
    }

    private var accessibilityRectangular: String {
        if noSnapshot { return String(localized: "The Machine. No data yet, open The Machine on your iPhone to sync.") }
        if isStale {
            let fresh = freshness ?? String(localized: "a while ago")
            return String(localized: "The Machine. Values out of date, last synced \(fresh). Open The Machine on iPhone to refresh.")
        }
        let sleepPhrase = rest.map { String(localized: "Sleep \($0) percent") }
            ?? String(localized: "Sleep unavailable")
        if summary.isEmpty { return String(localized: "The Machine. \(sleepPhrase).") }
        return String(localized: "The Machine. \(sleepPhrase), \(summary).")
    }
}

// MARK: - Widget declaration

struct NOOPSleepComplication: Widget {
    let kind = "NOOPSleepComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SleepProvider()) { entry in
            NOOPSleepView(entry: entry)
                .containerBackground(StrandPalette.surfaceBase, for: .widget)
        }
        .configurationDisplayName("Machine Sleep")
        .description("Your Sleep score on the watch face, with last night's duration and efficiency in the larger families.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryInline,
            .accessoryRectangular
        ])
    }
}

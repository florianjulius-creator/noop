import WidgetKit
import SwiftUI
import StrandDesign

// MARK: - Machine Strain complication
//
// Third face complication alongside Recovery and HRV: Effort (strain) on the wrist. Same
// architecture — the iPhone computes, this extension only renders the shared app-group snapshot.
//
// Display axis: the familiar WHOOP-style 0–21 number (stored effort is 0–100, so ×0.21 for the
// display value only — mirroring the iOS overview widget), while gauge fills stay effort/100.
// The honesty rule holds: a calibrating or stale Effort renders a dash, never a number.
//
// Families: accessoryCircular (gauge ring + 0–21 number), accessoryCorner (number + curved gauge),
// accessoryInline (Strain + Recovery), accessoryRectangular (Strain + Recovery side by side).

// MARK: - Timeline

struct StrainEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchScoreSnapshot?
}

struct StrainProvider: TimelineProvider {
    func placeholder(in context: Context) -> StrainEntry {
        StrainEntry(date: Date(), snapshot: .strainPreview)
    }

    func getSnapshot(in context: Context, completion: @escaping (StrainEntry) -> Void) {
        let snap = context.isPreview ? WatchScoreSnapshot.strainPreview : WatchSnapshotAccess.load()
        completion(StrainEntry(date: Date(), snapshot: snap))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StrainEntry>) -> Void) {
        let snap = WatchSnapshotAccess.load()
        // Same backstop cadence as the other complications; the phone forces reloads on fresh pushes.
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date())
            ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [StrainEntry(date: Date(), snapshot: snap)], policy: .after(next)))
    }
}

// MARK: - Preview snapshot

private extension WatchScoreSnapshot {
    /// Gallery stand-in: a mid Strain with a healthy Recovery alongside.
    static var strainPreview: WatchScoreSnapshot {
        WatchScoreSnapshot(
            charge: 74, chargeCalibrating: false,
            effort: 62, effortCalibrating: false,
            rest: 81, restCalibrating: false,
            hr: 58,
            sleepSummary: "7h 12m",
            asOf: Date(),
            hrvMs: 64
        )
    }
}

// MARK: - The complication view

struct NOOPStrainView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StrainEntry

    /// One staleness decision, mirroring the other Machine complications.
    private var isStale: Bool {
        guard let snap = entry.snapshot else { return false }
        return snap.isStale(now: entry.date)
    }

    /// Effort on the stored 0–100 axis, or nil for the dash. Stale and calibrating both collapse to
    /// nil so an old or unearned number is never presented as current.
    private var effort: Double? {
        if isStale { return nil }
        guard let snap = entry.snapshot, !snap.effortCalibrating else { return nil }
        return snap.effort
    }

    /// The WHOOP-style display number (0–21, one decimal) — display only; fills use effort/100.
    private var strainText: String? {
        effort.map { String(format: "%.1f", $0 * 0.21) }
    }

    private var strainFraction: Double? {
        effort.map { min(max($0 / 100, 0), 1) }
    }

    /// Recovery as the companion read-out in the roomier families, same stale collapse.
    private var charge: Int? {
        if isStale { return nil }
        return entry.snapshot?.charge.map { Int($0.rounded()) }
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

    /// The Strain colour world: WHOOP's signal blue, matching the iOS overview widget's strain ring.
    private static let strainBlue = Color(red: 0.00, green: 0.58, blue: 0.91)
    private static let strainGradient = Gradient(colors: [Color(red: 0.35, green: 0.72, blue: 0.96),
                                                          Color(red: 0.00, green: 0.58, blue: 0.91)])

    private var chargeTint: Color {
        if let charge { return StrandPalette.recoveryColor(Double(charge)) }
        return StrandPalette.textTertiary
    }

    // MARK: accessoryCircular — strain gauge ring with the 0–21 number centred

    private var circular: some View {
        Gauge(value: strainFraction ?? 0, in: 0...1) {
            EmptyView()
        } currentValueLabel: {
            Text(strainText ?? "–")
                .font(StrandFont.rounded(14, weight: .semibold))
                .foregroundStyle(strainText == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                .minimumScaleFactor(0.6)
        }
        .gaugeStyle(.accessoryCircular)
        .tint(strainText == nil ? Gradient(colors: [StrandPalette.textTertiary]) : Self.strainGradient)
        .widgetLabel(circularLabel)
        .widgetAccentable()
        .accessibilityLabel(accessibilityStrain)
    }

    private var circularLabel: String {
        guard let fresh = freshness else { return String(localized: "Strain") }
        if isStale { return String(localized: "Strain · \(fresh)") }
        if isFreshToday { return String(localized: "Strain") }
        return String(localized: "Strain · \(fresh)")
    }

    // MARK: accessoryCorner — number hugging the corner, gauge along the bezel

    private var corner: some View {
        // The bolt glyph identifies this corner as Strain on faces that flatten colours to one tint
        // and show no gauge text.
        HStack(spacing: 2) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 10, weight: .semibold))
            Text(strainText ?? "–")
                .font(StrandFont.rounded(17, weight: .semibold))
        }
            .foregroundStyle(strainText == nil ? StrandPalette.textTertiary : Self.strainBlue)
            .widgetAccentable()
            // A present value earns the curved gauge; missing/stale keeps the honest text label.
            .widgetLabel {
                if let fraction = strainFraction {
                    Gauge(value: fraction, in: 0...1) { Text("Strain") }
                        .tint(Self.strainGradient)
                } else {
                    Text(cornerLabel)
                }
            }
            .accessibilityLabel(accessibilityStrain)
    }

    private var cornerLabel: String {
        if isStale {
            let fresh = freshness ?? String(localized: "stale")
            return String(localized: "Strain · \(fresh)")
        }
        return noSnapshot ? String(localized: "Open Machine") : String(localized: "Strain")
    }

    // MARK: accessoryInline — one line: Strain + Recovery

    private var inlineText: String {
        if noSnapshot { return String(localized: "Machine · open on iPhone") }
        if isStale {
            let fresh = freshness ?? String(localized: "old")
            return String(localized: "Strain stale · \(fresh)")
        }
        let suffix = inlineFreshnessSuffix
        switch (strainText, charge) {
        case let (.some(s), .some(c)):
            return String(localized: "Strain \(s) · Recovery \(c)\(suffix)")
        case let (.some(s), nil):
            return String(localized: "Strain \(s)\(suffix)")
        case let (nil, .some(c)):
            return String(localized: "Strain – · Recovery \(c)\(suffix)")
        default:
            return String(localized: "Strain –")
        }
    }

    private var inlineFreshnessSuffix: String {
        guard let fresh = freshness, !isFreshToday else { return "" }
        return " · \(fresh)"
    }

    // MARK: accessoryRectangular — Strain + Recovery side by side under the recency header

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
            HStack(alignment: .top, spacing: 0) {
                valueCell(String(localized: "Strain"), text: strainText, tint: Self.strainBlue)
                valueCell(String(localized: "Recovery"), text: charge.map { "\($0)" }, tint: chargeTint)
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

    private func valueCell(_ label: String, text: String?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(text ?? "–")
                .font(StrandFont.rounded(18, weight: .semibold))
                .foregroundStyle(text == nil ? StrandPalette.textTertiary : tint)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Accessibility

    private var accessibilityStrain: String {
        if isStale {
            let fresh = freshness ?? String(localized: "a while ago")
            return String(localized: "Strain out of date, last synced \(fresh). Open The Machine on iPhone.")
        }
        if let strainText { return String(localized: "Strain \(strainText) out of 21") }
        return noSnapshot ? String(localized: "No data, open The Machine on iPhone")
                          : String(localized: "Strain unavailable")
    }

    private var accessibilityRectangular: String {
        if noSnapshot { return String(localized: "The Machine. No data yet, open The Machine on your iPhone to sync.") }
        if isStale {
            let fresh = freshness ?? String(localized: "a while ago")
            return String(localized: "The Machine. Values out of date, last synced \(fresh). Open The Machine on iPhone to refresh.")
        }
        let strainPhrase = strainText.map { String(localized: "Strain \($0)") }
            ?? String(localized: "Strain unavailable")
        let chargePhrase = charge.map { String(localized: "Recovery \($0)") }
            ?? String(localized: "Recovery unavailable")
        return String(localized: "The Machine. \(strainPhrase), \(chargePhrase).")
    }
}

// MARK: - Widget declaration

struct NOOPStrainComplication: Widget {
    let kind = "NOOPStrainComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StrainProvider()) { entry in
            NOOPStrainView(entry: entry)
                .containerBackground(StrandPalette.surfaceBase, for: .widget)
        }
        .configurationDisplayName("Machine Strain")
        .description("Your Strain on the watch face (0–21 axis), with Recovery alongside in the larger families.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryInline,
            .accessoryRectangular
        ])
    }
}

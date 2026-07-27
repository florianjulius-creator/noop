import WidgetKit
import SwiftUI
import StrandDesign

// MARK: - NOOP HRV complication
//
// A second face complication alongside NOOP Charge: overnight HRV (RMSSD, ms) with Charge as its
// companion in the roomier families. Same architecture as NOOPChargeComplication — the iPhone is the
// brain, this extension only renders the latest `WatchScoreSnapshot` from the shared app group and
// never recomputes anything.
//
// The honesty rule carries through: HRV has no calibrating flag on the wire (a missing value simply
// means no overnight HRV for the anchor day), so a nil — or a stale snapshot — renders as a dash,
// never a number we did not earn. HRV also has no universal 0–100 scale, so the circular family draws
// the number plainly instead of pretending a ring fraction means something.
//
// Families: accessoryCircular (number + "ms"), accessoryCorner, accessoryInline (HRV + Charge), and
// accessoryRectangular (HRV + Charge side by side with the recency header).

// MARK: - Timeline
//
// Its own provider (same shape as ChargeProvider) so each widget kind owns its timeline; both read the
// identical app-group snapshot, so the two complications can never disagree about the data.

struct HRVEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchScoreSnapshot?
}

struct HRVProvider: TimelineProvider {
    func placeholder(in context: Context) -> HRVEntry {
        HRVEntry(date: Date(), snapshot: .hrvPreview)
    }

    func getSnapshot(in context: Context, completion: @escaping (HRVEntry) -> Void) {
        let snap = context.isPreview ? WatchScoreSnapshot.hrvPreview : WatchSnapshotAccess.load()
        completion(HRVEntry(date: Date(), snapshot: snap))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HRVEntry>) -> Void) {
        let snap = WatchSnapshotAccess.load()
        // Same backstop cadence as the Charge complication: the phone forces a reload on every fresh
        // push, the 30-minute timeline only keeps the recency label honest.
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date())
            ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [HRVEntry(date: Date(), snapshot: snap)], policy: .after(next)))
    }
}

// MARK: - Preview snapshot

private extension WatchScoreSnapshot {
    /// Gallery stand-in: a real-looking HRV + Charge pair. Never persisted; the live view falls back
    /// to the neutral placeholder when nothing has synced.
    static var hrvPreview: WatchScoreSnapshot {
        WatchScoreSnapshot(
            charge: 74, chargeCalibrating: false,
            effort: 41, effortCalibrating: false,
            rest: 81, restCalibrating: false,
            hr: 58,
            sleepSummary: "7h 12m",
            asOf: Date(),
            hrvMs: 64
        )
    }
}

// MARK: - The complication view

struct NOOPHRVView: View {
    @Environment(\.widgetFamily) private var family
    let entry: HRVEntry

    /// One staleness decision, mirroring NOOPChargeView: a days-old snapshot must never read as live
    /// in any family, so both numbers collapse to the dash when the snapshot has aged out.
    private var isStale: Bool {
        guard let snap = entry.snapshot else { return false }
        return snap.isStale(now: entry.date)
    }

    /// The HRV number to draw, or nil for the dash. Stale collapses to nil so an old value is never
    /// presented as current.
    private var hrv: Int? {
        if isStale { return nil }
        return entry.snapshot?.hrvMs
    }

    /// Charge as the companion read-out in the roomier families, same stale collapse.
    private var charge: Int? {
        if isStale { return nil }
        return entry.snapshot?.charge.map { Int($0.rounded()) }
    }

    private var noSnapshot: Bool { entry.snapshot == nil }

    /// The honest recency label, straight from the shared contract so this complication, the Charge
    /// complication and the glance all phrase age identically.
    private var freshness: String? {
        guard let snap = entry.snapshot else { return nil }
        return snap.freshnessText(now: entry.date)
    }

    /// Semantic "reads as current" flag (never a display-text comparison — that breaks under i18n).
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

    /// Charge keeps its earned colour world; HRV itself stays neutral (there is no universal
    /// good/bad HRV scale to borrow a colour from).
    private var chargeTint: Color {
        if let charge { return StrandPalette.recoveryColor(Double(charge)) }
        return StrandPalette.textTertiary
    }

    // MARK: accessoryCircular — HRV ring (0–120 ms axis) with the number + "ms" in the centre

    /// Ring fill on the same fixed 0–120 ms RMSSD axis the Breathe coherence bar uses, so the ring
    /// reads "how high is my HRV" at a glance without inventing a personal scale the complication
    /// doesn't have. Values above 120 pin the ring full.
    private var hrvFraction: Double? {
        hrv.map { min(Double($0) / 120.0, 1) }
    }

    /// The HRV accent world: the brand cyan→green. A gradient fill (low = cyan, high = green) gives
    /// the ring the same premium read as the iOS overview rings.
    private static let hrvGradient = Gradient(colors: [Color(red: 0.13, green: 0.83, blue: 0.93),
                                                       Color(red: 0.20, green: 0.83, blue: 0.60)])

    private var circular: some View {
        Gauge(value: hrvFraction ?? 0, in: 0...1) {
            EmptyView()
        } currentValueLabel: {
            VStack(spacing: 0) {
                Text(hrv.map(String.init) ?? "–")
                    .font(StrandFont.rounded(15, weight: .semibold))
                    .foregroundStyle(hrv == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    .minimumScaleFactor(0.5)
                Text("ms")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .gaugeStyle(.accessoryCircular)
        .tint(hrv == nil ? Gradient(colors: [StrandPalette.textTertiary]) : Self.hrvGradient)
        .widgetLabel(circularLabel)
        .widgetAccentable()
        .accessibilityLabel(accessibilityHRV)
    }

    private var circularLabel: String {
        guard let fresh = freshness else { return String(localized: "HRV") }
        if isStale { return String(localized: "HRV · \(fresh)") }
        if isFreshToday { return String(localized: "HRV") }
        return String(localized: "HRV · \(fresh)")
    }

    // MARK: accessoryCorner — number hugging the corner, an HRV gauge along the bezel

    private var corner: some View {
        // The ECG glyph identifies this corner as HRV on faces that flatten colours to one tint and
        // show no gauge text.
        HStack(spacing: 2) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 13, weight: .semibold))
            Text(hrv.map(String.init) ?? "–")
                .font(StrandFont.rounded(26, weight: .semibold))
                .minimumScaleFactor(0.5)
        }
            .foregroundStyle(hrv == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
            .widgetAccentable()
            // A present value earns the curved gauge (same 0–120 ms axis as the circular ring);
            // missing / stale keeps the honest text label instead of an empty-claim fill.
            .widgetLabel {
                if let fraction = hrvFraction {
                    Gauge(value: fraction, in: 0...1) { Text("HRV") }
                        .tint(Self.hrvGradient)
                } else {
                    Text(cornerLabel)
                }
            }
            .accessibilityLabel(accessibilityHRV)
    }

    private var cornerLabel: String {
        if hrv != nil {
            guard let fresh = freshness, !isFreshToday else { return String(localized: "HRV ms") }
            return String(localized: "HRV · \(fresh)")
        }
        if isStale {
            let fresh = freshness ?? String(localized: "stale")
            return String(localized: "HRV · \(fresh)")
        }
        return noSnapshot ? String(localized: "Open Machine") : String(localized: "HRV")
    }

    // MARK: accessoryInline — one line: HRV + Charge

    private var inlineText: String {
        if noSnapshot { return String(localized: "Machine · open on iPhone") }
        if isStale {
            let fresh = freshness ?? String(localized: "old")
            return String(localized: "HRV stale · \(fresh)")
        }
        let suffix = inlineFreshnessSuffix
        switch (hrv, charge) {
        case let (.some(h), .some(c)):
            return String(localized: "HRV \(h) ms · Charge \(c)\(suffix)")
        case let (.some(h), nil):
            return String(localized: "HRV \(h) ms\(suffix)")
        case let (nil, .some(c)):
            return String(localized: "HRV – · Charge \(c)\(suffix)")
        default:
            return String(localized: "HRV –")
        }
    }

    private var inlineFreshnessSuffix: String {
        guard let fresh = freshness, !isFreshToday else { return "" }
        return " · \(fresh)"
    }

    // MARK: accessoryRectangular — HRV + Charge side by side under the recency header

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
                valueCell(String(localized: "HRV"), text: hrv.map { "\($0)" }, unit: "ms",
                          tint: StrandPalette.textPrimary)
                valueCell(String(localized: "Charge"), text: charge.map { "\($0)" }, unit: nil,
                          tint: chargeTint)
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

    /// One labelled value in the rectangular card. nil text draws the neutral dash.
    private func valueCell(_ label: String, text: String?, unit: String?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(text ?? "–")
                    .font(StrandFont.rounded(18, weight: .semibold))
                    .foregroundStyle(text == nil ? StrandPalette.textTertiary : tint)
                    .minimumScaleFactor(0.7)
                if let unit, text != nil {
                    Text(unit)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Accessibility

    private var accessibilityHRV: String {
        if isStale {
            let fresh = freshness ?? String(localized: "a while ago")
            return String(localized: "HRV out of date, last synced \(fresh). Open The Machine on iPhone.")
        }
        if let hrv { return String(localized: "HRV \(hrv) milliseconds") }
        return noSnapshot ? String(localized: "No data, open The Machine on iPhone")
                          : String(localized: "HRV unavailable")
    }

    private var accessibilityRectangular: String {
        if noSnapshot { return String(localized: "The Machine. No data yet, open The Machine on your iPhone to sync.") }
        if isStale {
            let fresh = freshness ?? String(localized: "a while ago")
            return String(localized: "The Machine. Values out of date, last synced \(fresh). Open The Machine on iPhone to refresh.")
        }
        let hrvPhrase = hrv.map { String(localized: "HRV \($0) milliseconds") }
            ?? String(localized: "HRV unavailable")
        let chargePhrase = charge.map { String(localized: "Charge \($0)") }
            ?? String(localized: "Charge unavailable")
        return String(localized: "The Machine. \(hrvPhrase), \(chargePhrase).")
    }
}

// MARK: - Widget declaration

struct NOOPHRVComplication: Widget {
    let kind = "NOOPHRVComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HRVProvider()) { entry in
            NOOPHRVView(entry: entry)
                .containerBackground(StrandPalette.surfaceBase, for: .widget)
        }
        .configurationDisplayName("Machine HRV")
        .description("Overnight HRV (RMSSD) on the watch face, with Charge alongside in the larger families.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryInline,
            .accessoryRectangular
        ])
    }
}

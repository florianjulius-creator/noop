import WidgetKit
import SwiftUI
import StrandDesign

/// Timeline entry backed by the latest `WidgetSnapshot` the app published into the App Group.
struct NOOPEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct NOOPProvider: TimelineProvider {
    func placeholder(in context: Context) -> NOOPEntry {
        NOOPEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (NOOPEntry) -> Void) {
        completion(NOOPEntry(date: Date(), snapshot: WidgetSnapshot.load() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NOOPEntry>) -> Void) {
        let snap = WidgetSnapshot.load() ?? .placeholder
        // Refresh roughly every 15 minutes; the app also forces a reload when it publishes fresh data.
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [NOOPEntry(date: Date(), snapshot: snap)], policy: .after(next)))
    }
}

/// The glanceable widget — the iOS analogue of the macOS menu-bar extra. Recovery, live/last HR,
/// and strap battery.
struct NOOPWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NOOPEntry

    private var snap: WidgetSnapshot { entry.snapshot }

    var body: some View {
        switch family {
        case .accessoryCircular:
            recoveryGauge
        case .accessoryInline:
            Text(inlineText)
        case .accessoryRectangular:
            rectangular
        case .systemLarge:
            large
        case .systemMedium:
            overviewMedium
        default:
            home
        }
    }

    private var recoveryColor: Color {
        guard let r = snap.recovery else { return StrandPalette.textTertiary }
        return r >= 67 ? StrandPalette.statusPositive : r >= 34 ? StrandPalette.statusWarning : StrandPalette.statusCritical
    }

    /// Effort is on the 0–100 axis (`StrainScorer.maxStrain == 100`), so the fraction is just the value
    /// over 100 — the same input `effortTint` takes on the Today Effort tile.
    private var effortColor: Color {
        guard let e = snap.effort else { return StrandPalette.textTertiary }
        return StrandPalette.effortTint(fraction: Double(e) / 100)
    }

    private var restColor: Color {
        guard let r = snap.rest else { return StrandPalette.textTertiary }
        return StrandPalette.recoveryColor(Double(r))
    }

    private var inlineText: String {
        var parts: [String] = []
        if let r = snap.recovery { parts.append("Charge \(r)%") }
        if let b = snap.bpm { parts.append("\(b) bpm") }
        return parts.isEmpty ? "NOOP" : parts.joined(separator: " · ")
    }

    private var recoveryGauge: some View {
        Gauge(value: Double(snap.recovery ?? 0), in: 0...100) {
            Image(systemName: "heart.fill")
        } currentValueLabel: {
            Text(snap.recovery.map { "\($0)" } ?? "–")
        }
        .gaugeStyle(.accessoryCircular)
        .tint(recoveryColor)
    }

    /// Lock-Screen rectangular accessory. Two lines (#446): line 1 the Charge headline, line 2 the live
    /// HR alongside Effort so the at-a-glance pair the users asked for both fit the tinted accessory.
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "heart.fill").foregroundStyle(recoveryColor)
                Text("Charge \(snap.recovery.map(String.init) ?? "–")%").font(.headline)
            }
            Text("HR \(snap.bpm.map(String.init) ?? "–") · Effort \(snap.effort.map(String.init) ?? "–")")
                .font(.caption)
        }
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("NOOP").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Circle().fill(snap.bonded ? StrandPalette.statusPositive : StrandPalette.statusCritical)
                    .frame(width: 8, height: 8)
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(snap.recovery.map(String.init) ?? "–")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(recoveryColor)
                Text("%").font(.headline).foregroundStyle(StrandPalette.textTertiary)
            }
            Text("Charge").font(.caption).foregroundStyle(StrandPalette.textTertiary)
            Spacer(minLength: 0)
            HStack {
                Label("\(snap.bpm.map(String.init) ?? "–")", systemImage: "waveform.path.ecg")
                Spacer()
                Label("\(snap.batteryPct.map { "\($0)%" } ?? "–")", systemImage: "battery.50")
            }
            .font(.caption2).foregroundStyle(StrandPalette.textSecondary)
        }
        .padding(12)
    }

    // MARK: systemMedium — "Today's Overview" three-ring card (WHOOP-style)
    //
    // Sleep / Recovery / Strain as three rings over the dark card, with HRV and strap battery in the
    // header. Strain renders on WHOOP's familiar 0–21 axis (effort is stored 0–100, so ×0.21 for the
    // display number only; the ring fraction stays effort/100). Missing values draw a dash over an
    // empty track — never a fabricated number.

    private var overviewMedium: some View {
        VStack(spacing: 6) {
            HStack {
                HStack(spacing: 3) {
                    Text("HRV").font(.system(size: 11, weight: .semibold)).tracking(0.5)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Text(snap.hrv.map(String.init) ?? "–")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer()
                Text("MACHINE")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(3)
                    .foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                HStack(spacing: 3) {
                    Image(systemName: batterySymbol).font(.system(size: 11))
                    Text(snap.batteryPct.map { "\($0)%" } ?? "–")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 0) {
                overviewRing(label: "SLEEP",
                             text: snap.rest.map(String.init), sub: "%",
                             fraction: snap.rest.map { Double($0) / 100 },
                             color: Self.sleepBlue)
                overviewRing(label: "RECOVERY",
                             text: snap.recovery.map(String.init), sub: "%",
                             fraction: snap.recovery.map { Double($0) / 100 },
                             color: recoveryColor)
                overviewRing(label: "STRAIN",
                             text: snap.effort.map { String(format: "%.1f", Double($0) * 0.21) }, sub: nil,
                             fraction: snap.effort.map { Double($0) / 100 },
                             color: Self.strainBlue)
            }
        }
        .padding(.vertical, 4)
    }

    /// WHOOP's widget colour world: slate blue for sleep, signal blue for strain. Recovery reuses the
    /// zone tint (green / amber / red) so it agrees with every other Recovery surface in the app.
    private static let sleepBlue = Color(red: 0.49, green: 0.64, blue: 0.79)
    private static let strainBlue = Color(red: 0.00, green: 0.58, blue: 0.91)

    private var batterySymbol: String {
        guard let p = snap.batteryPct else { return "battery.50" }
        switch p {
        case 88...: return "battery.100"
        case 63...: return "battery.75"
        case 38...: return "battery.50"
        case 13...: return "battery.25"
        default:    return "battery.0"
        }
    }

    /// One ring in the overview: value (dash when missing) centred in a stroked ring, caps label below.
    private func overviewRing(label: String, text: String?, sub: String?,
                              fraction: Double?, color: Color) -> some View {
        VStack(spacing: 7) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 6)
                if let fraction {
                    Circle()
                        .trim(from: 0, to: min(max(fraction, 0), 1))
                        .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(text ?? "–")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(text == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                        .minimumScaleFactor(0.6)
                    if let sub, text != nil {
                        Text(sub)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(width: 62, height: 62)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// The rich `systemLarge` layout (#446): the Charge headline plus a stat grid of Effort, Rest, HRV,
    /// Resting HR, live HR and strap battery — the "show me more" the issue asked for.
    private var large: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("NOOP").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Circle().fill(snap.bonded ? StrandPalette.statusPositive : StrandPalette.statusCritical)
                    .frame(width: 8, height: 8)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(snap.recovery.map(String.init) ?? "–")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(recoveryColor)
                Text("%").font(.title3).foregroundStyle(StrandPalette.textTertiary)
                Text("Charge").font(.subheadline).foregroundStyle(StrandPalette.textTertiary)
                    .padding(.leading, 2)
            }
            Divider()
            // Two-by-three stat grid of the richer scores. Each cell is a value + label pairing, tinted to
            // match its Today tile where a token exists (Effort, Rest); raw vitals stay neutral.
            HStack(alignment: .top, spacing: 0) {
                statCell("Effort", value: snap.effort.map(String.init), tint: effortColor)
                statCell("Rest", value: snap.rest.map { "\($0)%" }, tint: restColor)
                statCell("HRV", value: snap.hrv.map { "\($0)" }, unit: "ms")
            }
            HStack(alignment: .top, spacing: 0) {
                statCell("Rest HR", value: snap.restingHr.map { "\($0)" }, unit: "bpm")
                statCell("HR", value: snap.bpm.map { "\($0)" }, unit: "bpm")
                statCell("Battery", value: snap.batteryPct.map { "\($0)%" })
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    /// One labelled stat in the large grid — value over a caption, equal-width so the three columns align.
    private func statCell(_ label: String, value: String?, unit: String? = nil,
                          tint: Color = StrandPalette.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value ?? "–")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(value == nil ? StrandPalette.textTertiary : tint)
                if let unit, value != nil {
                    Text(unit).font(.caption2).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Text(label).font(.caption2).foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NOOPWidget: Widget {
    let kind = "NOOPWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NOOPProvider()) { entry in
            if #available(iOS 17.0, *) {
                NOOPWidgetView(entry: entry)
                    .containerBackground(StrandPalette.surfaceBase, for: .widget)
            } else {
                NOOPWidgetView(entry: entry)
                    .padding()
                    .background(StrandPalette.surfaceBase)
            }
        }
        .configurationDisplayName("The Machine")
        .description("Sleep, Recovery and Strain rings with HRV, heart rate and strap battery at a glance.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryCircular, .accessoryInline, .accessoryRectangular
        ])
    }
}

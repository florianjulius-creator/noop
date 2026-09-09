import SwiftUI
import WatchKit
import StrandDesign

// MARK: - MorningMomentView — the full-screen morning long look
//
// Rendered by the MORNING notification's custom long look AND by the settings page's preview. Two
// concentric rings (Recovery outside in the recovery colour, Sleep inside in the app blue) sweep in with
// a spark trail and a burst on arrival; below, the Crown scrolls to the Recovery / Slaap / Ochtendrapport
// blocks. Every number comes from `MorningMoment`, so a not-scored morning is an empty track + a dash,
// never yesterday's figures. Quiet motion (system Reduce Motion, the in-app "Reduce motion in NOOP"
// switch, Low Power Mode — the composed `NoopMotionState.poseStill`): no sweep, no sparks, haptic kept.
struct MorningMomentView: View {
    @ObservedObject var store: WatchScoreStore
    var celebrate: Bool = true
    /// COMPACT is the notification long look: a fixed, small layout that always fits the one screen the
    /// system leaves between its sash and the dismiss button, pinned to the TOP. Anything taller was
    /// clipped at both ends (centred content in too little room, 09-09-2026), and a nested ScrollView
    /// opened halfway down the ring. Full detail lives in the app, which scrolls freely.
    var compact: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared

    private var moment: MorningMoment { MorningMoment(snapshot: store.snapshot) }

    var body: some View {
        Group {
            if compact {
                compactContent
            } else {
                ScrollView { content }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            if celebrate { WKInterfaceDevice.current().play(.notification) }
        }
    }

    /// The notification screen: rings + one line of numbers, top-aligned, nothing that can overflow.
    private var compactContent: some View {
        VStack(spacing: 4) {
            MorningRingsView(moment: moment,
                             animated: celebrate && !motion.poseStill(reduceMotion),
                             diameter: 88)
            switch moment.scores {
            case .fresh:
                legend
            case .notScored:
                Text("Nog geen score van vannacht")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 4)
    }

    private var content: some View {
        VStack(spacing: 10) {
            MorningRingsView(moment: moment, animated: celebrate && !motion.poseStill(reduceMotion))
            if case .fresh = moment.scores { legend }
            switch moment.scores {
            case .fresh: blocks
            case .notScored: notScored
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
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

    /// One line under the rings so the screen already says it all: "Slaap 84 · HRV 42 ms · Pols 49".
    private var legend: some View {
        var parts: [String] = []
        if case .fresh(_, let sleep) = moment.scores, let sleep { parts.append("Slaap \(Int(sleep.rounded()))") }
        if let hrv = moment.hrvMs { parts.append(hrvLabel(hrv)) }
        if let rhr = moment.restingHr { parts.append("Pols \(rhr)") }
        return Text(parts.joined(separator: " · "))
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textSecondary)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.7)
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
    /// Outer ring diameter. 88 pt in the notification (the system leaves ~140 pt between its sash and
    /// the dismiss button on an Ultra), 100 pt in the app where the page scrolls.
    var diameter: CGFloat = 100
    @State private var appeared = false

    private var outer: CGFloat { diameter }
    private var inner: CGFloat { diameter * 0.72 }
    private var width: CGFloat { diameter * 0.11 }

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
        .frame(width: outer + width, height: outer + width)
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
                    .font(StrandFont.rounded(diameter * 0.26, weight: .heavy))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(animated ? .easeOut(duration: 1.0) : nil, value: shownRecovery)
                Text("RECOVERY")
                    .font(StrandFont.overlineScaled(7))
                    .tracking(1.0)
                    .foregroundStyle(StrandPalette.textTertiary)
                if let verdict = moment.verdict {
                    Text(verdict)
                        .font(StrandFont.rounded(9, weight: .heavy))
                        .tracking(0.6)
                        .foregroundStyle(StrandPalette.recoveryColor(recovery))
                }
            } else {
                Text("–")
                    .font(StrandFont.rounded(diameter * 0.26, weight: .heavy))
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

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
    @State private var diagNow = "…"
    @State private var diagLog: [String] = []
    private let ticker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

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
                        // Ask the phone for a fresh score + briefing, then post the real alert HERE so
                        // the whole morning screen can be checked on demand.
                        store.requestMorning(force: true) { _ in
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                                await MorningScheduler.forceAlertNow()
                                requesting = false
                                refreshDiag()
                            }
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

                Button("Wijzerplaat verversen") {
                    store.forceComplicationReload()
                    refreshDiag()
                }

                // Diagnostics: what the notification daemon holds now, and what the app found at
                // its last launch (before it re-armed). The evidence line for "it did not fire".
                VStack(alignment: .leading, spacing: 2) {
                    Text("Planning")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Text("Strap: \(strapLine)")
                    Text("Wijzerplaat: \(complicationLine)")
                    Text("Nu: \(diagNow)")
                    Text("Bij start: \(UserDefaults.standard.string(forKey: MorningDiag.launchKey) ?? "–")")
                    ForEach(diagLog.suffix(4), id: \.self) { Text($0) }
                }
                .font(StrandFont.overlineScaled(9))
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
                .onAppear { refreshDiag() }
                .onReceive(ticker) { _ in refreshDiag() }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $preview) {
            MorningMomentView(store: store, celebrate: true)
        }
    }

    /// What the complication reads from the App Group, versus what this app holds. Different values mean
    /// the shared copy is stale; equal values with a stale face mean WidgetKit did not reload.
    private var complicationLine: String {
        let shared = WatchScoreStore.complicationSees()
        let sharedCharge = shared?.charge.map { String(Int($0.rounded())) } ?? "–"
        let appCharge = store.snapshot?.charge.map { String(Int($0.rounded())) } ?? "–"
        let at = UserDefaults.standard.object(forKey: "complication.lastReloadAt") as? Double
        let when = at.map { " · ververst " + Self.clock.string(from: Date(timeIntervalSince1970: $0)) } ?? ""
        // The extension's own stamp, written from inside getTimeline — proof of whether WidgetKit asked.
        let beat = UserDefaults(suiteName: WatchScoreSnapshot.appGroupId)?
            .string(forKey: "complication.lastTimeline") ?? "nooit gedraaid"
        return "gedeeld \(sharedCharge) · app \(appCharge)\(when)\n  extensie: \(beat)"
    }

    /// "verbonden · laatste sync 06:12" — the tell for whether the phone's background strap link lives.
    private var strapLine: String {
        guard let snap = store.snapshot else { return "–" }
        let link = snap.strapConnected.map { $0 ? "verbonden" : "niet verbonden" } ?? "?"
        let sync = snap.lastSyncAt.map { "laatste sync " + Self.clock.string(from: $0) } ?? "geen sync bekend"
        return "\(link) · \(sync)"
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "nl_NL")
        f.dateFormat = "dd-MM HH:mm"
        return f
    }()

    private func refreshDiag() {
        Task {
            diagNow = await MorningDiag.line()
            diagLog = MorningDiag.recent()
        }
    }

    private func rearm() {
        Task {
            await MorningScheduler.rearm()
            refreshDiag()
        }
    }
}

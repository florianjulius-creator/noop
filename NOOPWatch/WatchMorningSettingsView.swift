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

                // Diagnostics: what the notification daemon holds now, and what the app found at
                // its last launch (before it re-armed). The evidence line for "it did not fire".
                VStack(alignment: .leading, spacing: 2) {
                    Text("Planning")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Text("Nu: \(diagNow)")
                    Text("Bij start: \(UserDefaults.standard.string(forKey: MorningDiag.launchKey) ?? "–")")
                }
                .font(StrandFont.overlineScaled(9))
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
                .task { diagNow = await MorningDiag.line() }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $preview) {
            MorningMomentView(store: store, celebrate: true)
        }
    }

    private func rearm() {
        Task {
            await MorningScheduler.rearm()
            diagNow = await MorningDiag.line()
        }
    }
}

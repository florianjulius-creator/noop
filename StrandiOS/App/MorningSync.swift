#if os(iOS)
import Foundation

// MARK: - MorningSync — pull the night off the strap before the briefing
//
// The Watch wakes the phone at T − 25 min (`requestMorning`). The night is only scorable once the strap
// has offloaded it, and the periodic 15-minute offload needs BLE traffic to run at all while the app is
// backgrounded — so the morning request asks for one explicitly: the `.manual` tier bypasses the
// rate-limit floor but still honours the connected + bonded + not-already-syncing gate. Then it waits,
// bounded, for the offload to finish and settles any deferred re-score, so `generateIfDue` sees today's
// numbers instead of yesterday's. A no-op without a live link (nothing to pull; the honest status then
// reads "geen gescoorde nacht").
@MainActor
enum MorningSync {
    /// Upper bound on the wait for a running offload. A full night is ~1–2 min over BLE.
    static let timeout: TimeInterval = 150

    static func pullStrap(model: AppModel, timeout: TimeInterval = MorningSync.timeout) async {
        guard model.live.connected, model.live.bonded else { return }
        model.ble.requestSync(.manual)
        let start = Date()
        // Give the offload a moment to start, then wait for it to end (or the bound to pass).
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        while model.live.backfilling, Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        // Score what just landed, unconditionally. `runDeferredRescoreIfOwed` only resumes a pass an
        // earlier attempt started; a night whose data arrived in THIS offload was never "owed" and
        // stayed unscored until the next foreground — which is why the wrist kept waiting at 07:23
        // while the phone, once opened, showed the night at once (10-09-2026).
        await model.intelligence.analyzeRecent()
    }
}
#endif

#if os(iOS)
import Foundation
import StrandDesign

// MARK: - MorningSync — pull the night off the strap before the briefing
//
// The Watch wakes the phone (`requestMorning`). On 11-09-2026 that wake came at 07:25 and 07:45 and
// the night was still never scored: the app had been launched COLD in the background, CoreBluetooth
// had not yet restored the strap link in the first second, the old `guard live.connected` failed, and
// the pull returned without syncing — with the last offload still at 00:51. So this now WAITS for the
// link (state restoration + reconnect take seconds, not milliseconds), asks for an offload (`.manual`
// bypasses the rate-limit floor but still honours connected + bonded + not-already-syncing), waits for
// it to finish, and scores what landed. Every outcome is written to `syncStatus` so the Watch shows
// what happened instead of a bare "wacht op score".
@MainActor
enum MorningSync {
    /// How long to wait for the BLE link to come up after a cold background launch.
    static let linkTimeout: TimeInterval = 90
    /// Upper bound on the wait for a running offload. A full night is ~1–2 min over BLE.
    static let offloadTimeout: TimeInterval = 150
    static let statusKey = "morningSync.lastStatus"

    static var lastStatus: String? { UserDefaults.standard.string(forKey: statusKey) }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "nl_NL")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func record(_ text: String) {
        UserDefaults.standard.set(text, forKey: statusKey)
        DiagSink.phone("sync", text)
    }

    static func pullStrap(model: AppModel) async {
        let start = Date()
        record("wacht op strap \(clock.string(from: start))")
        // 1. Wait for the link. `willRestoreState` marks an already-connected strap within a second;
        //    a strap that dropped overnight reconnects when it is in range — both well inside 90 s.
        while !(model.live.connected && model.live.bonded),
              Date().timeIntervalSince(start) < linkTimeout {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard model.live.connected, model.live.bonded else {
            record("geen strap binnen \(Int(linkTimeout)) s")
            await model.intelligence.analyzeRecent()
            return
        }
        // 2. Ask for the offload and wait for it.
        let syncBefore = model.live.lastSyncedAt ?? 0
        model.ble.requestSync(.manual)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let offloadStart = Date()
        while model.live.backfilling, Date().timeIntervalSince(offloadStart) < offloadTimeout {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        let synced = (model.live.lastSyncedAt ?? 0) > syncBefore
        // 3. Score what landed, unconditionally (a night that arrived in this offload was never "owed"),
        //    under a background assertion so a backgrounded pass is not cut short.
        await RescoreBackgroundScheduler.run(isBackground: false,
                                             log: { [live = model.live] line in live.append(log: line) }) {
            await model.intelligence.analyzeRecent()
        }
        let day = Repository.widgetAnchor(days: model.repo.days, now: Date())
        let scored = day?.day == Repository.localDayKey(Date()) && day?.recovery != nil
        let offload = synced ? "offload \(clock.string(from: Date()))" : "geen nieuwe offload"
        record("\(offload) · \(scored ? "gescoord" : "nog geen score")")
        dumpStrapLog(live: model.live, label: "pull")
    }

    /// Whether `now` lies in the morning window [T − 45 min, T + 3 h] of the wrist's morning time.
    /// Inside it, background scoring runs immediately instead of deferring (see AppModel).
    static func inWindow(now: Date = Date()) -> Bool {
        guard MorningAlertSender.enabled else { return false }
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: now)
        comps.hour = MorningAlertSender.hour
        comps.minute = MorningAlertSender.minute
        guard let morning = Calendar.current.date(from: comps) else { return false }
        return now >= morning.addingTimeInterval(-45 * 60) && now <= morning.addingTimeInterval(3 * 3600)
    }

    // MARK: - Standalone: the phone kicks its own morning offload
    //
    // Every strap packet wakes this app in the background (`bluetooth-central`), so the packet path is
    // the one clock that keeps ticking overnight. From 45 min before the morning time, when the last
    // offload predates that window, force one (`.manual` bypasses the 15-min floor), at most once per
    // 20 min. The completed offload scores the night and pushes the wrist by itself
    // (`AppModel.refreshAfterCompletedBackfill` → `watchPush`). One clock comparison per packet; the
    // real check runs at most once a minute.
    static let kickKey = "morningSync.lastKickAt"
    nonisolated(unsafe) private static var nextCheckAt: TimeInterval = 0

    nonisolated static func kickIfDue(ble: BLEManager, live: LiveState, now: Date = Date()) {
        let t = now.timeIntervalSince1970
        guard t >= nextCheckAt else { return }
        nextCheckAt = t + 60
        Task { @MainActor in kick(ble: ble, live: live, now: now) }
    }

    private static func kick(ble: BLEManager, live: LiveState, now: Date) {
        guard inWindow(now: now), live.connected, live.bonded, !live.backfilling else { return }
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: now)
        comps.hour = MorningAlertSender.hour
        comps.minute = MorningAlertSender.minute
        guard let morning = Calendar.current.date(from: comps) else { return }
        let windowStart = morning.addingTimeInterval(-45 * 60)
        if let last = live.lastSyncedAt, last >= windowStart.timeIntervalSince1970 { return }
        let lastKick = UserDefaults.standard.double(forKey: kickKey)
        guard now.timeIntervalSince1970 - lastKick >= 20 * 60 else { return }
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: kickKey)
        record("auto-offload \(clock.string(from: now))")
        dumpStrapLog(live: live, label: "kick")
        ble.requestSync(.manual)
    }

    /// The strap log's tail into the diag folder — the only place "why no offload since 00:51" lives.
    /// Includes the previous process's rolled tail, so a cold background launch still shows the night.
    static func dumpStrapLog(live: LiveState, label: String) {
        let previous = LiveState.persistedLogGenerations().last ?? []
        DiagSink.file("ble-\(Repository.localDayKey(Date())).log",
                      header: label, lines: Array(previous.suffix(300)) + Array(live.log.suffix(400)))
    }
}
#endif

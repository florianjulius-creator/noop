import Foundation
import Combine
import WatchConnectivity
import WidgetKit
import StrandDesign

// MARK: - WatchScoreStore — the watch side of the phone->watch bridge
//
// Activates WCSession on the watch, receives the latest score snapshot the phone pushed via
// `updateApplicationContext` (latest-state semantics, no queue buildup), persists it into the shared
// App Group so the complication can read the same bytes, and reloads the complication timelines so the
// watch face matches the glance. The phone is the brain; this object never computes a score, it only
// carries the one the phone already earned.
//
// The published `snapshot` is what the glance binds to. It starts from whatever was last persisted to the
// App Group (so a relaunch shows the last-known scores immediately, with an honest "as of" age) and is
// nil only on a truly fresh install, which the glance renders as the "open NOOP on your iPhone" state.
//
// Since the morning moment the store is ONE shared instance: the app scene, the notification scene and
// the background refresh all read and write the same object, and the watch can now ASK the phone for
// data (requestLatest / requestMorning) instead of only waiting for a push.
final class WatchScoreStore: NSObject, ObservableObject, WCSessionDelegate {

    /// The one store every scene shares.
    static let shared = WatchScoreStore()

    /// The latest snapshot the watch knows about. nil = nothing has ever synced (fresh install).
    @Published private(set) var snapshot: WatchScoreSnapshot?

    /// The shared App Group suite the watch app + its complication both read/write. `Bundle.main` is
    /// process-global, so this is exactly the lookup `WatchScoreSnapshot.appGroupId` itself performs —
    /// deferring to it directly (rather than repeating the lookup here) keeps the resolution in ONE
    /// place so the writer and readers can't desync on it.
    static let suiteName: String = WatchScoreSnapshot.appGroupId

    /// The key the complication also reads. The single source of truth lives in the shared contract.
    static let storageKey = WatchScoreSnapshot.storageKey

    /// Message keys — must match `WatchSessionBridge` on the phone.
    static let contextKey = "snapshot"
    static let requestLatestKey = "requestLatest"
    static let requestMorningKey = "requestMorning"
    static let forceKey = "force"

    private typealias Pending = (message: [String: Any], completion: (WatchScoreSnapshot?) -> Void)
    /// Messages queued while WCSession is still activating (a background launch sends before the
    /// activation callback lands). Main-thread only.
    private var pending: [Pending] = []

    private override init() {
        super.init()
        // Show the last-known snapshot straight away (honest about its age via the glance's "as of").
        snapshot = Self.loadPersisted()
        activate()
    }

    /// Bring up the WCSession so the phone can reach us. Guarded because the simulator / an unpaired
    /// state can report the session unsupported, in which case we simply run on the last persisted snapshot.
    private func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: Persistence (shared with the complication)

    /// Read the last snapshot the phone delivered, if any. The complication uses the same key.
    static func loadPersisted() -> WatchScoreSnapshot? {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: storageKey),
              let snap = try? JSONDecoder().decode(WatchScoreSnapshot.self, from: data) else { return nil }
        return snap
    }

    /// Persist a snapshot into the shared group so the complication reads the SAME bytes the glance shows.
    /// They can never disagree because there is one source of truth.
    private func persist(_ snap: WatchScoreSnapshot) {
        guard let defaults = UserDefaults(suiteName: Self.suiteName),
              let data = try? JSONEncoder().encode(snap) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// Apply a snapshot unless it is OLDER than the one we hold (a late reply must never roll back a
    /// fresher context). Persists, publishes, reloads the complication. Hops to the main actor because
    /// it touches @Published state and WidgetCenter.
    private func apply(_ snap: WatchScoreSnapshot) {
        DispatchQueue.main.async {
            if let current = self.snapshot, snap.asOf < current.asOf { return }
            self.persist(snap)
            self.snapshot = snap
            // The phone just pushed new scores, so pull the complication timelines forward now rather
            // than waiting for WidgetKit's own cadence.
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Re-read the app group (a background wake may have persisted a newer snapshot from another
    /// launch of this process). Safe to call anytime.
    func reloadFromAppGroup() {
        if let persisted = Self.loadPersisted() { apply(persisted) }
    }

    /// Decode a WatchScoreSnapshot out of a WatchConnectivity payload. The phone encodes the Codable
    /// snapshot to Data under "snapshot"; we tolerate a missing/garbled payload by simply ignoring it.
    private func decode(from payload: [String: Any]) -> WatchScoreSnapshot? {
        guard let data = payload[Self.contextKey] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchScoreSnapshot.self, from: data)
    }

    // MARK: Asking the phone

    /// Ask for the phone's latest mirrored snapshot (cheap; the reply applies itself).
    func requestLatest() {
        send([Self.requestLatestKey: true]) { _ in }
    }

    /// Ask the phone to make this morning's briefing now (day-guarded there unless `force`) and push.
    /// `completion` always runs exactly once: with the reply snapshot, or nil when unreachable/failed.
    func requestMorning(force: Bool, completion: @escaping (WatchScoreSnapshot?) -> Void) {
        send([Self.requestMorningKey: true, Self.forceKey: force], completion: completion)
    }

    private func send(_ message: [String: Any], completion: @escaping (WatchScoreSnapshot?) -> Void) {
        guard WCSession.isSupported() else { completion(nil); return }
        let session = WCSession.default
        guard session.activationState == .activated else {
            pending.append((message, completion))
            return
        }
        guard session.isReachable else { completion(nil); return }
        session.sendMessage(message, replyHandler: { [weak self] reply in
            let snap = self?.decode(from: reply)
            if let snap { self?.apply(snap) }
            completion(snap)
        }, errorHandler: { _ in
            completion(nil)
        })
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        // On activation the system hands us the most recent application context the phone set, even if it
        // was set while we were not running. Pick it up so a relaunch immediately reflects the latest scores.
        if let snap = decode(from: session.receivedApplicationContext) {
            apply(snap)
        }
        DispatchQueue.main.async {
            let queued = self.pending
            self.pending = []
            for item in queued { self.send(item.message, completion: item.completion) }
        }
    }

    /// The phone calls `updateApplicationContext` whenever its dashboard refreshes. Latest-state only, so
    /// we always have the freshest scores without a backlog of stale messages.
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if let snap = decode(from: applicationContext) {
            apply(snap)
        }
    }

    /// The phone's once-a-day complication transfer (the morning wake) lands here.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let snap = decode(from: userInfo) {
            apply(snap)
        }
    }

    // Required by the protocol on watchOS even though they are phone-side concerns. No-ops here.
    #if os(watchOS)
    func sessionReachabilityDidChange(_ session: WCSession) {}
    #endif
}

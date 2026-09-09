import Foundation
import UserNotifications
import WatchKit
import StrandDesign

// MARK: - MorningSettings — the user's choices, on the watch
enum MorningSettings {
    static let enabledKey = "morning.enabled"
    static let hourKey = "morning.hour"
    static let minuteKey = "morning.minute"
    static let lastShownDayKey = "morning.lastShownDay"
    static let lastFiredDayKey = "morning.lastFiredDay"

    /// The local day the long look was last actually SHOWN with today's score (set by the notification
    /// controller). The Focus-ended re-fire skips a day whose moment the user already saw.
    static var lastShownDay: String? {
        get { UserDefaults.standard.string(forKey: lastShownDayKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastShownDayKey) }
    }
    /// The local day the moment was last fired or armed for its time (so a later score push never
    /// fires a second one).
    static var lastFiredDay: String? {
        get { UserDefaults.standard.string(forKey: lastFiredDayKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastFiredDayKey) }
    }

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
    static var hour: Int {
        get { UserDefaults.standard.object(forKey: hourKey) as? Int ?? 7 }
        set { UserDefaults.standard.set(newValue, forKey: hourKey) }
    }
    static var minute: Int {
        get { UserDefaults.standard.object(forKey: minuteKey) as? Int ?? 0 }
        set { UserDefaults.standard.set(newValue, forKey: minuteKey) }
    }

    /// Today at hour:minute, for the DatePicker.
    static func timeAsDate(now: Date = Date()) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = minute
        return Calendar.current.date(from: comps) ?? now
    }

    static func set(time: Date) {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        hour = comps.hour ?? 7
        minute = comps.minute ?? 0
    }
}

// MARK: - MorningScheduler — the notification + the background refreshes around it
//
// The Watch owns the morning clock, and the moment is DATA-driven (MorningPlan): it fires when today's
// recovery has landed here, not before the user's time T, never with empty content. `reconcile` is the
// one entry point — called on launch, on every settings change, and on every snapshot that arrives —
// and it (re)arms exactly what the plan says: a one-shot alert at T or right now, or nothing at T plus
// a fallback notice at T + 90 min. The background refreshes (T − 25 … T + 45) keep asking the phone
// for the night (MorningRefresh). "Test nu" arms a one-shot copy 10 s out.
enum MorningScheduler {
    static let category = MorningAlert.category
    /// Same identifier the phone uses, so watchOS dedupes the two instead of alerting twice.
    static let notificationId = MorningAlert.identifier
    static let testId = "morning-test"
    static let lateId = "morning-late"
    static let fallbackId = "morning-fallback"

    static func rearm() async {
        await reconcile(reason: "rearm")
    }

    /// Apply MorningPlan to the notification daemon for today. Idempotent.
    static func reconcile(reason: String, now: Date = Date()) async {
        scheduleRefresh(now: now)
        let center = UNUserNotificationCenter.current()
        guard MorningSettings.enabled else {
            center.removePendingNotificationRequests(withIdentifiers: [notificationId, fallbackId])
            return
        }
        await requestAuthorizationIfNeeded(center)
        let today = WatchScoreSnapshot.localDayKey(now)
        let fire = MorningSchedule.fireToday(now: now, hour: MorningSettings.hour, minute: MorningSettings.minute)
        let moment = MorningMoment(snapshot: WatchScoreStore.shared.snapshot, now: now)
        var scored = false
        if case .fresh(let recovery, _) = moment.scores, recovery != nil { scored = true }

        switch MorningPlan.decide(scored: scored, now: now, fire: fire,
                                  shownToday: MorningSettings.lastShownDay == today,
                                  firedToday: MorningSettings.lastFiredDay == today) {
        case .done:
            center.removePendingNotificationRequests(withIdentifiers: [fallbackId])
        case .fireNow:
            MorningSettings.lastFiredDay = today
            center.removePendingNotificationRequests(withIdentifiers: [notificationId, fallbackId])
            center.removeDeliveredNotifications(withIdentifiers: [fallbackId])
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: notificationId, content: content(), trigger: trigger))
            MorningDiag.log("\(reason): score binnen → melding nu")
        case .scheduleAt(let at):
            MorningSettings.lastFiredDay = today
            center.removePendingNotificationRequests(withIdentifiers: [fallbackId])
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: notificationId, content: content(), trigger: trigger))
            MorningDiag.log("\(reason): score binnen → melding \(MorningDiag.hhmm(at))")
        case .waitForScore(let fallbackAt):
            center.removePendingNotificationRequests(withIdentifiers: [notificationId])
            if fallbackAt > now {
                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fallbackAt)
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                try? await center.add(UNNotificationRequest(identifier: fallbackId, content: fallbackContent(), trigger: trigger))
            }
            MorningDiag.log("\(reason): wacht op score (vangnet \(MorningDiag.hhmm(fallbackAt)))")
        }
    }

    /// A Focus just ended: when today's moment already fired but landed silently (the Watch sat under
    /// the Sleep Focus) and has not been shown, fire a fresh one now so it alerts on the wrist. Only with
    /// today's score on board — without it a later score push fires the moment anyway (Focus is off by
    /// then). Window: from T until 6 h after.
    static func fireIfMissedToday(reason: String, now: Date = Date()) async {
        guard MorningSettings.enabled else { return }
        let today = WatchScoreSnapshot.localDayKey(now)
        let fireToday = MorningSchedule.fireToday(now: now, hour: MorningSettings.hour, minute: MorningSettings.minute)
        let sinceFire = now.timeIntervalSince(fireToday)
        guard sinceFire >= 0, sinceFire < 6 * 3600 else {
            MorningDiag.log("\(reason): buiten venster"); return
        }
        guard MorningSettings.lastShownDay != today else {
            MorningDiag.log("\(reason): al getoond"); return
        }
        let moment = MorningMoment(snapshot: WatchScoreStore.shared.snapshot, now: now)
        guard case .fresh(let recovery, _) = moment.scores, recovery != nil else {
            MorningDiag.log("\(reason): nog geen score, wacht"); return
        }
        MorningSettings.lastFiredDay = today
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationId, fallbackId])
        center.removeDeliveredNotifications(withIdentifiers: [notificationId, lateId, fallbackId])
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: lateId, content: content(), trigger: trigger))
        MorningDiag.log("\(reason): melding opnieuw")
    }

    /// The wrist's "Rapport nu" test: post the real morning alert right now with whatever the store
    /// holds, ignoring the once-a-day and before-T guards. Always posted BY THE WATCH, so it renders
    /// with our long look (a notification forwarded from the iPhone gets the plain system UI instead).
    static func forceAlertNow() async {
        let center = UNUserNotificationCenter.current()
        await requestAuthorizationIfNeeded(center)
        center.removePendingNotificationRequests(withIdentifiers: [notificationId, fallbackId])
        center.removeDeliveredNotifications(withIdentifiers: [notificationId, fallbackId, lateId])
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: notificationId, content: content(), trigger: trigger))
        MorningDiag.log("test: melding nu")
    }

    static func scheduleTest() async {
        let center = UNUserNotificationCenter.current()
        await requestAuthorizationIfNeeded(center)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 10, repeats: false)
        let request = UNNotificationRequest(identifier: testId, content: content(), trigger: trigger)
        try? await center.add(request)
    }

    static func scheduleRefresh(now: Date = Date()) {
        guard MorningSettings.enabled else { return }
        let fire = MorningSchedule.fireToday(now: now, hour: MorningSettings.hour, minute: MorningSettings.minute)
        let preferred = MorningSchedule.refreshDate(for: fire, now: now)
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: preferred, userInfo: nil) { _ in }
    }

    private static func content() -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = String(localized: "Goedemorgen")
        c.body = String(localized: "Je ochtendoverzicht staat klaar")
        c.categoryIdentifier = category
        c.sound = .default
        c.interruptionLevel = .timeSensitive
        c.relevanceScore = 1.0
        // Carry the numbers, exactly like the phone's alert does: the long look then shows what was
        // true when the alert was made, even if the store moves on before it is opened.
        if let snap = WatchScoreStore.shared.snapshot {
            c.body = MorningAlert.body(for: snap)
            c.userInfo = MorningAlert.userInfo(for: snap)
        }
        return c
    }

    /// The honest notice when nothing landed by T + 90 min (same long look, which then reads "nog niet").
    private static func fallbackContent() -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = String(localized: "Goedemorgen")
        c.body = String(localized: "Nog geen score van vannacht")
        c.categoryIdentifier = category
        c.sound = .default
        c.interruptionLevel = .timeSensitive
        return c
    }

    private static func requestAuthorizationIfNeeded(_ center: UNUserNotificationCenter) async {
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }
}

// MARK: - MorningDiag — what the notification daemon actually holds
//
// The 05-09-2026 morning did not fire and nothing on the wrist could say why. This records, at each
// launch path and on demand, whether a MORNING request is pending, when it fires next and whether the
// app is authorised — as one short Dutch line the settings page shows. Written BEFORE the launch
// re-arm so it is evidence of the state the app woke up to, not of what it just scheduled.
enum MorningDiag {
    static let launchKey = "morning.diag.launch"

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "nl_NL")
        f.dateFormat = "dd-MM HH:mm"
        return f
    }()

    private static let short: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "nl_NL")
        f.dateFormat = "HH:mm"
        return f
    }()

    static func hhmm(_ date: Date) -> String { short.string(from: date) }

    /// One line: "05-09 08:12 · auth ok · 1 gepland · volgende 06-09 07:00".
    static func line(now: Date = Date()) async -> String {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let auth: String
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: auth = "auth ok"
        case .denied: auth = "auth GEWEIGERD"
        case .notDetermined: auth = "auth nog niet gevraagd"
        @unknown default: auth = "auth ?"
        }
        let pending = await center.pendingNotificationRequests()
        let morning = pending.first { $0.identifier == MorningScheduler.notificationId }
        let fallback = pending.first { $0.identifier == MorningScheduler.fallbackId }
        let next = (morning?.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
        let fallbackAt = (fallback?.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
        let nextText = next.map { "melding " + clock.string(from: $0) }
            ?? fallbackAt.map { "wacht op score, vangnet " + clock.string(from: $0) }
            ?? "wacht op score"
        return "\(clock.string(from: now)) · \(auth) · \(pending.count) gepland · \(nextText)"
    }

    /// Persist the launch-time line (read by the settings page as "Bij start: …").
    static func recordLaunch(_ label: String) async {
        let text = await line()
        UserDefaults.standard.set("\(label) \(text)", forKey: launchKey)
        log("start \(label)")
    }

    // MARK: Event log — the last few things that happened, for the settings page
    static let logKey = "morning.diag.log"

    static func log(_ text: String) {
        var lines = UserDefaults.standard.stringArray(forKey: logKey) ?? []
        lines.append("\(clock.string(from: Date())) \(text)")
        if lines.count > 6 { lines.removeFirst(lines.count - 6) }
        UserDefaults.standard.set(lines, forKey: logKey)
    }

    static func recent() -> [String] {
        UserDefaults.standard.stringArray(forKey: logKey) ?? []
    }
}

// MARK: - MorningRefresh — the T − 10 min background run
//
// Sends requestMorning to the phone (reachable from a background refresh task), applies whatever comes
// back, re-arms the next slot, and completes the WatchKit task exactly once — on reply, on error, or on
// a 25 s timeout so the task budget is never blown.
@MainActor
final class MorningRefresh {
    private var finished = false
    private let completion: () -> Void

    private init(completion: @escaping () -> Void) {
        self.completion = completion
    }

    static func run(completion: @escaping () -> Void) {
        let run = MorningRefresh(completion: completion)
        // Today's moment already fired or was seen: nothing left to pull for, just re-arm the slots.
        if MorningSettings.lastFiredDay == WatchScoreSnapshot.localDayKey(Date())
            || MorningSettings.lastShownDay == WatchScoreSnapshot.localDayKey(Date()) {
            run.finish()
            return
        }
        WatchScoreStore.shared.requestMorning(force: false) { _ in
            Task { @MainActor in run.finish() }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            run.finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        MorningDiag.log("refresh klaar")
        MorningScheduler.scheduleRefresh()
        completion()
    }
}

// MARK: - WatchAppDelegate — launch hook + background task dispatch
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        Task {
            await MorningDiag.recordLaunch("delegate")
            await MorningScheduler.rearm()
        }
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let refresh = task as? WKApplicationRefreshBackgroundTask {
                MorningDiag.log("refresh gestart")
                Task { @MainActor in
                    MorningRefresh.run { refresh.setTaskCompletedWithSnapshot(false) }
                }
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}

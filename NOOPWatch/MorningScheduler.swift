import Foundation
import UserNotifications
import WatchKit
import StrandDesign

// MARK: - MorningSettings — the user's choices, on the watch
enum MorningSettings {
    static let enabledKey = "morning.enabled"
    static let hourKey = "morning.hour"
    static let minuteKey = "morning.minute"

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

// MARK: - MorningScheduler — the notification + the background refresh ahead of it
//
// The Watch owns the morning clock. Two things are armed from here, idempotently, on launch and after
// every settings change: the repeating calendar notification at T (category MORNING → the custom long
// look), and a background app refresh at T − 10 min whose only job is to wake the phone for today's
// scores + briefing (MorningRefresh). "Test nu" arms a one-shot copy 10 s out.
enum MorningScheduler {
    static let category = "MORNING"
    static let notificationId = "morning-moment"
    static let testId = "morning-test"

    static func rearm() async {
        await scheduleNotification()
        scheduleRefresh()
    }

    static func scheduleNotification() async {
        let center = UNUserNotificationCenter.current()
        guard MorningSettings.enabled else {
            center.removePendingNotificationRequests(withIdentifiers: [notificationId])
            return
        }
        await requestAuthorizationIfNeeded(center)
        var comps = DateComponents()
        comps.hour = MorningSettings.hour
        comps.minute = MorningSettings.minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        // Adding under an existing identifier REPLACES the pending request, so no remove-then-add:
        // both calls are asynchronous on the notification daemon and a remove that lands after the add
        // would silently delete the fresh schedule.
        let request = UNNotificationRequest(identifier: notificationId, content: content(), trigger: trigger)
        try? await center.add(request)
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
        let fire = MorningSchedule.nextFire(after: now, hour: MorningSettings.hour, minute: MorningSettings.minute)
        let preferred = MorningSchedule.refreshDate(for: fire, now: now)
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: preferred, userInfo: nil) { _ in }
    }

    private static func content() -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = String(localized: "Goedemorgen")
        c.body = String(localized: "Je ochtendrapport staat klaar")
        c.categoryIdentifier = category
        c.sound = .default
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
        let next = (morning?.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
        let nextText = next.map { "volgende " + clock.string(from: $0) } ?? "GEEN volgende"
        return "\(clock.string(from: now)) · \(auth) · \(pending.count) gepland · \(nextText)"
    }

    /// Persist the launch-time line (read by the settings page as "Bij start: …").
    static func recordLaunch(_ label: String) async {
        let text = await line()
        UserDefaults.standard.set("\(label) \(text)", forKey: launchKey)
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
                Task { @MainActor in
                    MorningRefresh.run { refresh.setTaskCompletedWithSnapshot(false) }
                }
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}

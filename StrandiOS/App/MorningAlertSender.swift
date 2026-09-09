#if os(iOS)
import Foundation
import UserNotifications
import StrandDesign

// MARK: - MorningAlertSender — the phone sends the morning notification
//
// The iPhone COMPUTES the score, so it knows first. Letting the Watch drive the alert made it depend on
// watchOS granting background time, which it does sparingly: on 09-09 the watch app happened to be awake
// at 06:43 and armed 07:00, but the alert's content then went stale before it was opened.
//
// So the phone sends it. watchOS mirrors an iPhone notification to the wrist and renders it with the
// WATCH app's interface for the same category, so the long look is the same either way. The snapshot
// travels INSIDE the notification (`MorningAlert.userInfo`), so the wrist shows the numbers that were
// true when the alert was made — never a "nog niet gesynct" screen for an alert that had data.
//
// The Watch keeps its own path; both use `MorningAlert.identifier`, which is exactly how Apple says to
// let watchOS dedupe a phone notification against a watch one instead of alerting twice.
@MainActor
enum MorningAlertSender {
    /// Local day the alert was last sent, so it goes out once a day.
    static let lastDayKey = "morningAlert.lastDay"
    /// Morning time, mirrored from the Watch (it owns the setting); defaults to 07:00.
    static let hourKey = "morningAlert.hour"
    static let minuteKey = "morningAlert.minute"
    static let enabledKey = "morningAlert.enabled"

    static var hour: Int { UserDefaults.standard.object(forKey: hourKey) as? Int ?? 7 }
    static var minute: Int { UserDefaults.standard.object(forKey: minuteKey) as? Int ?? 0 }
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// The Watch tells the phone its morning settings on every message it sends.
    static func adoptSettings(from message: [String: Any]) {
        let d = UserDefaults.standard
        if let h = message[MorningPlan.hourKey] as? Int { d.set(h, forKey: hourKey) }
        if let m = message[MorningPlan.minuteKey] as? Int { d.set(m, forKey: minuteKey) }
        if let e = message[MorningPlan.enabledKey] as? Bool { d.set(e, forKey: enabledKey) }
    }

    /// Ask once; without this the phone cannot alert at all (and so cannot mirror to the wrist).
    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    /// Send (or schedule) today's morning alert if this snapshot earns it. Idempotent: once sent for a
    /// local day, later snapshots do nothing, so a score that arrives in pieces alerts exactly once.
    /// - Parameter force: the wrist's "Rapport nu" test — send within seconds regardless of the
    ///   once-a-day guard and of whether T has passed, so the whole path can be verified on demand.
    static func maybeSend(_ snap: WatchScoreSnapshot, now: Date = Date(), force: Bool = false) async {
        guard enabled || force else { return }
        let today = WatchScoreSnapshot.localDayKey(now)
        let defaults = UserDefaults.standard
        if !force {
            guard defaults.string(forKey: lastDayKey) != today else { return }
            // Only a real score for TODAY earns the alert — never yesterday's numbers carried over.
            guard MorningAlert.isScored(snap, now: now) else { return }
        }

        let fire = force ? now : MorningSchedule.fireToday(now: now, hour: hour, minute: minute)
        let content = UNMutableNotificationContent()
        content.title = "Goedemorgen"
        content.body = MorningAlert.body(for: snap)
        content.categoryIdentifier = MorningAlert.category
        content.userInfo = MorningAlert.userInfo(for: snap)
        content.sound = .default

        // Before T: schedule for T with the numbers as they are now (a later, better snapshot replaces
        // this request under the same identifier). At or after T: send within seconds.
        let trigger: UNNotificationTrigger
        if fire > now.addingTimeInterval(30) {
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        } else {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
            defaults.set(today, forKey: lastDayKey)
        }
        let request = UNNotificationRequest(identifier: MorningAlert.identifier,
                                            content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
#endif

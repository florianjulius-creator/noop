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

    /// The phone no longer posts the morning notification itself. A notification forwarded from the
    /// iPhone is rendered with the plain system UI on the wrist — no rings, no numbers — because
    /// watchOS only uses the watch app's `WKNotificationScene` for a notification the WATCH posted.
    /// So the phone wakes the watch (a complication transfer in `WatchSessionBridge.send`) and the
    /// watch posts the alert. This type stays for the settings the wrist mirrors over.
}
#endif

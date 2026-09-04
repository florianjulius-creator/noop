import SwiftUI
import UserNotifications
import WatchKit

// MARK: - MorningNotificationController — the MORNING category's custom long look
//
// watchOS shows this SwiftUI view full screen when the wrist stays raised after the short look (or when
// the notification is opened from Notification Center). It reads the shared store, nudges it to re-read
// the app group (a background wake may have written a newer snapshot) and asks the phone for the latest
// mirror when reachable; the view observes the store, so a reply that lands a second later updates the
// rings in place. The system's own Dismiss button suffices — no custom actions.
final class MorningNotificationController: WKUserNotificationHostingController<MorningMomentView> {

    override var body: MorningMomentView {
        MorningMomentView(store: WatchScoreStore.shared, celebrate: true)
    }

    override func didReceive(_ notification: UNNotification) {
        WatchScoreStore.shared.reloadFromAppGroup()
        WatchScoreStore.shared.requestLatest()
    }
}

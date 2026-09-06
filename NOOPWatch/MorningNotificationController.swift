import SwiftUI
import UserNotifications
import WatchKit
import StrandDesign

// MARK: - MorningNotificationController — the MORNING category's custom long look
//
// watchOS shows this SwiftUI view full screen when the wrist stays raised after the short look (or when
// the notification is opened from Notification Center). It reads the shared store, nudges it to re-read
// the app group (a background wake may have written a newer snapshot) and asks the phone for the latest
// mirror when reachable; the view observes the store, so a reply that lands a second later updates the
// rings in place. The system's own Dismiss button suffices — no custom actions.
final class MorningNotificationController: WKUserNotificationHostingController<MorningMomentView> {

    // The system sash (app icon + delivery time) above the content cannot be removed or recoloured:
    // `sashColor` / `titleColor` overrides are ignored since watchOS 9 (Apple forums 713204, 719446),
    // and on the simulator neither the app icon nor a black AccentColor changed it — it follows the
    // watch face's tint. So the content below simply fits the first screen (rings ≤ 130 pt).

    override var body: MorningMomentView {
        MorningMomentView(store: WatchScoreStore.shared, celebrate: true)
    }

    override func didReceive(_ notification: UNNotification) {
        MorningSettings.lastShownDay = WatchScoreSnapshot.localDayKey(Date())
        MorningDiag.log("getoond (\(notification.request.identifier))")
        WatchScoreStore.shared.reloadFromAppGroup()
        WatchScoreStore.shared.requestLatest()
    }
}

#if os(iOS)
import Foundation
import Intents

// MARK: - FocusStatusHandler — the Sleep Focus ending re-fires the Watch's morning moment
//
// iOS delivers `INShareFocusStatusIntent` to this app (launched in the background if needed) whenever
// the user's Focus changes, once the user has shared Focus status with the app (INFocusStatusCenter
// authorization, prompted at launch). The only thing done with it: when a Focus ENDS, wake the Watch so
// it can re-fire a morning notification that landed silently under the Sleep Focus. The Shortcuts
// `MorningMomentIntent` does the same from a manual automation and stays as a fallback.
final class FocusStatusHandler: NSObject, INShareFocusStatusIntentHandling {
    func handle(intent: INShareFocusStatusIntent,
                completion: @escaping (INShareFocusStatusIntentResponse) -> Void) {
        let focused = intent.focusStatus?.isFocused ?? false
        UserDefaults.standard.set(focused, forKey: "focus.isFocused")
        if !focused {
            Task { @MainActor in await WatchSessionBridge.current?.wakeWatchForMorning() }
        }
        completion(INShareFocusStatusIntentResponse(code: .success, userActivity: nil))
    }
}
#endif

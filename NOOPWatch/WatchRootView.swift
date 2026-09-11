import SwiftUI
import StrandDesign

// MARK: - WatchRootView — the swipeable page deck
//
// Two pages, swiped (or turned with the Digital Crown): the glance (last night's synced scores) and the
// morning-moment settings with its diagnostics. Nothing else — the watch shows the stats and posts the
// morning alert; the phone stays the brain. (Breathe / Workout / Intervals were dropped on 11-09-2026.)
struct WatchRootView: View {
    var body: some View {
        TabView {
            WatchGlanceView()
            WatchMorningSettingsView()
        }
        // watchOS page TabView shows the page-indicator dots by default; the iOS background-display-mode
        // customisation is unavailable here, so the plain page style is the right call.
        .tabViewStyle(.page)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        // Belt and braces for the morning schedule: the delegate re-arms at launch, but a UI start
        // re-arms too (idempotent — same identifier replaces), and records what it found first. It also
        // ASKS the phone for its latest snapshot: the phone only pushes on its own foreground, so without
        // this the glance shows whatever it last got until the iPhone app is opened. WatchConnectivity
        // launches the iPhone app in the background to answer, so the reply is fresh even from a pocket.
        .task {
            if UserDefaults.standard.string(forKey: MorningDiag.launchKey) == nil {
                await MorningDiag.recordLaunch("ui")
            }
            WatchScoreStore.shared.requestLatest()
            await MorningScheduler.rearm()
        }
    }
}

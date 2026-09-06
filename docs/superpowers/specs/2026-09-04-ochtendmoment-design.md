# Ochtendmoment — morning ring moment on the Watch (design spec)

Date: 2026-09-04 · Fork: The Machine (`hrv-complication`) · Status: approved by Florian (HTML design + popup)

## Goal

Every morning at a time the user picks on the Watch, a full-screen ring moment appears on the Watch
Ultra without opening the app: Recovery (outer) and Sleep (inner) animate in Apple-Activity style,
then the Digital Crown scrolls through three blocks (Recovery, Sleep, Ochtendrapport). Mechanism:
a watch-local notification with a custom long look (`WKNotificationScene`), the same mechanism
Apple's own "ring closed" celebration uses. The Watch owns the schedule and wakes the iPhone.

Decisions taken with the user:
- Route A only: notification + custom long look. No Smart Stack widget, no Live Activity.
- Two rings: Recovery + Sleep. Blocks: Recovery · Sleep · Ochtendrapport.
- Time is set on the Watch (default 07:00, default enabled).
- The daily iPhone push "Ochtendrapport" has never fired for the user and is removed. The
  briefing text is delivered only through the watch snapshot.
- Every briefing outcome is recorded as a readable status; silent failure is not allowed.

## What cannot be done (and what we do instead)

- watchOS gives third-party apps no "first unlock / wrist-on" hook and no way to self-launch
  full screen. Hence a user-chosen time. If the Watch is on the charger when it fires, the
  notification waits in Notification Center; tapping it plays the same long look + animation.
- Notifications cannot page horizontally; "tabs" become vertically stacked blocks (Crown).
- Sleep Focus silences normal notifications; the user picks a time at/after the focus ends.
  Time-sensitive interruption level is out of scope (needs an entitlement).

## Morning flow

| When | Where | What |
|---|---|---|
| night | WHOOP strap → iPhone | BLE offload in background, as today. |
| T − 10 min | Watch → iPhone | Watch background refresh task sends `requestMorning`. WatchConnectivity wakes The Machine on the iPhone. The iPhone replies at once with its current snapshot, then generates the briefing (day-guarded) and pushes a fresh snapshot with text via `updateApplicationContext` plus one `transferCurrentComplicationUserInfo` per day (wakes the watch app; a complication is on the active face). |
| T | Watch | Repeating calendar notification (category `MORNING`). Wrist up → short look → automatic full-screen long look. The long look reads the App Group snapshot, observes the shared store, and sends `requestLatest` when the iPhone is reachable. |
| 0–2 s | Watch | Rings sweep in (spring), number counts up, comet-tail sparks trail the ring tip, burst on arrival, haptic `.notification`. |
| after | Watch | Crown scrolls to the three blocks. System "Dismiss" closes. |

The iPhone's own 06:45 BGAppRefresh (`.morningbriefing`) stays as a silent fallback that only
generates + pushes; it no longer posts a notification.

## Components

### Shared (`Packages/StrandDesign`)

- `WatchScoreSnapshot` gains eight optional, wire-compatible fields (same pattern as `hrvMs`):
  `restingHr: Int?`, `restingHrBaseline: Int?`, `hrvBaselineMs: Int?`, `sleepMin: Int?`,
  `sleepEfficiencyPct: Int?`, `briefing: String?`, `briefingDay: String?`, `briefingStatus: String?`.
- `MorningMoment` (pure struct, no SwiftUI): snapshot + `now` → display state.
  - `scoreState`: `.fresh(recovery:sleep:)` when `scoreDay` is today's local day; `.notScored`
    otherwise (rings empty, dash, hint "Nacht nog niet gesynct — open The Machine op je iPhone").
    A stale snapshot (`isStale`) is `.notScored` too.
  - `verdict`: one word from the recovery zone — ≥ 67 "KLAAR", 34…66 "MATIG", < 34 "RUST".
  - `hrvDeltaPct: Int?` = (hrvMs − hrvBaselineMs) / hrvBaselineMs × 100, rounded; nil when either
    is missing or baseline is 0.
  - `briefingText: String?` only when `briefingDay` equals `scoreDay` (never yesterday's text
    under today's rings).
  - Contributor bars (0…1): HRV = clamp(hrvMs / (1.25 × hrvBaselineMs)); RHR =
    clamp(restingHrBaseline / restingHr); Sleep = rest / 100. Each nil when inputs are missing (bar hidden).

### iPhone (`Strand/Data/WatchSessionBridge.swift`, `StrandiOS/App/MorningBriefing.swift`)

- `buildSnapshot` fills the new fields from the same anchor day the widget uses: `restingHr`,
  30-day `restingHrBaseline` and `hrvBaselineMs` (same average `MorningBriefing.buildContext` computes — extract that into
  one shared helper), `sleepMin`, `sleepEfficiencyPct`, plus `briefing`/`briefingDay`/
  `briefingStatus` from `MorningBriefing` storage.
- `headlineChanged` counts the new fields except `briefingStatus`.
- `pushLatest(from:force:)`: `force: true` skips the 30-minute spacing gate (used for the
  morning push and the `requestMorning` reply path only).
- `send(_:wakeWatch:)`: when `wakeWatch` is true also call `transferCurrentComplicationUserInfo`
  with the same payload, at most once per local day (`watch.lastWakeDay`).
- New WC message `requestMorning` (`force: Bool`): reply immediately with the current snapshot
  (App Group mirror), then `Task { await MorningBriefing.generateIfDue(model:force:) ; await
  watch.pushLatest(from: model, force: true, wakeWatch: true) }`.
- `MorningBriefing`:
  - `notify(_:dayKey:)` and the `UserNotifications` import are removed. Nothing on the iPhone
    posts a morning notification any more.
  - `generateIfDue` records `briefing.lastStatus` on every exit path: "OK HH:mm" (Dutch,
    24h), "uitgeschakeld", "geen API-key", "geen gescoorde nacht", "te vroeg (< 06:00)",
    "API-fout: <localizedDescription>" (the `try?` becomes `do/catch`), "leeg antwoord".
    Status text is written in Dutch because it is read on the Watch.
  - Fire time stays 06:45 (fallback only). No change to `nextFireDate`.

### Watch (`NOOPWatch`)

- `WatchScoreStore.shared` singleton; the App and the notification controller both use it.
  Adds `session(_:didReceiveUserInfo:)` (same decode/apply as context), `requestLatest()` and
  `requestMorning(force:)` via `sendMessage` with reply handler (apply the reply snapshot;
  ignore errors). Both are no-ops when `!session.isReachable`.
- `MorningSettings` (UserDefaults.standard): `morning.enabled` (default true), `morning.hour`
  (7), `morning.minute` (0).
- `MorningScheduler`:
  - `scheduleNotification()`: removes pending `morning-moment`, and when enabled adds a
    `UNCalendarNotificationTrigger(dateMatching: hour+minute, repeats: true)` with category
    `MORNING`, title "Goedemorgen", body "Je ochtendrapport staat klaar". Requests
    authorization (`.alert, .sound`) first when not determined.
  - `scheduleRefresh()`: `WKExtension.shared().scheduleBackgroundRefresh(withPreferredDate:
    nextFire − 10 min, userInfo: nil)`; re-armed from the refresh handler and on launch.
  - `scheduleTest()`: one-shot `UNTimeIntervalNotificationTrigger(10 s)` with the same
    category, id `morning-test`.
  - Called on app launch and after every settings change.
- `NOOPWatchApp`: adds `WKNotificationScene(controller: MorningNotificationController.self,
  category: "MORNING")` and `.backgroundTask(.appRefresh)` on the WindowGroup; the handler sends
  `requestMorning(force: false)` and re-arms `scheduleRefresh()`.
- `MorningNotificationController: WKUserNotificationHostingController<MorningMomentView>`:
  `didReceive` loads the App Group snapshot into the store if the store has none newer, calls
  `store.requestLatest()`, returns `MorningMomentView(store:)`. `isInteractive` stays false.
- `MorningMomentView`: two concentric `GlowRing`-style arcs (recovery colour =
  `StrandPalette.recoveryColor(score)`, sleep colour = `StrandPalette.restLine`), centre number
  + verdict word, spark layer (`Canvas` in a `TimelineView`, ~1.2 s, then removed from the
  hierarchy), haptic on appear. Below: Recovery block (verdict line + three contributor bars),
  Sleep block (duration, efficiency, Rest score), Ochtendrapport block (text; hidden when nil).
  Honours system Reduce Motion: no sweep, no sparks, haptic kept.
- `WatchMorningSettingsView` = page 5 of `WatchRootView`: toggle, `DatePicker(.hourAndMinute)`,
  status row "Rapport: <briefingStatus>" with a "Nu" button (`requestMorning(force: true)`),
  "Test nu" (`scheduleTest`), "Bekijk vandaag" (sheet with `MorningMomentView`).
- Strings go through `NOOPWatch/Localizable.xcstrings` like the rest of the watch UI.

## Testing

- `StrandDesign` package tests: snapshot round-trip with the eight fields + legacy payload
  decodes to nil; `MorningMoment` states (fresh / not scored / stale / no briefing / yesterday's
  briefing suppressed / verdict thresholds / HRV delta / bars).
- `BriefingStatus` texts and the T − 10 min derivation live in `StrandDesign` (pure) and are
  tested there; `headlineChanged` is iOS-only and verified by the Release compile + device run.
- Simulator: `.apns` payload with `"category": "MORNING"` on the NOOPWatch scheme renders the long
  look with the DEBUG demo snapshot.
- Device: `Tools/install-device.sh`; on the Watch "Rapport nu" → status shows OK or the reason;
  "Test nu" → notification after 10 s → animation + blocks; next morning real run.
- Gate: 8 packages `swift test`, `xcodebuild test -scheme Strand` (macOS), NOOPiOS + NOOPWatch
  Release against the 27 SDK — all green.

## Build order

1. Shared: snapshot fields + `MorningMoment` + tests.
2. iPhone: fill fields, briefing + status into snapshot, remove push, `requestMorning` handler,
   force push, wake push.
3. Watch: store singleton + messaging, background refresh, scheduler, notification scene, ring
   view, settings page.
4. Device install; verify with "Rapport nu" / "Test nu"; confirm the next morning.

## Out of scope

Smart Stack widget, Live Activity, iPhone UI changes, evening moment, time-sensitive
notifications, Dutch localisation of the rest of the watch app.

## Addendum 05-09-2026 — freshness: the Watch pulls, the phone pushes in the background

Observed: the 05-09 notification did not fire (reinstall wiped the schedule, app not relaunched) and
the long look read "nog niet gesynct" (the iPhone app had not run since the reinstall, so no strap
offload overnight). Two structural gaps behind that:

1. The phone only pushed the Watch on its own foreground (`scenePhase == .active`); a night offloaded
   in the background reached the widget and Health but not the wrist.
2. The Watch never asked; it waited for a push.

Changes:
- `WatchScoreSnapshot` + `lastSyncAt`, `strapConnected` (optional); Watch page 5 shows
  "Strap: verbonden · laatste sync dd-MM HH:mm".
- `AppModel.watchPush` closure, called from `refreshAfterCompletedBackfill` next to the widget publish
  and Health write-back (rate-limited in the bridge, one complication wake per day).
- Watch root `.task` sends `requestLatest` on every UI start (WatchConnectivity launches the iPhone
  app in the background to answer).
- Morning wake is two-staged: `MorningSchedule.refreshStages = [T − 25 min, T − 5 min]`; past the
  last stage the next slot is tomorrow's first (no re-arm loop). On `requestMorning` the phone first
  runs `MorningSync.pullStrap` (`.manual` offload, bounded 150 s wait, deferred re-score), then the
  briefing, then the forced push.
- Scheduling diagnostics on page 5 ("Nu" / "Bij start"): auth, pending count, next fire.
- Operational rule: after every install open the iPhone app AND the Watch app once; never force-quit
  the iPhone app (iOS stops relaunching it for strap events).
- The long look's system sash (icon + coloured bar) cannot be removed or recoloured on watchOS 9+;
  rings are 130 pt so ring + verdict fit the first screen.

## Addendum 06-09-2026 — the Sleep Focus: re-fire when it ends

Observed 06-09: the 07:00 notification fired, but the Watch sat under the Sleep Focus, so it landed
silently in Notification Center (proven by the page-5 diagnostics: "Bij start … 1 gepland · volgende
06-09 07:00", process alive all night). The user wants the moment on the wrist as soon as the Focus ends.

- Chosen mechanism: a Shortcuts personal automation "When Sleep Focus is turned off → run 'Ochtendmoment
  naar de Watch' (immediately)". The App Intent `MorningMomentIntent` runs the iPhone app in the
  background and calls `WatchSessionBridge.wakeWatchForMorning()`, a complication transfer with
  `focusEnded`. The Watch's `didReceiveUserInfo` calls `MorningScheduler.fireIfMissedToday`: within
  T…T+6 h and only when `morning.lastShownDay` ≠ today, it removes the silent delivery and fires
  `morning-late` after 3 s (category MORNING → the long look).
- `MorningNotificationController.didReceive` records `lastShownDay`, so a moment already viewed from
  Notification Center is not re-fired.
- The Focus Status API (`INShareFocusStatusIntent`, no automation needed) was implemented and reverted:
  it requires the Communication Notifications capability in the provisioning profile, which the
  headless build cannot add. Re-enable via Xcode GUI if wanted.
- Page 5 keeps an event log (start / refresh / getoond / focus-einde) and refreshes "Nu" on appear and
  every minute. Rings are 100 pt with a one-line legend so the device's first screen holds them.

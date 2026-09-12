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

## Addendum 08-09-2026 — the moment is data-driven

Observed 08-09: the 07:00 alert did reach the wrist (Focus allow-list), but read "Nog niet gesynct":
the night was not scored yet at 07:00 — it cannot be before the user is up, the strap has offloaded
the finished sleep and the phone has scored it. A fixed time can never guarantee content.

- `MorningPlan.decide(scored:now:fire:shownToday:firedToday:)` (StrandDesign, tested): today's
  score on the Watch and T passed → fire now; score before T → one-shot at T; no score → nothing at
  T, fallback notice "Nog geen score van vannacht" at T + 90 min; fired or seen → done.
- `MorningScheduler.reconcile(reason:)` is the single entry point (launch, settings change, every
  snapshot that lands via `WatchScoreStore.apply`). No repeating calendar trigger any more.
- Refresh stages now `[T−25, T−5, T+10, T+25, T+45]` so the Watch keeps asking the phone after wake;
  `MorningRefresh` skips the ask once today's moment fired or was seen.
- Phone: the first push of the day that carries today's recovery bypasses the 30-min gate and spends
  the once-a-day complication wake; unscored pushes never spend it.
- "Seen" (`lastShownDay`) only counts when the long look showed today's score, so a viewed fallback
  notice does not block the real moment.

## Addendum 09-09-2026 — the phone sends it, and the alert carries its own data

The page-5 log settled it: the watch app was awake at 06:43, had a score, armed 07:00, and the alert
did fire — but by 08:28 the store read "0 gepland · wacht op score", so the card opened on the
not-scored screen. Three separate faults:

1. **The alert's data did not travel with it.** `MorningAlert` (StrandDesign) now defines one
   identifier, one category, and a `userInfo` payload carrying the JSON snapshot. Both senders attach
   it; `MorningNotificationController.didReceive` adopts it before the view renders.
2. **A newer-but-emptier snapshot removed today's score.** `WatchScoreStore.apply` refuses a snapshot
   that drops today's recovery when we already had it.
3. **The alert depended on watch background time.** `MorningAlertSender` (iOS) sends it: the phone
   computes the score, so it knows first, and watchOS mirrors a phone notification to the wrist,
   rendering it with the watch app's long look for the same category. Both sides use
   `MorningAlert.identifier`, so watchOS dedupes rather than alerting twice. The Watch sends its
   morning time with every WC message (`MorningPlan.hourKey/minuteKey/enabledKey`).

Layout: the notification uses `MorningMomentView(compact: true)` — an 88 pt ring plus one line
("Slaap 83 · HRV 31 ms · Pols 49"), top-aligned, no ScrollView. The system leaves ~140 pt between its
sash and the dismiss button; centred taller content was clipped at both ends.

Testing without waiting for tomorrow: "Rapport nu" on page 5 forces the phone to send the real alert
(`alertForce`), bypassing the once-a-day and before-T guards. The iPhone must be locked or set aside,
or iOS shows the alert on the phone instead of mirroring it.

## Addendum 10-09-2026 — root cause: the background score never reached the wrist

Decisive observation: at 07:23 the iPhone's Today screen showed the night's recovery, the Watch still
showed yesterday's ("wacht op score"). The score existed; it was not pushed. Three background paths
scored (or could score) without pushing the Watch:

1. `AppModel.runDeferredRescoreIfOwed` published the widget only → now also `watchPush?()`.
2. `MorningBriefing.handle` (the 06:45 BGAppRefresh) generated and stopped → now `model.watchPush?()`.
3. `MorningSync.pullStrap` ran `runDeferredRescoreIfOwed`, which only resumes a pass an earlier attempt
   started; a night whose data landed in that very offload was never "owed" → now
   `intelligence.analyzeRecent()` unconditionally after the offload.

Also reverted on 09-09 (evening): the phone-sent alert. A notification forwarded from the iPhone is
rendered with the plain system UI on the wrist (no `WKNotificationScene`), and narrowing the wake to
once a day starved the complication, which reads the Watch's own App Group copy. The phone now wakes
the Watch on every push that goes out (20-minute floor, `transferUserInfo` fallback) and the Watch
posts the alert. Time Sensitive is set on both senders.

Layout is verified on watchOS 26.5 and 27.0 simulators with a full pushed payload: 96 pt ring + one
line, natural height (the long look is itself a scroll page); no `maxHeight` frame, no GeometryReader.
Page 5 shows the complication extension's own heartbeat ("extensie: <time> zag <charge>").

## Addendum 11-09-2026 — the strap pull waits, the phone kicks itself, the Mac can read the wrist

Morning of 11-09: no alert again. Page 5 read "Strap: verbonden · laatste sync 00:51"; the Watch's
refreshes at 07:25 and 07:45 did reach the phone (`requestMorning`), but the phone had been launched
COLD in the background and `MorningSync.pullStrap` started with `guard live.connected, live.bonded` —
false in the first second, before CoreBluetooth had restored the link — so it returned without an
offload and the night was never scored. Transport (WatchConnectivity) was fine; the data was missing.

Decisions:

1. **The pull waits for the link.** `MorningSync.pullStrap` polls `connected && bonded` for up to
   90 s, then forces an offload (`.manual`, no rate floor), waits for it (≤150 s), scores
   (`analyzeRecent`) and pushes. Every outcome is written to `syncStatus` in the snapshot and shown on
   page 5 as "Sync: offload 07:26 · gescoord" / "geen strap binnen 90 s" — no more silent step.
2. **The phone kicks its own morning offload (standalone path).** Every strap packet wakes the app in
   the background, so the BLE notify path is the one clock that ticks overnight.
   `MorningSync.kickIfDue` (called from `didUpdateValueFor`, one comparison per packet, real check
   once a minute) forces an offload from T − 45 min when the last offload predates that window, at
   most once per 20 min. The completed offload scores and pushes the wrist by itself
   (`refreshAfterCompletedBackfill` → `watchPush`). The Watch's wake at T − 25 is now the second path,
   not the only one.
3. **Self-readable diagnostics.** `DiagSink` (iOS) appends JSON lines to `Documents/diag/`:
   `phone.jsonl` (message received, pull outcome, push, wake), `watch.jsonl` (the Watch's page-5
   lines, attached to every message and queued as `transferUserInfo` after every `MorningDiag.log`),
   `ble-<day>.log` (the strap log tail — previous process's rolled tail + live ring — at every pull and
   kick, which is where "why no offload since 00:51" will be answered). `Tools/diag-pull.sh` copies
   the folder off the phone with `devicectl device copy from … --domain-type appDataContainer` and
   prints the tails. No more photographs of the wrist.
4. **The Watch app is two pages:** the glance (last night's stats) and the morning settings with its
   diagnostics. Breathe / Workout / Intervals were removed (files deleted, deck + DEBUG demo cases).

5. **The night is scored in the background during the morning window.** The first `diag-pull`
   (08:22) answered the deeper question: offloads DID land in the background (07:32, 07:42, 07:52,
   08:02, 08:15 — "rows landed on 2026-09-11"), but each post-offload pass logged "re-score: deferred
   to a background task — a re-score is already outstanding from an earlier trigger".
   `RescoreBackgroundPolicy` defers a backgrounded pass once a debt is owed or the last pass took
   over 20 s, and the `BGProcessingTask` it schedules does not come in the morning — so the score
   existed only after the app was opened. Now `AppModel.refreshAfterCompletedBackfill` passes
   `isBackground: false` while `MorningSync.inWindow()` (T − 45 min … T + 3 h): the pass runs
   immediately under the scheduler's background assertion, and `pullStrap` scores through the same
   assertion. The push record in `phone.jsonl` carries `rescoreOwed` and `lastPassSeconds`.

Considered and not chosen: a cloud relay (iPhone uploads the snapshot, the Watch fetches it with a
`WKURLSessionRefreshBackgroundTask`). It only helps when the phone is out of Bluetooth range at
night, needs a server and network on the wrist, and does nothing for the failure that actually
occurred (no night on the phone). Apple Health has no type for a recovery score and its iPhone→Watch
sync timing cannot be driven. Both stay fallbacks if the diag shows WatchConnectivity itself failing.

## Addendum 12-09-2026 — the phone had given up on the strap

Read from `Tools/diag-pull.sh`, no photo needed. Yesterday's chain did work once the data arrived:
11:24 "snapshot: score binnen → melding nu", 11:24 "getoond (morning-moment)". Last night:

- 11:54 last offload; the link dropped and a **bond-loop pause** latched (`autoReconnectPausedForBondLoop`,
  #617/#1635): auto-reconnect off, only the foreground salvage probe (#78 hole-4) can end it.
- 00:00, 07:03 (BGTask), 07:37 and 07:55 (Watch wakes): every push said `strapConnected: false`.
- `pullStrap` ran at 07:37 but its 90 s wait only advanced between wakes — "geen strap binnen 90 s"
  was stamped at 07:55, then again at 08:03: the process was suspended in between.
- 08:03:27 the phone was picked up → foreground → "Bond-loop pause: one salvage probe" →
  "connect handshake done" one second later. The strap was reachable all night; nobody asked.
- The trip line itself fell outside the 400-line dump (the strap's console is most of the ring).

Decisions:

6. **`BLEManager.reconnectForMorning()`**: a paused strap gets the same one bounded salvage probe the
   foreground gives it (floors unchanged, give-up stays latched); an unpaused one gets its standing
   connect re-parked (idempotent). Called from `pullStrap` when there is no link, and from the 06:45
   BGTask. `pullStrap` now holds a `beginBackgroundTask` assertion so its wait actually elapses; once
   the strap connects, the bluetooth-central link keeps the process alive for the offload and the pass.
7. The strap-log dump grows to the previous generation's last 1000 lines + the live ring's last 2500,
   and is also written on the no-link branch (`pull-nolink`), so a pause tripping at midday is readable
   the next morning.

Measured on this phone: a full re-score pass takes 225–239 s (`lastPassSeconds`), which is why every
backgrounded pass outside the morning window defers (decision 5 covers the window).

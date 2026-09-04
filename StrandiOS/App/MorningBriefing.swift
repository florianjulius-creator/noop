#if os(iOS)
import Foundation
import BackgroundTasks
import StrandDesign
import WhoopStore

// MARK: - Morning briefing — Claude's daily "hoe sta ik ervoor" push
//
// Every morning (the Watch's T − 10 min `requestMorning`, the ~06:45 background task as a fallback,
// and a foreground catch-up on first open) the phone builds a compact summary of last night —
// Recovery, HRV vs the 30-day baseline, resting HR, sleep, yesterday's Strain — and sends it to the
// SAME AI provider/key the in-app Coach is configured with (Settings → AI Coach; Anthropic + a Claude
// model for this user). Dutch by design: the reply is read by a Dutch user.
//
// Honest by design, like every other surface:
// - No key configured, or no scored night yet → generate nothing (never a made-up briefing).
// - One briefing per local day (`lastDayKey`), regenerated only via `force`.
// - The API payload carries day-level aggregates only — never raw R-R/HR streams.
// - No notification is posted on the iPhone any more: the text travels to the Watch inside the
//   WatchScoreSnapshot and is read there (the morning moment). Every outcome, good or bad, is
//   recorded as a `BriefingStatus` so the Watch can show WHY there is no text.
@MainActor
enum MorningBriefing {

    /// BGAppRefresh identifier — must stay in lockstep with BGTaskSchedulerPermittedIdentifiers in
    /// project.yml (mirrors ScheduledDebugExport's `.debugexport` registration).
    static var taskId: String {
        (Bundle.main.bundleIdentifier ?? "noop") + ".morningbriefing"
    }

    static let enabledKey = "briefing.enabled"
    static let lastDayKey = "briefing.lastDay"
    static let lastTextKey = "briefing.lastText"
    /// The last outcome, as `BriefingStatus.text` (Dutch), shipped to the Watch settings page.
    static let lastStatusKey = "briefing.lastStatus"

    private static func record(_ status: BriefingStatus) {
        UserDefaults.standard.set(status.text, forKey: lastStatusKey)
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "nl_NL")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// Opt-out toggle (default ON — the feature stays dormant anyway until an AI key is configured).
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// The app entry stores the live model here at launch so the background handler can reach the
    /// same repository the UI uses (a BGTask launch runs the full app, so this is always set before
    /// the handler fires).
    static weak var model: AppModel?

    // MARK: - Scheduling

    /// Register the BGTask handler. Must run before launch finishes (see ScheduledDebugExport).
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in handle(refresh) }
        }
    }

    /// (Re)arm the next morning run. Safe to call repeatedly — BGTaskScheduler replaces a pending
    /// request with the same identifier. Sideload-friendly: when submission fails (entitlement /
    /// beta quirks) the foreground catch-up in `generateIfDue` still produces the briefing on first
    /// open of the day.
    static func scheduleNext(now: Date = Date()) {
        guard enabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: taskId)
        request.earliestBeginDate = nextFireDate(after: now)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Next 06:45 local — early enough that the 07:00-ish delivery window is realistic, late enough
    /// that the night's scoring pass has data.
    static func nextFireDate(after now: Date) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: now)
        comps.hour = 6; comps.minute = 45
        let todayFire = Calendar.current.date(from: comps) ?? now
        if now < todayFire { return todayFire }
        return Calendar.current.date(byAdding: .day, value: 1, to: todayFire) ?? todayFire
    }

    private static func handle(_ task: BGAppRefreshTask) {
        scheduleNext()   // always re-arm tomorrow, whatever happens below
        let work = Task { @MainActor in
            if let model { await generateIfDue(model: model) }
            if !Task.isCancelled { task.setTaskCompleted(success: true) }
        }
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    // MARK: - Generation

    /// Generate once per local day. Called from the Watch's `requestMorning`, the BGTask and as a
    /// foreground catch-up on every scenePhase-active (cheap: the day guard exits immediately after the
    /// first success). Returns true when a NEW briefing was produced by this call, so the caller knows
    /// to push the wrist right away. Every exit records a `BriefingStatus`.
    @discardableResult
    static func generateIfDue(model: AppModel, force: Bool = false, now: Date = Date()) async -> Bool {
        guard enabled else { record(.disabled); return false }
        let todayKey = Repository.localDayKey(now)
        let defaults = UserDefaults.standard
        // Already done today: keep the OK status as it is.
        if !force, defaults.string(forKey: lastDayKey) == todayKey { return false }
        // Before 06:00 the night isn't scored yet — wait for the morning run / next open.
        if !force, Calendar.current.component(.hour, from: now) < 6 { record(.tooEarly); return false }
        // Same provider/key/model the in-app Coach uses; no key → dormant, never a fake briefing.
        guard let key = AIKeyStore.read(), !key.isEmpty else { record(.noKey); return false }
        guard let context = buildContext(model: model, todayKey: todayKey) else {
            record(.noScoredNight); return false
        }

        let provider = UserDefaults.standard.string(forKey: "ai.provider")
            .flatMap(AIProvider.init(rawValue:)) ?? .anthropic
        let storedModel = UserDefaults.standard.string(forKey: "ai.model") ?? ""
        let modelId = storedModel.isEmpty ? provider.defaultModel : storedModel

        let reply: String
        do {
            reply = try await provider.client.send(
                key: key,
                model: modelId,
                systemPrompt: Self.systemPrompt,
                messages: [(role: .user, content: context)],
                session: .shared)
        } catch {
            record(.apiError(error.localizedDescription)); return false
        }
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { record(.emptyReply); return false }
        defaults.set(todayKey, forKey: lastDayKey)
        defaults.set(text, forKey: lastTextKey)
        record(.ok(time: clock.string(from: now)))
        return true
    }

    /// The coaching contract: Dutch, compact, concrete — status, duiding, één trainingsadvies
    /// (fiets/JOIN-framing zodat het antwoord direct bruikbaar is in de JOIN readiness-vraag).
    static let systemPrompt = """
    Je bent de ochtendcoach van The Machine, een persoonlijke healthtracker-app. Je krijgt \
    dag-aggregaten van afgelopen nacht en gisteren (recovery 0-100, HRV in ms met 30-dagen-baseline, \
    rustpols met baseline, slaap, strain van gisteren op schaal 0-21). Schrijf een ochtendrapport in \
    het Nederlands van maximaal 80 woorden, als doorlopende tekst zonder opsommingen of emoji: \
    1) één zin hoe de gebruiker ervoor staat, 2) korte duiding van het waarom (HRV/rustpols vs \
    baseline, slaap), 3) één concreet trainingsadvies voor vandaag — de gebruiker fietst met de \
    JOIN-trainingsapp, dus zeg expliciet of de geplande JOIN-training vol kan, een stand lager moet, \
    of dat rust verstandig is. Geen disclaimers, geen groet, geen herhaling van de cijfers die je \
    niet nodig hebt.
    """

    /// Compact day-aggregate context, or nil when there is no scored night to talk about yet (the
    /// honest skip — a briefing about nothing helps nobody).
    static func buildContext(model: AppModel, todayKey: String) -> String? {
        let days = model.repo.days
        guard let day = Repository.widgetAnchor(days: days) else { return nil }
        // A briefing needs at least one overnight signal for the anchor day.
        guard day.recovery != nil || day.avgHrv != nil || day.totalSleepMin != nil else { return nil }

        let base = WatchSessionBridge.baselines(days: days)
        let yesterday = days.last(where: { $0.day < day.day })

        var lines: [String] = ["dag: \(day.day)"]
        func add(_ label: String, _ value: String?) {
            if let value { lines.append("\(label): \(value)") }
        }
        func fmt(_ v: Double?, _ digits: Int = 0) -> String? {
            v.map { String(format: "%.\(digits)f", $0) }
        }
        add("recovery", fmt(day.recovery))
        add("hrv_ms", fmt(day.avgHrv))
        add("hrv_baseline_30d_ms", base.hrvMs.map(String.init))
        add("rustpols_bpm", day.restingHr.map(String.init))
        add("rustpols_baseline_30d_bpm", base.restingHr.map(String.init))
        add("slaap_min", fmt(day.totalSleepMin))
        add("slaap_efficiency_pct", fmt((day.efficiency).map { $0 <= 1 ? $0 * 100 : $0 }))
        add("ademhaling_rpm", fmt(day.respRateBpm, 1))
        add("huidtemp_afwijking_c", fmt(day.skinTempDevC, 1))
        add("strain_gisteren_0_21", fmt((yesterday?.strain).map { $0 * 0.21 }, 1))
        add("workouts_gisteren", yesterday?.exerciseCount.map(String.init))
        return lines.joined(separator: "\n")
    }

}
#endif

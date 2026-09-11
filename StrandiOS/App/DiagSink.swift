#if os(iOS)
import Foundation
import StrandDesign

// MARK: - DiagSink — the morning's paper trail, readable from the Mac
//
// Every step of the morning chain (watch wake → strap pull → score → push) and every diagnostic the
// Watch sends over WatchConnectivity is appended here, as JSON lines in the app's Documents folder.
// `Tools/diag-pull.sh` copies it off the phone with `devicectl` whenever the phone is on the same
// network, so the chain can be read back without photographing the wrist.
enum DiagSink {
    static let folder = "diag"

    private static var dir: URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return nil }
        let d = docs.appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    private static func append(_ file: String, _ record: [String: Any]) {
        guard let dir else { return }
        var rec = record
        rec["t"] = stamp.string(from: Date())
        guard JSONSerialization.isValidJSONObject(rec),
              let data = try? JSONSerialization.data(withJSONObject: rec),
              let line = String(data: data, encoding: .utf8) else { return }
        let url = dir.appendingPathComponent(file)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data((line + "\n").utf8))
        } else {
            try? (line + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// A phone-side event ("push", "sync", "wake", "morning") with a free-text detail.
    static func phone(_ event: String, _ detail: String) {
        append("phone.jsonl", ["event": event, "detail": detail])
    }

    /// A snapshot summary alongside an event, so the log says WHAT was pushed.
    static func phone(_ event: String, snapshot snap: WatchScoreSnapshot, extra: String = "") {
        append("phone.jsonl", [
            "event": event, "detail": extra,
            "scoreDay": snap.scoreDay ?? "-", "charge": snap.charge ?? -1,
            "lastSyncAt": snap.lastSyncAt.map { stamp.string(from: $0) } ?? "-",
            "strapConnected": snap.strapConnected ?? false,
            "syncStatus": snap.syncStatus ?? "-", "briefingStatus": snap.briefingStatus ?? "-",
            "rescoreOwed": RescoreBackgroundScheduler.isRescoreOwed,
            "lastPassSeconds": RescoreBackgroundScheduler.lastCompletedPassSeconds ?? -1,
        ])
    }

    /// A block of plain lines under a stamped header (the strap log tail).
    static func file(_ name: String, header: String, lines: [String]) {
        guard let dir else { return }
        let block = "===== \(header) \(stamp.string(from: Date())) =====\n" + lines.joined(separator: "\n") + "\n"
        let url = dir.appendingPathComponent(name)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(block.utf8))
        } else {
            try? block.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Whatever the Watch reported about itself (its page-5 lines).
    static func watch(_ report: [String: Any]) {
        var rec: [String: Any] = [:]
        for (k, v) in report { rec[k] = v }
        append("watch.jsonl", rec)
    }
}
#endif

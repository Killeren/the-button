import AppKit

// MARK: - Event model

struct ButtonEvent: Equatable {
    let type: String        // "permission" | "notify" | "clear"
    let message: String
    let sessionId: String
    let claudePid: Int32
    let ancestors: [Int32]
    let tty: String         // e.g. /dev/ttys003 — the session's terminal device
    let cwd: String         // the claude session's working directory
    let toolName: String
    let detail: String      // command / file path being approved
    let ts: Double
    // v0.2 protocol
    let mode: String        // "decide" | "keystroke" | "" (notify/legacy)
    let answerPath: String  // where a decide answer must be written
    let hookPid: Int32      // the blocked permreq hook (decide mode)
    let deadlineTs: Double
    let ruleTool: String    // "Always allow" rule pieces precomputed by hook.py
    let ruleContent: String
    var fileKey: String = "" // events/ filename; "legacy" or "test-N" otherwise

    var isDecide: Bool { mode == "decide" && !answerPath.isEmpty }
    var projectName: String { (cwd as NSString).lastPathComponent }
    var ttyTail: String { (tty as NSString).lastPathComponent }
}

func loadEvent(from url: URL) -> ButtonEvent? {
    guard let data = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return ButtonEvent(
        type: obj["type"] as? String ?? "clear",
        message: obj["message"] as? String ?? "",
        sessionId: obj["session_id"] as? String ?? "",
        claudePid: Int32(obj["claude_pid"] as? Int ?? 0),
        ancestors: (obj["ancestors"] as? [Any] ?? []).compactMap { ($0 as? Int).map(Int32.init) },
        tty: obj["tty"] as? String ?? "",
        cwd: obj["cwd"] as? String ?? "",
        toolName: obj["tool_name"] as? String ?? "",
        detail: obj["detail"] as? String ?? "",
        ts: obj["ts"] as? Double ?? 0,
        mode: obj["mode"] as? String ?? "",
        answerPath: obj["answer_path"] as? String ?? "",
        hookPid: Int32(obj["hook_pid"] as? Int ?? 0),
        deadlineTs: obj["deadline_ts"] as? Double ?? 0,
        ruleTool: obj["rule_tool"] as? String ?? "",
        ruleContent: obj["rule_content"] as? String ?? ""
    )
}

// MARK: - Paths

enum StatePaths {
    // Honor $HOME like hook.py's expanduser does (NSHomeDirectory() reads the
    // passwd entry and ignores the environment) — keeps tests hermetic too.
    static let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    static let stateDir = URL(fileURLWithPath: home)
        .appendingPathComponent(".claude/the_button")
    static let eventsDir = stateDir.appendingPathComponent("events")
    static let answersDir = stateDir.appendingPathComponent("answers")
    static let legacyEvent = stateDir.appendingPathComponent("event.json")
    // Instance-specific so two running apps (or a --test run) never delete each
    // other's heartbeat; hook.py globs heartbeat*.json so any of them counts.
    static let heartbeat = stateDir.appendingPathComponent("heartbeat-app-\(getpid()).json")
}

/// Atomic write next to the target (same filesystem), then rename over it.
@discardableResult
func atomicWriteJSON(_ payload: [String: Any], to dest: URL) -> Bool {
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
    let fm = FileManager.default
    try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    let tmp = StatePaths.stateDir.appendingPathComponent(".tb-\(UUID().uuidString).tmp")
    try? fm.createDirectory(at: StatePaths.stateDir, withIntermediateDirectories: true)
    do { try data.write(to: tmp) } catch { return false }
    return rename(tmp.path, dest.path) == 0
}

// MARK: - Process helpers

func processAlive(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
}

// MARK: - Heartbeat (advertises this listener to hook.py)

/// Beats from a DEDICATED background queue, never the main thread: a
/// beachballing host (a synchronous AX call, a busy tick) must not stall the
/// beat, or every blocked decide hook would time out and fall back to the
/// native dialog. The write itself is a lock-free temp+rename.
final class Heartbeat {
    private let queue = DispatchQueue(label: "the-button.heartbeat", qos: .utility)
    private var timer: DispatchSourceTimer?
    private(set) var running = false

    func start() {
        stop()
        running = true
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.beat() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        running = false
    }

    /// Removing the file makes blocked hooks fall back to the native dialog
    /// within their next liveness re-check (~1s), instead of after 3s staleness.
    /// Only touches this instance's own file, so a second app/--test run is safe.
    func stopAndRemove() {
        let wasRunning = running
        stop()
        if wasRunning {
            try? FileManager.default.removeItem(at: StatePaths.heartbeat)
        }
    }

    private func beat() {
        atomicWriteJSON([
            "caps": ["decide"],
            "ts": Date().timeIntervalSince1970,
            "pid": Int(getpid()),
        ], to: StatePaths.heartbeat)
    }
}

// MARK: - Event store

final class EventStore {
    struct Snapshot {
        var permissions: [ButtonEvent] = []  // oldest-first
        var notifies: [ButtonEvent] = []     // oldest-first
        var all: [ButtonEvent] { permissions + notifies }
    }

    var debug: (String) -> Void = { _ in }
    var testEvents: [ButtonEvent]? = nil     // --test seeds; bypasses disk

    private var mtimes: [String: Date] = [:]
    private var entries: [String: ButtonEvent] = [:]
    private var arrival: [String: Int] = [:]
    private var arrivalCounter = 0
    private var handled: [String: Double] = [:]   // fileKey -> answered/dismissed ts
    private var lastJanitor = Date.distantPast

    // Legacy single-file mode (old hook.py still installed)
    private var legacyMtime: Date?
    private var legacyCurrent: ButtonEvent?
    private var legacyHandledTs: Double = 0

    // MARK: refresh

    func refresh(now: Date) -> Snapshot {
        if testEvents != nil { return snapshot(from: testEvents!.filter { !isHandled($0) }) }

        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: StatePaths.eventsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else {
            // events/ missing: the old hook.py owns the world. Fall back to
            // the original single-file behavior, verbatim.
            resetDirState()
            return legacyRefresh()
        }
        legacyCurrent = nil

        var seen = Set<String>()
        // Defensive cap for pathological dirs: newest 32 files only.
        let jsonURLs = urls.filter { $0.pathExtension == "json" }
        let capped: [URL]
        if jsonURLs.count > 32 {
            capped = jsonURLs
                .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
                .sorted { $0.1 > $1.1 }
                .prefix(32).map { $0.0 }
        } else {
            capped = jsonURLs
        }

        for url in capped {
            let name = url.lastPathComponent
            seen.insert(name)
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if mtimes[name] == mtime { continue }  // unchanged: keep cached entry
            mtimes[name] = mtime
            guard var event = loadEvent(from: url), event.type != "clear" else {
                // deleted mid-read / malformed / tombstone: drop, remember mtime
                entries.removeValue(forKey: name)
                debug("store: dropped unparsable/cleared \(name)")
                continue
            }
            event.fileKey = name
            if let old = entries[name], old.ts == event.ts {
                entries[name] = event                 // in-place update (mode flip)
            } else {
                entries[name] = event
                arrivalCounter += 1
                arrival[name] = arrivalCounter
                handled.removeValue(forKey: name)     // new ts: prior answer is stale
            }
        }

        for gone in Set(mtimes.keys).subtracting(seen) {
            mtimes.removeValue(forKey: gone)
            entries.removeValue(forKey: gone)
            arrival.removeValue(forKey: gone)
            handled.removeValue(forKey: gone)
        }

        var live: [ButtonEvent] = []
        for (name, event) in entries {
            if isHandled(event) { continue }
            if event.claudePid > 0, !processAlive(event.claudePid) {
                debug("store: claude pid \(event.claudePid) dead, dropping \(name)")
                removeFile(name)
                continue
            }
            // A decide event whose hook died (turn interrupted, hook killed)
            // is unanswerable; clean it up fast. Grace period avoids racing a
            // freshly-written file.
            if event.mode == "decide", event.hookPid > 0, !processAlive(event.hookPid),
               now.timeIntervalSince(mtimes[name] ?? now) > 2 {
                debug("store: decide hook \(event.hookPid) dead, dropping \(name)")
                removeFile(name)
                continue
            }
            live.append(event)
        }

        if now.timeIntervalSince(lastJanitor) > 60 {
            lastJanitor = now
            janitor(now: now)
        }
        return snapshot(from: live)
    }

    private func snapshot(from events: [ButtonEvent]) -> Snapshot {
        var snap = Snapshot()
        let sorted = events.sorted {
            if $0.ts != $1.ts { return $0.ts < $1.ts }
            return (arrival[$0.fileKey] ?? 0) < (arrival[$1.fileKey] ?? 0)
        }
        snap.permissions = sorted.filter { $0.type == "permission" }
        snap.notifies = sorted.filter { $0.type == "notify" }
        return snap
    }

    private func resetDirState() {
        if !entries.isEmpty || !mtimes.isEmpty {
            mtimes.removeAll(); entries.removeAll(); arrival.removeAll(); handled.removeAll()
        }
    }

    private func removeFile(_ name: String) {
        try? FileManager.default.removeItem(at: StatePaths.eventsDir.appendingPathComponent(name))
        mtimes.removeValue(forKey: name)
        entries.removeValue(forKey: name)
        arrival.removeValue(forKey: name)
        handled.removeValue(forKey: name)
    }

    // MARK: handled bookkeeping

    func isHandled(_ event: ButtonEvent) -> Bool {
        if event.fileKey == "legacy" { return event.ts == legacyHandledTs }
        return handled[event.fileKey] == event.ts
    }

    func markHandled(_ event: ButtonEvent) {
        if event.fileKey == "legacy" { legacyHandledTs = event.ts; legacyCurrent = nil; return }
        if testEvents != nil {
            handled[event.fileKey] = event.ts
            return
        }
        handled[event.fileKey] = event.ts
    }

    /// The live ts for a prompt, or nil when it is gone/superseded — the
    /// "never answer a resolved prompt" re-check.
    func currentTs(forFile fileKey: String) -> Double? {
        if fileKey == "legacy" {
            guard let cur = legacyCurrent, cur.ts != legacyHandledTs else { return nil }
            return cur.ts
        }
        if let tests = testEvents {
            guard let ev = tests.first(where: { $0.fileKey == fileKey }), !isHandled(ev) else { return nil }
            return ev.ts
        }
        guard let ev = entries[fileKey], !isHandled(ev) else { return nil }
        return ev.ts
    }

    func event(forFile fileKey: String) -> ButtonEvent? {
        if fileKey == "legacy" { return legacyCurrent }
        if let tests = testEvents { return tests.first { $0.fileKey == fileKey } }
        return entries[fileKey]
    }

    // MARK: legacy single-file mode

    private func legacyRefresh() -> Snapshot {
        let path = StatePaths.legacyEvent.path
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        if let mtime, mtime != legacyMtime {
            legacyMtime = mtime
            if var event = loadEvent(from: StatePaths.legacyEvent) {
                event.fileKey = "legacy"
                debug("store(legacy): event=\(event.type) ts=\(event.ts)")
                if event.type == "clear" {
                    if shouldApplyLegacyClear(event) { legacyCurrent = nil }
                } else if event.ts == legacyHandledTs {
                    // already answered from the panel; ignore re-reads
                } else {
                    legacyCurrent = event
                }
            }
        }
        if let event = legacyCurrent, event.claudePid > 0, !processAlive(event.claudePid) {
            debug("store(legacy): claude pid \(event.claudePid) dead, dropping event")
            legacyCurrent = nil
        }
        guard let event = legacyCurrent else { return Snapshot() }
        return snapshot(from: [event])
    }

    /// A malformed clear (no session) or one from a different session must
    /// not dismiss a pending prompt (backstop for hook-side races).
    private func shouldApplyLegacyClear(_ clear: ButtonEvent) -> Bool {
        guard let cur = legacyCurrent else { return true }
        guard !clear.sessionId.isEmpty else { return false }
        return cur.sessionId.isEmpty || cur.sessionId == clear.sessionId
    }

    // MARK: janitor

    private func janitor(now: Date) {
        let fm = FileManager.default
        // Stale answers nobody consumed (hook died between write and read).
        if let urls = try? fm.contentsOfDirectory(at: StatePaths.answersDir,
                                                  includingPropertiesForKeys: [.contentModificationDateKey]) {
            for url in urls {
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? now
                if now.timeIntervalSince(mtime) > 3600 { try? fm.removeItem(at: url) }
            }
        }
        // Crashed sessions leave pending-*.json behind (SessionEnd never fired).
        if let urls = try? fm.contentsOfDirectory(at: StatePaths.stateDir,
                                                  includingPropertiesForKeys: [.contentModificationDateKey]) {
            for url in urls where url.lastPathComponent.hasPrefix("pending-") {
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? now
                if now.timeIntervalSince(mtime) > 86400 { try? fm.removeItem(at: url) }
            }
        }
    }
}

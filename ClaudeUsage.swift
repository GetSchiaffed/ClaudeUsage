import AppKit
import CommonCrypto
import Foundation

// ClaudeUsage — macOS menu bar app for monitoring Claude Code usage
//
// Data source: ~/.claude/projects/*/[sessionId].jsonl
// Lines type=="assistant" -> token usage. Lines type=="user" -> project metadata (cwd, gitBranch).
//
// Costs computed from tokens via Claude API pricing (no costUSD in logs).
// Account detection: `claude auth status` CLI -> email + orgId.
//
// Reset times: ideally from Anthropic usage API:
//   GET https://claude.ai/api/organizations/{orgId}/usage
// Returns actual resetsAt timestamps + utilization%, same as Claude Code built-in panel.
// Requires sessionKey cookie from Safari, Chrome, Brave, or Arc. Falls back to JSONL sliding-window estimate.

// MARK: - Debug Logger

private func debugLog(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(msg)\n"
    let path = "/tmp/claudeusage_debug.log"
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile(); fh.write(line.data(using: .utf8)!); fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
}

// MARK: - Data Structures

struct TokenUsage {
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    var totalTokens: Int { inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens }
}

enum Provider: String {
    case claude, codex
    /// Single-letter tag drawn in the menu bar when both providers are shown.
    var menubarTag: String { self == .claude ? "A" : "O" }
}

/// Which provider(s) the always-visible menu bar icon renders.
enum MenubarSource: String {
    case claude, codex, both
}

/// A rolling-usage window: percent consumed (0-100) + when it resets.
/// Shared by the Claude usage API and Codex's local rate-limit snapshots.
struct Bucket {
    let utilization: Double  // 0-100%
    let resetsAt: Date?      // nil when no activity in window / unknown
}

struct UsageRecord {
    let provider: Provider
    let sessionId: String
    let model: String
    let timestamp: Date
    let usage: TokenUsage
    let cost: Double
}

/// Metadata from user-type JSONL messages: cwd, gitBranch.
struct SessionMeta {
    let cwd: String
    let gitBranch: String?
    var projectName: String {
        let comps = (cwd as NSString).pathComponents
        let last2 = comps.suffix(2).joined(separator: "/")
        return last2.isEmpty ? cwd : last2
    }
}

struct AccountInfo {
    let email: String
    let subscriptionType: String
    let orgName: String?
    let orgId: String?  // used for Anthropic usage API
}

// MARK: - CostCalculator

enum CostCalculator {
    private struct Rates { let input, output, cacheCreation, cacheRead: Double }

    // Per-MTok USD rates (≤200K context). Anthropic doubles them for >200K context
    // (1M-context Opus 4.7 / Sonnet 4.x). The JSONL doesn't expose context size at
    // request time, so we use the standard tier — costs are slight under-estimates
    // for long-context turns. Rates current as of Apr 2026 (Opus 4.7, Sonnet 4.6, Haiku 4.5).
    private static func rates(for model: String) -> Rates {
        let lower = model.lowercased()
        if lower.hasPrefix("claude-opus-4") || lower.contains("opus-4") {
            // Opus 4.x (incl. 4.6, 4.7): same pricing tier.
            // Restricted to opus-4 — Opus 3 had different pricing and a future
            // Opus 5/6 will likely change tier.
            return Rates(input: 15.0, output: 75.0, cacheCreation: 18.75, cacheRead: 1.50)
        } else if lower.hasPrefix("claude-sonnet-4") || lower.contains("sonnet") {
            return Rates(input: 3.0, output: 15.0, cacheCreation: 3.75, cacheRead: 0.30)
        } else if lower.hasPrefix("claude-haiku-4") || lower.contains("haiku") {
            return Rates(input: 0.80, output: 4.0, cacheCreation: 1.00, cacheRead: 0.08)
        } else {
            return Rates(input: 3.0, output: 15.0, cacheCreation: 3.75, cacheRead: 0.30)
        }
    }

    static func cost(for usage: TokenUsage, model: String) -> Double {
        let r = rates(for: model); let M = 1_000_000.0
        return (Double(usage.inputTokens)*r.input + Double(usage.outputTokens)*r.output
              + Double(usage.cacheCreationTokens)*r.cacheCreation
              + Double(usage.cacheReadTokens)*r.cacheRead) / M
    }

    static func formatCost(_ cost: Double) -> String { String(format: "$%.2f", cost) }

    static func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count)/1_000_000) }
        if count >= 1_000     { return String(format: "%.0fk", Double(count)/1_000) }
        return "\(count)"
    }
}

// MARK: - CodexCostCalculator
//
// API-equivalent cost estimate for OpenAI Codex usage (same framing as Claude:
// not real spend on a ChatGPT subscription, just list-price value of the tokens).
// Rates per-MTok for the GPT-5 family (Codex runs on gpt-5-codex by default).
enum CodexCostCalculator {
    private struct Rates { let input, cachedInput, output: Double }

    // Standard GPT-5 API list prices (USD per 1M tokens). Cached input is 90% off.
    private static func rates(for model: String) -> Rates {
        let m = model.lowercased()
        if m.contains("nano") {
            return Rates(input: 0.05, cachedInput: 0.005, output: 0.40)
        } else if m.contains("mini") {
            return Rates(input: 0.25, cachedInput: 0.025, output: 2.00)
        } else {
            // gpt-5 / gpt-5-codex / unknown → default to gpt-5 pricing
            return Rates(input: 1.25, cachedInput: 0.125, output: 10.0)
        }
    }

    // The Codex parser maps fresh input → inputTokens, cached input → cacheReadTokens,
    // output → outputTokens, and leaves cacheCreationTokens at 0.
    static func cost(for usage: TokenUsage, model: String) -> Double {
        let r = rates(for: model); let M = 1_000_000.0
        return (Double(usage.inputTokens)*r.input
              + Double(usage.cacheReadTokens)*r.cachedInput
              + Double(usage.outputTokens)*r.output) / M
    }
}

// MARK: - UsageMath
//
// Provider-agnostic aggregation over UsageRecord arrays — shared by LogParser (Claude)
// and CodexLogParser (Codex) so date/session math lives in one place.
enum UsageMath {
    static func records(for date: Date, from all: [UsageRecord]) -> [UsageRecord] {
        let cal = Calendar.current; let start = cal.startOfDay(for: date)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
        return all.filter { $0.timestamp >= start && $0.timestamp < end }
    }

    static func recordsForCurrentMonth(from all: [UsageRecord]) -> [UsageRecord] {
        let cal = Calendar.current; let now = Date()
        let c = cal.dateComponents([.year, .month], from: now)
        guard let start = cal.date(from: c),
              let end = cal.date(byAdding: .month, value: 1, to: start) else { return [] }
        return all.filter { $0.timestamp >= start && $0.timestamp < end }
    }

    static func recentSessions(from all: [UsageRecord], count: Int, meta: [String: SessionMeta])
        -> [(sessionId: String, lastTimestamp: Date, cost: Double, projectName: String)]
    {
        var map: [String: (Date, Double)] = [:]
        for r in all {
            if let ex = map[r.sessionId] { map[r.sessionId] = (max(ex.0, r.timestamp), ex.1 + r.cost) }
            else { map[r.sessionId] = (r.timestamp, r.cost) }
        }
        return map
            .map { (sessionId: $0.key, lastTimestamp: $0.value.0, cost: $0.value.1,
                    projectName: meta[$0.key]?.projectName ?? "—") }
            .sorted { $0.lastTimestamp > $1.lastTimestamp }
            .prefix(count).map { $0 }
    }
}

// MARK: - LogParser

final class LogParser {

    private let projectsURL: URL
    private(set) var sessionMeta: [String: SessionMeta] = [:]

    init() {
        self.projectsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    func parseAll() -> [UsageRecord] {
        let fm = FileManager.default
        var records: [UsageRecord] = []
        var meta: [String: SessionMeta] = [:]
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        guard fm.fileExists(atPath: projectsURL.path) else { return records }
        guard let dirs = try? fm.contentsOfDirectory(at: projectsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return records }

        for dir in dirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                .filter({ $0.pathExtension == "jsonl" }) else { continue }
            for file in files {
                let (recs, m) = parseFile(at: file, fmt: fmt)
                records.append(contentsOf: recs)
                for (k, v) in m { meta[k] = v }
            }
        }
        sessionMeta = meta
        return records.sorted { $0.timestamp < $1.timestamp }
    }

    private func parseFile(at url: URL, fmt: ISO8601DateFormatter)
        -> ([UsageRecord], [String: SessionMeta])
    {
        guard let data = try? Data(contentsOf: url) else { return ([], [:]) }
        var records: [UsageRecord] = []
        var meta: [String: SessionMeta] = [:]
        data.withUnsafeBytes { ptr in
            var ls = ptr.startIndex
            for i in ptr.indices {
                let isNL = ptr[i] == UInt8(ascii: "\n")
                let isEnd = i == ptr.index(before: ptr.endIndex)
                if isNL || isEnd {
                    let end = isNL ? i : ptr.endIndex
                    if end > ls {
                        let d = Data(ptr[ls..<end])
                        if let r = parseAssistant(d, fmt: fmt) { records.append(r) }
                        if let (sid, m) = parseUser(d) { meta[sid] = m }
                    }
                    ls = isNL ? ptr.index(after: i) : ptr.endIndex
                }
            }
        }
        return (records, meta)
    }

    private func parseAssistant(_ data: Data, fmt: ISO8601DateFormatter) -> UsageRecord? {
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["type"] as? String) == "assistant",
              let sid = json["sessionId"] as? String,
              let ts = (json["timestamp"] as? String).flatMap({ fmt.date(from: $0) }),
              let msg = json["message"] as? [String: Any],
              let u = msg["usage"] as? [String: Any]
        else { return nil }
        let model = (msg["model"] as? String) ?? "unknown"
        let inp = (u["input_tokens"] as? Int) ?? 0
        let out = (u["output_tokens"] as? Int) ?? 0
        let cc  = (u["cache_creation_input_tokens"] as? Int) ?? 0
        let cr  = (u["cache_read_input_tokens"] as? Int) ?? 0
        guard inp + out + cc + cr > 0 else { return nil }
        let usage = TokenUsage(inputTokens: inp, outputTokens: out,
                               cacheCreationTokens: cc, cacheReadTokens: cr)
        return UsageRecord(provider: .claude, sessionId: sid, model: model, timestamp: ts,
                           usage: usage, cost: CostCalculator.cost(for: usage, model: model))
    }

    // Parses user-type messages to extract cwd/gitBranch for session display.
    private func parseUser(_ data: Data) -> (String, SessionMeta)? {
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["type"] as? String) == "user",
              let sid = json["sessionId"] as? String,
              let cwd = json["cwd"] as? String, !cwd.isEmpty
        else { return nil }
        return (sid, SessionMeta(cwd: cwd, gitBranch: json["gitBranch"] as? String))
    }

    func records(for date: Date, from all: [UsageRecord]) -> [UsageRecord] {
        UsageMath.records(for: date, from: all)
    }

    func recordsForCurrentMonth(from all: [UsageRecord]) -> [UsageRecord] {
        UsageMath.recordsForCurrentMonth(from: all)
    }

    func recentSessions(from all: [UsageRecord], count: Int)
        -> [(sessionId: String, lastTimestamp: Date, cost: Double, projectName: String)]
    {
        UsageMath.recentSessions(from: all, count: count, meta: sessionMeta)
    }
}

// MARK: - CodexLogParser
//
// Reads OpenAI Codex CLI session logs from ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
// (base dir overridable via CODEX_HOME). Unlike Claude, the rolling-window limits live IN
// the local files: each `token_count` event carries `rate_limits` with primary (≈5h) and
// secondary (≈weekly) windows. No auth / cookie / network needed.
//
// Rollout line envelope (one JSON object per line):
//   { "timestamp": "...", "type": "<kind>", "payload": { ... } }
// Kinds used here:
//   session_meta → payload.cwd, payload.git.branch
//   turn_context → payload.model
//   event_msg    → payload.type == "token_count" → payload.info (tokens) + payload.rate_limits
//
// Token usage in info.total_token_usage is cumulative per session; we diff consecutive
// totals to recover per-turn deltas, immune to events re-emitted for rate-limit-only updates.

final class CodexLogParser {

    private let baseURL: URL
    private(set) var sessionMeta: [String: SessionMeta] = [:]
    // Latest non-null rate-limit snapshot found during the most recent parseAll().
    private(set) var latestPrimary: Bucket?
    private(set) var latestSecondary: Bucket?
    private(set) var latestPlan: String?

    init() {
        let env = ProcessInfo.processInfo.environment["CODEX_HOME"]
        if let env, !env.isEmpty {
            baseURL = URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        } else {
            baseURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        }
    }

    private var sessionsURL: URL { baseURL.appendingPathComponent("sessions") }
    private var archivedURL: URL { baseURL.appendingPathComponent("archived_sessions") }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: sessionsURL.path) }

    // Date-sharded dirs (YYYY/MM/DD) for the last `days` days, across sessions + archived.
    private func recentDateDirs(days: Int, now: Date) -> [URL] {
        let cal = Calendar.current
        var dirs: [URL] = []
        for offset in 0..<days {
            guard let d = cal.date(byAdding: .day, value: -offset, to: now) else { continue }
            let rel = String(format: "%04d/%02d/%02d",
                             cal.component(.year, from: d),
                             cal.component(.month, from: d),
                             cal.component(.day, from: d))
            dirs.append(sessionsURL.appendingPathComponent(rel))
            dirs.append(archivedURL.appendingPathComponent(rel))
        }
        return dirs
    }

    /// Latest rate-limit snapshot seen while scanning, tracked by event timestamp.
    private struct RLSnapshot { let ts: Date; let primary: Bucket?; let secondary: Bucket?; let plan: String? }

    func parseAll() -> [UsageRecord] {
        latestPrimary = nil; latestSecondary = nil; latestPlan = nil; sessionMeta = [:]
        guard isInstalled else { return [] }
        let fm = FileManager.default
        let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withInternetDateTime]

        var records: [UsageRecord] = []
        var meta: [String: SessionMeta] = [:]
        var latest: RLSnapshot? = nil
        // 9 days covers Today + the 7d window with timezone margin.
        for dir in recentDateDirs(days: 9, now: Date()) {
            guard let files = try? fm.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                .filter({ $0.pathExtension == "jsonl" }) else { continue }
            for file in files {
                let (recs, m, rl) = parseFile(at: file, f1: f1, f2: f2)
                records.append(contentsOf: recs)
                for (k, v) in m { meta[k] = v }
                if let rl, latest == nil || rl.ts > latest!.ts { latest = rl }
            }
        }
        sessionMeta = meta
        if let latest { latestPrimary = latest.primary; latestSecondary = latest.secondary; latestPlan = latest.plan }
        return records.sorted { $0.timestamp < $1.timestamp }
    }

    private func parseFile(at url: URL, f1: ISO8601DateFormatter, f2: ISO8601DateFormatter)
        -> ([UsageRecord], [String: SessionMeta], RLSnapshot?)
    {
        guard let data = try? Data(contentsOf: url) else { return ([], [:], nil) }
        let sid = url.deletingPathExtension().lastPathComponent  // rollout-<id>
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? Date()

        var records: [UsageRecord] = []
        var meta: [String: SessionMeta] = [:]
        var latest: RLSnapshot? = nil
        var currentModel = "gpt-5-codex"
        var prevIn = 0, prevCached = 0, prevOut = 0

        // Build one record from a per-turn delta (fresh input excludes cached).
        func emit(dIn: Int, dCached: Int, dOut: Int, ts: Date) {
            let fresh = max(0, dIn - dCached)
            guard fresh + dCached + dOut > 0 else { return }
            let usage = TokenUsage(inputTokens: fresh, outputTokens: dOut,
                                   cacheCreationTokens: 0, cacheReadTokens: dCached)
            records.append(UsageRecord(provider: .codex, sessionId: sid, model: currentModel,
                timestamp: ts, usage: usage,
                cost: CodexCostCalculator.cost(for: usage, model: currentModel)))
        }

        func parseDate(_ s: Any?) -> Date? {
            guard let str = s as? String else { return nil }
            return f1.date(from: str) ?? f2.date(from: str)
        }

        data.withUnsafeBytes { ptr in
            var ls = ptr.startIndex
            for i in ptr.indices {
                let isNL = ptr[i] == UInt8(ascii: "\n")
                let isEnd = i == ptr.index(before: ptr.endIndex)
                if isNL || isEnd {
                    let end = isNL ? i : ptr.endIndex
                    if end > ls {
                        let d = Data(ptr[ls..<end])
                        if let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                           let type = json["type"] as? String {
                            let payload = json["payload"] as? [String: Any]
                            let ts = parseDate(json["timestamp"]) ?? mtime
                            switch type {
                            case "session_meta":
                                if let p = payload, let cwd = p["cwd"] as? String, !cwd.isEmpty {
                                    let branch = (p["git"] as? [String: Any])?["branch"] as? String
                                    meta[sid] = SessionMeta(cwd: cwd, gitBranch: branch)
                                }
                            case "turn_context":
                                if let p = payload, let model = p["model"] as? String, !model.isEmpty {
                                    currentModel = model
                                }
                            case "event_msg":
                                guard let p = payload, (p["type"] as? String) == "token_count" else { break }
                                if let info = p["info"] as? [String: Any] {
                                    if let tot = info["total_token_usage"] as? [String: Any] {
                                        // Cumulative totals → diff to per-turn delta.
                                        let tIn = (tot["input_tokens"] as? Int) ?? 0
                                        let tCached = (tot["cached_input_tokens"] as? Int) ?? 0
                                        let tOut = (tot["output_tokens"] as? Int) ?? 0
                                        if tIn < prevIn || tOut < prevOut { prevIn = 0; prevCached = 0; prevOut = 0 }
                                        emit(dIn: tIn - prevIn, dCached: max(0, tCached - prevCached),
                                             dOut: tOut - prevOut, ts: ts)
                                        prevIn = tIn; prevCached = tCached; prevOut = tOut
                                    } else if let last = info["last_token_usage"] as? [String: Any] {
                                        // Older format: per-turn deltas given directly.
                                        emit(dIn: (last["input_tokens"] as? Int) ?? 0,
                                             dCached: (last["cached_input_tokens"] as? Int) ?? 0,
                                             dOut: (last["output_tokens"] as? Int) ?? 0, ts: ts)
                                    }
                                }
                                if let rl = p["rate_limits"] as? [String: Any] {
                                    let primary = bucket(from: rl["primary"], f1: f1, f2: f2)
                                    let secondary = bucket(from: rl["secondary"], f1: f1, f2: f2)
                                    if (primary != nil || secondary != nil),
                                       latest == nil || ts > latest!.ts {
                                        latest = RLSnapshot(ts: ts, primary: primary, secondary: secondary,
                                                            plan: rl["plan_type"] as? String)
                                    }
                                }
                            default: break
                            }
                        }
                    }
                    ls = isNL ? ptr.index(after: i) : ptr.endIndex
                }
            }
        }
        return (records, meta, latest)
    }

    // Maps a Codex RateLimitWindow JSON object → Bucket.
    private func bucket(from any: Any?, f1: ISO8601DateFormatter, f2: ISO8601DateFormatter) -> Bucket? {
        guard let w = any as? [String: Any] else { return nil }
        let used = (w["used_percent"] as? Double) ?? (w["used_percent"] as? Int).map(Double.init) ?? 0
        var reset: Date? = nil
        if let secs = w["resets_at"] as? Double { reset = Date(timeIntervalSince1970: secs) }
        else if let secs = w["resets_at"] as? Int { reset = Date(timeIntervalSince1970: Double(secs)) }
        else if let s = w["resets_at"] as? String { reset = f1.date(from: s) ?? f2.date(from: s) }
        return Bucket(utilization: used, resetsAt: reset)
    }

    // MARK: aggregation (shared with Claude via UsageMath)
    func records(for date: Date, from all: [UsageRecord]) -> [UsageRecord] {
        UsageMath.records(for: date, from: all)
    }
    func recentSessions(from all: [UsageRecord], count: Int)
        -> [(sessionId: String, lastTimestamp: Date, cost: Double, projectName: String)]
    {
        UsageMath.recentSessions(from: all, count: count, meta: sessionMeta)
    }
}

// MARK: - AccountDetector

final class AccountDetector {
    private let staticCandidatePaths = [
        "/usr/local/bin/claude", "/opt/homebrew/bin/claude", "/usr/bin/claude",
        (NSHomeDirectory() as NSString).appendingPathComponent(".npm/bin/claude"),
        (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/claude"),
    ]

    // Finds the claude binary, including NVM-managed installs.
    private func resolveClaude() -> String? {
        let fm = FileManager.default
        // 1. Static known paths
        if let found = staticCandidatePaths.first(where: { fm.isExecutableFile(atPath: $0) }) {
            debugLog("resolveClaude: found at static path \(found)")
            return found
        }
        // 2. NVM: glob ~/.nvm/versions/node/*/bin/claude and return the newest version
        let nvmBase = (NSHomeDirectory() as NSString).appendingPathComponent(".nvm/versions/node")
        if let versions = try? fm.contentsOfDirectory(atPath: nvmBase) {
            let candidates = versions
                .sorted()  // lexicographic sort puts higher versions last
                .reversed()
                .map { "\(nvmBase)/\($0)/bin/claude" }
                .filter { fm.isExecutableFile(atPath: $0) }
            if let found = candidates.first {
                debugLog("resolveClaude: found via NVM at \(found)")
                return found
            }
        }
        // 3. Ask the shell (handles nvm shims, fnm, volta, etc.)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-l", "-c", "which claude"]
        proc.environment = ProcessInfo.processInfo.environment
        let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = Pipe()
        try? proc.run(); proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !out.isEmpty && fm.isExecutableFile(atPath: out) {
            debugLog("resolveClaude: found via shell at \(out)")
            return out
        }
        debugLog("resolveClaude: NOT FOUND")
        return nil
    }

    func detectSync() -> AccountInfo? {
        guard let path = resolveClaude() else {
            debugLog("detectSync: claude binary not found")
            return nil
        }
        // Resolve symlink chains fully (Homebrew can have multi-hop:
        // /opt/homebrew/bin/claude → ../Cellar/.../claude → claude.exe).
        let realPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let proc = Process()
        let binDir = (path as NSString).deletingLastPathComponent
        let nodePath = "\(binDir)/node"
        // Two install shapes today:
        //   1. JS script with `#!/usr/bin/env node` shebang (npm/NVM install)
        //   2. Bun-compiled native Mach-O binary (newer claude.exe distribution)
        // Detect by reading the first two bytes — only shebang scripts need node.
        let isShebang: Bool = {
            guard let fh = FileHandle(forReadingAtPath: realPath) else { return false }
            defer { try? fh.close() }
            return fh.readData(ofLength: 2) == Data([0x23, 0x21]) // "#!"
        }()
        if isShebang, FileManager.default.isExecutableFile(atPath: nodePath) {
            proc.executableURL = URL(fileURLWithPath: nodePath)
            proc.arguments = [path, "auth", "status"]
            debugLog("detectSync: shebang script — using node at \(nodePath)")
        } else {
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = ["auth", "status"]
            var env = proc.environment ?? ProcessInfo.processInfo.environment
            env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin") + ":\(binDir)"
            proc.environment = env
            debugLog("detectSync: native binary — running directly (\(realPath))")
        }
        let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = Pipe()
        var timedOut = false
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 10)
        timer.setEventHandler { timedOut = true; proc.terminate(); timer.cancel() }
        timer.resume()
        let startTime = Date()
        do { try proc.run(); proc.waitUntilExit(); timer.cancel() }
        catch { timer.cancel(); debugLog("detectSync: process launch error"); return nil }
        let elapsed = Date().timeIntervalSince(startTime)
        if timedOut { debugLog("detectSync: TIMED OUT after \(String(format: "%.1f", elapsed))s"); return nil }
        debugLog("detectSync: completed in \(String(format: "%.1f", elapsed))s, exit=\(proc.terminationStatus)")
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let rawOut = String(data: data, encoding: .utf8) ?? "(binary)"
        debugLog("detectSync raw output (\(data.count) bytes): \(rawOut.prefix(500))")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["loggedIn"] as? Bool) == true,
              let email = json["email"] as? String, !email.isEmpty else {
            debugLog("detectSync: JSON parse failed or not logged in")
            return nil
        }
        return AccountInfo(
            email: email,
            subscriptionType: (json["subscriptionType"] as? String) ?? "unknown",
            orgName: json["orgName"] as? String,
            orgId: json["orgId"] as? String  // needed for API call
        )
    }

    func detect(completion: @escaping (AccountInfo?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let info = self?.detectSync()
            DispatchQueue.main.async { completion(info) }
        }
    }
}

// MARK: - Browser Preference

enum BrowserPreference: String, CaseIterable {
    case auto   = "auto"
    case safari = "safari"
    case chrome = "chrome"
    case brave  = "brave"
    case arc    = "arc"

    var displayName: String {
        switch self {
        case .auto:   return "Auto (try all)"
        case .safari: return "Safari"
        case .chrome: return "Chrome"
        case .brave:  return "Brave"
        case .arc:    return "Arc"
        }
    }

    static var stored: BrowserPreference {
        BrowserPreference(rawValue: UserDefaults.standard.string(forKey: "preferredBrowser") ?? "auto") ?? .auto
    }
}

// MARK: - SessionCookieReader
//
// Reads the `sessionKey` cookie for claude.ai from Safari or Chromium-based browsers.
//
// Safari: reads binary cookies file directly (no decryption needed).
//   Path: ~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies
//
// Chrome / Brave / Arc: cookies are AES-128-CBC encrypted.
//   - Encryption key: PBKDF2(keychainPassword, "saltysalt", 1003 iterations, 16 bytes)
//   - Encrypted value starts with "v10" prefix (3 bytes), followed by ciphertext
//   - IV: 16 space characters (0x20)
//   - Keychain service name differs per browser (e.g. "Chrome Safe Storage")
//
// The browser to read from is controlled by the "preferredBrowser" UserDefaults key.
// Default is "auto" which tries Safari → Chrome → Brave → Arc in order.

final class SessionCookieReader {

    // MARK: Public entry point

    /// Last browser that successfully provided a sessionKey (used to prioritize in auto mode).
    private static var lastSuccessfulBrowser: BrowserPreference?

    func readSessionKey() -> String? {
        switch BrowserPreference.stored {
        case .auto:   return readSessionKeyAuto()
        case .safari: return readSafariSessionKey()
        case .chrome: return readChromiumSessionKey(browser: .chrome)
        case .brave:  return readChromiumSessionKey(browser: .brave)
        case .arc:    return readChromiumSessionKey(browser: .arc)
        }
    }

    /// Auto mode: tries the last successful browser first, then all others.
    /// Each browser is attempted independently so a single failure doesn't block the rest.
    private func readSessionKeyAuto() -> String? {
        typealias Reader = () -> String?
        let all: [(BrowserPreference, Reader)] = [
            (.safari, { self.readSafariSessionKey() }),
            (.chrome, { self.readChromiumSessionKey(browser: .chrome) }),
            (.brave,  { self.readChromiumSessionKey(browser: .brave) }),
            (.arc,    { self.readChromiumSessionKey(browser: .arc) }),
        ]
        // Prioritize last successful browser
        var ordered = all
        if let last = Self.lastSuccessfulBrowser,
           let idx = ordered.firstIndex(where: { $0.0 == last }) {
            let entry = ordered.remove(at: idx)
            ordered.insert(entry, at: 0)
        }
        for (browser, reader) in ordered {
            if let key = reader(), !key.isEmpty {
                Self.lastSuccessfulBrowser = browser
                return key
            }
        }
        return nil
    }

    // MARK: Safari (binary cookies, plaintext)

    private let safariPath = NSHomeDirectory() +
        "/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"

    private func readSafariSessionKey() -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: safariPath)),
              data.count > 8,
              data[0..<4].elementsEqual([0x63, 0x6F, 0x6F, 0x6B]) else { return nil } // "cook"
        let pageCount = Int(data.readBE32(at: 4))
        guard pageCount > 0, data.count > 8 + pageCount*4 else { return nil }
        var sizes = [Int]()
        for i in 0..<pageCount { sizes.append(Int(data.readBE32(at: 8 + i*4))) }
        var off = 8 + pageCount*4
        for sz in sizes {
            guard off + sz <= data.count else { break }
            if let v = parseSafariPage(data[off..<(off+sz)], domain: "claude.ai", name: "sessionKey") { return v }
            off += sz
        }
        return nil
    }

    private func parseSafariPage(_ page: Data, domain: String, name: String) -> String? {
        guard page.count > 8 else { return nil }
        let base = page.startIndex
        let count = Int(page.readLE32(at: base + 4))
        guard count > 0, page.count > 8 + count*4 else { return nil }
        for i in 0..<count {
            let co = Int(page.readLE32(at: base + 8 + i*4)); let cb = base + co
            guard cb + 44 <= page.endIndex else { continue }
            let csz = Int(page.readLE32(at: cb))
            guard cb + csz <= page.endIndex else { continue }
            let domOff = Int(page.readLE32(at: cb + 16))
            let namOff = Int(page.readLE32(at: cb + 20))
            let valOff = Int(page.readLE32(at: cb + 28))
            guard let d = safariCStr(page, at: cb + domOff),
                  let n = safariCStr(page, at: cb + namOff),
                  d.contains(domain), n == name else { continue }
            return safariCStr(page, at: cb + valOff)
        }
        return nil
    }

    private func safariCStr(_ data: Data, at offset: Int) -> String? {
        guard offset >= data.startIndex, offset < data.endIndex else { return nil }
        var end = offset
        while end < data.endIndex && data[end] != 0 { end += 1 }
        return String(bytes: data[offset..<end], encoding: .utf8)
    }

    // MARK: Chromium-based browsers (AES-128-CBC encrypted)

    enum ChromiumBrowser {
        case chrome, brave, arc
        var userDataDir: String {
            let home = NSHomeDirectory()
            switch self {
            case .chrome: return "\(home)/Library/Application Support/Google/Chrome"
            case .brave:  return "\(home)/Library/Application Support/BraveSoftware/Brave-Browser"
            case .arc:    return "\(home)/Library/Application Support/Arc/User Data"
            }
        }
        // Returns all Cookies paths found across Default + Profile N directories.
        var cookiesPaths: [String] {
            let base = userDataDir
            let fm = FileManager.default
            var paths: [String] = []
            // Always try Default first
            let def = "\(base)/Default/Cookies"
            if fm.fileExists(atPath: def) { paths.append(def) }
            // Scan for Profile 1, Profile 2, … up to Profile 20
            if let entries = try? fm.contentsOfDirectory(atPath: base) {
                let profiles = entries.filter { $0.hasPrefix("Profile ") }.sorted()
                for p in profiles {
                    let path = "\(base)/\(p)/Cookies"
                    if fm.fileExists(atPath: path) { paths.append(path) }
                }
            }
            return paths
        }
        var keychainService: String {
            switch self {
            case .chrome: return "Chrome Safe Storage"
            case .brave:  return "Brave Safe Storage"
            case .arc:    return "Arc Safe Storage"
            }
        }
        var keychainAccount: String {
            switch self {
            case .chrome: return "Chrome"
            case .brave:  return "Brave"
            case .arc:    return "Arc"
            }
        }
    }

    private func readChromiumSessionKey(browser: ChromiumBrowser) -> String? {
        let paths = browser.cookiesPaths
        guard !paths.isEmpty else { return nil }

        // Fetch decryption key from macOS Keychain (browser stores it there on first run)
        guard let keychainPassword = readKeychain(service: browser.keychainService,
                                                   account: browser.keychainAccount) else { return nil }
        guard let key = pbkdf2Key(password: keychainPassword) else { return nil }

        // Try each profile directory in order until we find a valid sessionKey
        for dbPath in paths {
            // Copy DB to /tmp since the browser may hold a read lock
            let tmpPath = "/tmp/cu_cookies_\(arc4random()).db"
            do { try FileManager.default.copyItem(atPath: dbPath, toPath: tmpPath) }
            catch { continue }
            defer { try? FileManager.default.removeItem(atPath: tmpPath) }

            // Query encrypted_value via sqlite3 CLI — returns X'hexhex' format
            guard let hexStr = querySQLite(dbPath: tmpPath,
                sql: "SELECT quote(encrypted_value) FROM cookies WHERE host_key LIKE '%claude.ai%' AND name='sessionKey' LIMIT 1"),
                  hexStr.hasPrefix("X'"), hexStr.hasSuffix("'")
            else { continue }

            let hex = String(hexStr.dropFirst(2).dropLast(1))
            guard let encrypted = Data(hexString: hex), encrypted.count > 3 else { continue }

            // Chromium v10 cookie format: v10 (3) | nonce (16) | ciphertext (rest)
            // The 16-byte nonce is used as AES-CBC IV.
            // First 16 bytes of decrypted plaintext are a metadata header — skip them.
            guard encrypted.count > 19 else { continue }
            let nonce      = encrypted[3..<19]
            let ciphertext = encrypted[19...]
            guard let decrypted = aesDecrypt(ciphertext: Data(ciphertext), key: key,
                                             iv: Data(nonce)) else { continue }
            guard decrypted.count > 16 else { continue }
            if let result = String(bytes: decrypted.dropFirst(16), encoding: .utf8),
               !result.isEmpty { return result }
        }
        return nil
    }

    // Reads a password from macOS Keychain using the `security` CLI.
    // This avoids Security.framework complexity and works fine for background reads.
    private func readKeychain(service: String, account: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-w", "-s", service, "-a", account]
        let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = Pipe()
        var timedOut = false
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 10)
        timer.setEventHandler { timedOut = true; proc.terminate(); timer.cancel() }
        timer.resume()
        let startTime = Date()
        do { try proc.run(); proc.waitUntilExit(); timer.cancel() }
        catch { timer.cancel(); debugLog("readKeychain(\(service)): launch error"); return nil }
        let elapsed = Date().timeIntervalSince(startTime)
        if timedOut { debugLog("readKeychain(\(service)): TIMED OUT after \(String(format: "%.1f", elapsed))s"); return nil }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        debugLog("readKeychain(\(service)): \(s.isEmpty ? "EMPTY" : "ok (\(s.count) chars)") in \(String(format: "%.1f", elapsed))s")
        return s.isEmpty ? nil : s
    }

    // Queries a single value from a SQLite database using the system sqlite3 binary.
    private func querySQLite(dbPath: String, sql: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        proc.arguments = [dbPath, sql]
        let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = Pipe()
        try? proc.run(); proc.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // PBKDF2-HMAC-SHA1: same parameters Chrome uses on macOS
    //   password = from Keychain, salt = "saltysalt", iterations = 1003, keyLength = 16
    private func pbkdf2Key(password: String) -> Data? {
        let salt = Data("saltysalt".utf8)
        var derivedKey = Data(count: 16)
        let status: CCCryptorStatus = derivedKey.withUnsafeMutableBytes { keyPtr in
            salt.withUnsafeBytes { saltPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    password, password.utf8.count,
                    saltPtr.bindMemory(to: UInt8.self).baseAddress!, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1003,
                    keyPtr.bindMemory(to: UInt8.self).baseAddress!, 16
                )
            }
        }
        return status == kCCSuccess ? derivedKey : nil
    }

    // AES-128-CBC decrypt.
    // Newer Chromium (Arc, Chrome 127+): IV = nonce from cookie data.
    // Older format: IV = 16 space bytes (0x20) — not used here but kept for fallback.
    private func aesDecrypt(ciphertext: Data, key: Data,
                             iv: Data = Data(repeating: 0x20, count: 16)) -> Data? {
        let outLen = ciphertext.count + kCCBlockSizeAES128
        var outBuf = [UInt8](repeating: 0, count: outLen)
        var decryptedLen = 0
        let status: CCCryptorStatus = ciphertext.withUnsafeBytes { inPtr in
            key.withUnsafeBytes { keyPtr in
                iv.withUnsafeBytes { ivPtr in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES128),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyPtr.baseAddress!, kCCKeySizeAES128,
                        ivPtr.baseAddress!,
                        inPtr.baseAddress!, ciphertext.count,
                        &outBuf, outLen,
                        &decryptedLen
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(outBuf.prefix(decryptedLen))
    }
}

private extension Data {
    init?(hexString hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let byte = UInt8(hex[i..<j], radix: 16) else { return nil }
            data.append(byte); i = j
        }
        self = data
    }
}

private extension Data {
    func readBE32(at i: Int) -> UInt32 {
        guard i + 4 <= count else { return 0 }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i, as: UInt32.self).bigEndian }
    }
    func readLE32(at i: Int) -> UInt32 {
        guard i + 4 <= count else { return 0 }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i, as: UInt32.self).littleEndian }
    }
}

// MARK: - UsageAPIClient
//
// Calls the same Anthropic usage API as Claude Code's "Account & Usage" panel.
// Returns actual resetsAt timestamps and utilization percentages.
//
// Endpoint: GET https://claude.ai/api/organizations/{orgId}/usage
// Auth:     Cookie: sessionKey=<value from Safari>

final class UsageAPIClient {

    struct Response {
        let fiveHour: Bucket?
        let sevenDay: Bucket?
        let sevenDaySonnet: Bucket?
        let sevenDayOpus: Bucket?
    }

    func fetchSync(orgId: String, sessionKey: String) -> Response? {
        guard let url = URL(string: "https://claude.ai/api/organizations/\(orgId)/usage") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        var responseData: Data?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, _ in responseData = data; sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 9)
        guard let data = responseData,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withInternetDateTime]
        func d(_ s: String?) -> Date? { guard let s else { return nil }; return f1.date(from: s) ?? f2.date(from: s) }
        func bucket(_ key: String) -> Bucket? {
            guard let dict = json[key] as? [String: Any],
                  let u = dict["utilization"] as? Double else { return nil }
            return Bucket(utilization: u, resetsAt: d(dict["resets_at"] as? String))
        }
        let resp = Response(fiveHour: bucket("five_hour"), sevenDay: bucket("seven_day"),
                            sevenDaySonnet: bucket("seven_day_sonnet"), sevenDayOpus: bucket("seven_day_opus"))
        guard resp.fiveHour != nil || resp.sevenDay != nil else { return nil }
        return resp
    }
}

// MARK: - SettingsWindowController

final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {

    private var currentEmail = "default"
    private var costField: NSTextField!
    private var renewalDayField: NSTextField!
    private var loginItemCheckbox: NSButton!
    private var browserPopup: NSPopUpButton!
    private var codexCheckbox: NSButton!
    private var menubarPopup: NSPopUpButton!
    private var onSave: (() -> Void)?

    /// Menu-bar source options, indexed to match the popup item order.
    private static let menubarOrder = ["claude", "codex", "both"]

    init(onSave: @escaping () -> Void) {
        self.onSave = onSave
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 340),
                            styleMask: [.titled, .closable, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "Claude Usage Settings"
        panel.isReleasedWhenClosed = false; panel.level = .floating
        super.init(window: panel); panel.delegate = self; buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(for email: String) {
        currentEmail = email
        let s = UserDefaults.standard.double(forKey: "planCost_\(email)")
        costField?.stringValue = s > 0 ? String(format: "%.2f", s) : "20.00"
        let rd = UserDefaults.standard.integer(forKey: "billingDay_\(email)")
        renewalDayField?.stringValue = rd > 0 ? "\(rd)" : "1"
        loginItemCheckbox?.state = loadLaunchAtLogin() ? .on : .off
        let stored = BrowserPreference.stored.rawValue
        if let idx = BrowserPreference.allCases.firstIndex(where: { $0.rawValue == stored }) {
            browserPopup?.selectItem(at: idx)
        }
        codexCheckbox?.state = codexEnabledStored ? .on : .off
        if let idx = Self.menubarOrder.firstIndex(of: menubarSourceStored) {
            menubarPopup?.selectItem(at: idx)
        }
    }

    func showPanel() {
        window?.center(); window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildUI() {
        guard let v = window?.contentView else { return }
        let lbl1 = NSTextField(labelWithString: "Monthly plan cost (USD):")
        lbl1.frame = NSRect(x: 20, y: 300, width: 180, height: 20); v.addSubview(lbl1)
        costField = NSTextField(frame: NSRect(x: 205, y: 297, width: 80, height: 24))
        costField.placeholderString = "20.00"; costField.stringValue = "20.00"
        costField.delegate = self; v.addSubview(costField)
        let lbl2 = NSTextField(labelWithString: "Billing renewal day (1–31):")
        lbl2.frame = NSRect(x: 20, y: 262, width: 180, height: 20); v.addSubview(lbl2)
        renewalDayField = NSTextField(frame: NSRect(x: 205, y: 259, width: 80, height: 24))
        renewalDayField.placeholderString = "1"; renewalDayField.stringValue = "1"
        renewalDayField.delegate = self; v.addSubview(renewalDayField)
        loginItemCheckbox = NSButton(checkboxWithTitle: "Launch at login",
                                     target: self, action: #selector(launchAtLoginToggled))
        loginItemCheckbox.frame = NSRect(x: 20, y: 226, width: 200, height: 20)
        loginItemCheckbox.state = loadLaunchAtLogin() ? .on : .off; v.addSubview(loginItemCheckbox)
        let lbl3 = NSTextField(labelWithString: "Session cookie source:")
        lbl3.frame = NSRect(x: 20, y: 190, width: 160, height: 20); v.addSubview(lbl3)
        browserPopup = NSPopUpButton(frame: NSRect(x: 185, y: 186, width: 115, height: 26))
        for pref in BrowserPreference.allCases { browserPopup.addItem(withTitle: pref.displayName) }
        let stored = BrowserPreference.stored.rawValue
        if let idx = BrowserPreference.allCases.firstIndex(where: { $0.rawValue == stored }) {
            browserPopup.selectItem(at: idx)
        }
        v.addSubview(browserPopup)
        // ── Codex ──
        codexCheckbox = NSButton(checkboxWithTitle: "Track Codex usage", target: nil, action: nil)
        codexCheckbox.frame = NSRect(x: 20, y: 152, width: 220, height: 20)
        codexCheckbox.state = codexEnabledStored ? .on : .off; v.addSubview(codexCheckbox)
        let lbl4 = NSTextField(labelWithString: "Menu bar shows:")
        lbl4.frame = NSRect(x: 20, y: 116, width: 160, height: 20); v.addSubview(lbl4)
        menubarPopup = NSPopUpButton(frame: NSRect(x: 185, y: 112, width: 115, height: 26))
        for opt in ["Claude", "Codex", "Both"] { menubarPopup.addItem(withTitle: opt) }
        if let idx = Self.menubarOrder.firstIndex(of: menubarSourceStored) {
            menubarPopup.selectItem(at: idx)
        }
        v.addSubview(menubarPopup)
        let note = NSTextField(labelWithString: "Costs shown are API-equivalent estimates.")
        note.frame = NSRect(x: 20, y: 78, width: 280, height: 20)
        note.font = NSFont.systemFont(ofSize: 10); note.textColor = .secondaryLabelColor
        v.addSubview(note)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelAction))
        cancel.frame = NSRect(x: 155, y: 15, width: 70, height: 28); cancel.bezelStyle = .rounded
        v.addSubview(cancel)
        let save = NSButton(title: "Save", target: self, action: #selector(saveAction))
        save.frame = NSRect(x: 232, y: 15, width: 70, height: 28); save.bezelStyle = .rounded
        save.keyEquivalent = "\r"; v.addSubview(save)
    }

    // Global (not per-email) Codex settings, with defaults matching StatusBarController.
    private var codexEnabledStored: Bool {
        UserDefaults.standard.object(forKey: "codexEnabled") == nil
            ? true : UserDefaults.standard.bool(forKey: "codexEnabled")
    }
    private var menubarSourceStored: String {
        UserDefaults.standard.string(forKey: "menubarSource") ?? "both"
    }

    @objc private func saveAction() {
        let val = Double(costField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 20.0
        UserDefaults.standard.set(max(0, val), forKey: "planCost_\(currentEmail)")
        let rd = min(max(Int(renewalDayField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 1, 1), 31)
        UserDefaults.standard.set(rd, forKey: "billingDay_\(currentEmail)")
        let selIdx = browserPopup.indexOfSelectedItem
        if selIdx >= 0 && selIdx < BrowserPreference.allCases.count {
            UserDefaults.standard.set(BrowserPreference.allCases[selIdx].rawValue, forKey: "preferredBrowser")
        }
        UserDefaults.standard.set(codexCheckbox.state == .on, forKey: "codexEnabled")
        let mi = menubarPopup.indexOfSelectedItem
        if mi >= 0 && mi < Self.menubarOrder.count {
            UserDefaults.standard.set(Self.menubarOrder[mi], forKey: "menubarSource")
        }
        window?.orderOut(nil); onSave?()
    }
    @objc private func cancelAction() { window?.orderOut(nil) }
    @objc private func launchAtLoginToggled() { setLaunchAtLogin(loginItemCheckbox.state == .on) }
    func windowWillClose(_ notification: Notification) {}

    private var launchAgentPlistPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents/com.claudeusage.app.plist")
    }
    private func loadLaunchAtLogin() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentPlistPath)
    }
    private func setLaunchAtLogin(_ enabled: Bool) {
        let path = launchAgentPlistPath; let url = URL(fileURLWithPath: path)
        if enabled {
            let binary = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
            let plist: [String: Any] = ["Label": "com.claudeusage.app", "Program": binary,
                "RunAtLoad": true, "KeepAlive": false,
                "StartupDelay": 30,
                "StandardOutPath": "/tmp/claudeusage.log",
                "StandardErrorPath": "/tmp/claudeusage.err"]
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist,
                format: .xml, options: 0) {
                try? data.write(to: url, options: .atomic); launchctl(["load", path])
            } else { loginItemCheckbox.state = .off }
        } else { launchctl(["unload", path]); try? FileManager.default.removeItem(at: url) }
        UserDefaults.standard.set(enabled, forKey: "launchAtLogin")
    }
    private func launchctl(_ args: [String]) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args; p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
    }
}

// MARK: - StatusBarController

final class StatusBarController {

    private let statusItem: NSStatusItem
    private var refreshTimer: Timer?
    private var startupRetryTimer: Timer?
    private var startupRetryCount = 0
    private static let maxStartupRetries = 20 // 20 × 15s = 5 min
    private var allRecords: [UsageRecord] = []
    private var currentAccount: AccountInfo?
    private var liveUsage: UsageAPIClient.Response?
    private var isLoading = true
    private let parser = LogParser()
    private let accountDetector = AccountDetector()
    private let cookieReader = SessionCookieReader()
    private let usageAPI = UsageAPIClient()
    private var settingsWindowController: SettingsWindowController?

    // Codex (OpenAI) — all data is local; no account/API/cookie needed.
    private let codexParser = CodexLogParser()
    private var codexRecords: [UsageRecord] = []
    private var codexPrimary: Bucket?
    private var codexSecondary: Bucket?
    private var codexPlan: String?
    private var codexInstalled = false

    private var isDarkMenu: Bool {
        get { UserDefaults.standard.object(forKey: "darkMenu") == nil
              ? true : UserDefaults.standard.bool(forKey: "darkMenu") }
        set { UserDefaults.standard.set(newValue, forKey: "darkMenu") }
    }

    /// Whether to track OpenAI Codex usage alongside Claude (default on).
    private var codexEnabled: Bool {
        UserDefaults.standard.object(forKey: "codexEnabled") == nil
            ? true : UserDefaults.standard.bool(forKey: "codexEnabled")
    }

    /// Which provider(s) the menu bar icon shows (default both).
    private var menubarSource: MenubarSource {
        MenubarSource(rawValue: UserDefaults.standard.string(forKey: "menubarSource") ?? "both") ?? .both
    }

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.attributedTitle = NSAttributedString(string: "$--.--", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)])
        }
    }

    func start() {
        // Re-run a full refresh on save so toggling Codex / menu-bar source takes effect now.
        settingsWindowController = SettingsWindowController { [weak self] in self?.refresh() }
        refresh()
        refreshTimer = Timer.scheduledTimer(timeInterval: 60, target: self,
                                            selector: #selector(refresh), userInfo: nil, repeats: true)
        // At startup the Keychain/browser may not be ready yet — retry every 15s until we get API data.
        startupRetryTimer = Timer.scheduledTimer(timeInterval: 15, target: self,
                                                 selector: #selector(startupRetry), userInfo: nil, repeats: true)
    }

    @objc private func startupRetry() {
        startupRetryCount += 1
        if liveUsage != nil || startupRetryCount >= Self.maxStartupRetries {
            startupRetryTimer?.invalidate()
            startupRetryTimer = nil
            return
        }
        refresh()
    }

    /// Number of consecutive API failures — used to keep the last good response visible.
    private var apiFailCount = 0
    private static let maxStaleRetries = 3

    @objc func refresh() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            debugLog("--- refresh START ---")
            let records = self.parser.parseAll()
            debugLog("records: \(records.count)")
            let account = self.accountDetector.detectSync()
            debugLog("account: \(account?.email ?? "nil"), orgId: \(account?.orgId ?? "nil")")
            var live: UsageAPIClient.Response? = nil
            let key = self.cookieReader.readSessionKey()
            debugLog("sessionKey: \(key != nil ? "found (\(key!.prefix(8))...)" : "nil"), browser pref: \(BrowserPreference.stored.rawValue)")
            if let orgId = account?.orgId, let key {
                live = self.usageAPI.fetchSync(orgId: orgId, sessionKey: key)
                debugLog("API response: \(live != nil ? "OK (5h: \(live!.fiveHour?.utilization ?? -1)%)" : "nil")")
            } else {
                debugLog("SKIPPED API call — orgId or sessionKey missing")
            }

            // Codex — pure local file reads (no network). Rolling windows come from the
            // latest non-null rate_limits snapshot in the session logs.
            var codexRecs: [UsageRecord] = []
            var cPrimary: Bucket? = nil, cSecondary: Bucket? = nil, cPlan: String? = nil
            var cInstalled = false
            if self.codexEnabled {
                codexRecs = self.codexParser.parseAll()
                cPrimary = self.codexParser.latestPrimary
                cSecondary = self.codexParser.latestSecondary
                cPlan = self.codexParser.latestPlan
                cInstalled = self.codexParser.isInstalled
                debugLog("codex: installed=\(cInstalled), records=\(codexRecs.count), 5h=\(cPrimary?.utilization ?? -1)%, 7d=\(cSecondary?.utilization ?? -1)%")
            }

            DispatchQueue.main.async {
                self.allRecords = records; self.currentAccount = account
                self.codexRecords = codexRecs
                self.codexPrimary = cPrimary; self.codexSecondary = cSecondary
                self.codexPlan = cPlan; self.codexInstalled = cInstalled
                if let live {
                    self.liveUsage = live
                    self.apiFailCount = 0
                } else if self.liveUsage != nil {
                    // Keep stale data for a few cycles so intermittent failures don't blank the UI
                    self.apiFailCount += 1
                    if self.apiFailCount > StatusBarController.maxStaleRetries {
                        self.liveUsage = nil
                    }
                }
                self.isLoading = false
                if let email = account?.email {
                    UserDefaults.standard.set(email, forKey: "lastKnownEmail")
                }
                self.rebuildMenu()
            }
        }
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        let now = Date()
        updateTitle()
        menu.appearance = NSAppearance(named: isDarkMenu ? .darkAqua : .aqua)

        let hasCodex = codexInstalled && codexEnabled
        // Hide the Claude block only for a Codex-only user (logged out + no Claude logs).
        let showClaude = currentAccount != nil || !allRecords.isEmpty || !hasCodex
        if showClaude { buildClaudeSections(menu, now: now) }
        if hasCodex { buildCodexSections(menu, now: now) }

        // ── Actions ────────────────────────────────────────────────────────────
        let sw = NSMenuItem(title: "Switch Account", action: #selector(switchAccount), keyEquivalent: "")
        sw.target = self; menu.addItem(sw)

        let dm = NSMenuItem(title: isDarkMenu ? "Dark Mode" : "Light Mode",
                            action: #selector(toggleTheme), keyEquivalent: "")
        dm.target = self; dm.state = .on; menu.addItem(dm)

        let se = NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ",")
        se.target = self; menu.addItem(se)
        let re = NSMenuItem(title: "Refresh", action: #selector(refreshAction), keyEquivalent: "r")
        re.target = self; menu.addItem(re)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    // MARK: - Provider sections

    private func buildClaudeSections(_ menu: NSMenu, now: Date) {
        let todayRecs = parser.records(for: now, from: allRecords)
        let todayCost = todayRecs.reduce(0.0) { $0 + $1.cost }
        let todayInFresh = todayRecs.reduce(0) { $0 + $1.usage.inputTokens }
        let todayCacheR  = todayRecs.reduce(0) { $0 + $1.usage.cacheReadTokens }
        let todayCacheW  = todayRecs.reduce(0) { $0 + $1.usage.cacheCreationTokens }
        let todayOut     = todayRecs.reduce(0) { $0 + $1.usage.outputTokens }
        // Total ↓ includes all input-side tokens (fresh + cache read + cache write)
        // so the breakdown caption underneath sums to the displayed total.
        let todayIn      = todayInFresh + todayCacheR + todayCacheW

        // ── Account ──────────────────────────────────────────────────────────
        if let a = currentAccount {
            let sub = a.subscriptionType == "unknown" ? "" : "  \(a.subscriptionType)"
            addHeader(menu, "\u{25CF}  \(a.email)\(sub)")
        } else {
            addHeader(menu, "\u{25CB}  Not logged in")
        }
        let src = liveUsage != nil ? "Live from API" : "Estimated from logs"
        addCaption(menu, "This Mac only  \u{00B7}  \(src)")
        menu.addItem(.separator())

        // ── Today ─────────────────────────────────────────────────────────────
        let df = DateFormatter(); df.dateFormat = "EEEE, d MMM"
        addHeader(menu, "Today  \u{00B7}  \(df.string(from: now))")
        addMono(menu, "\u{2193} \(CostCalculator.formatTokens(todayIn))  \u{2191} \(CostCalculator.formatTokens(todayOut))   \u{2022}   \(CostCalculator.formatCost(todayCost))")
        // Breakdown: fresh input (billed full price) vs cache read (90% off) vs cache write (+25%)
        addCaption(menu, "in: \(CostCalculator.formatTokens(todayInFresh)) fresh  \u{00B7}  \(CostCalculator.formatTokens(todayCacheR)) cache↺  \u{00B7}  \(CostCalculator.formatTokens(todayCacheW)) cache✎")
        menu.addItem(.separator())

        // ── Usage Windows ─────────────────────────────────────────────────────
        windowRow(menu, label: "Session (5h)",   secs: 5*3600,    bucket: liveUsage?.fiveHour,       fallbackResetAt: nil, now: now, records: allRecords)
        windowRow(menu, label: "Weekly (7d)",    secs: 7*24*3600, bucket: liveUsage?.sevenDay,        fallbackResetAt: nil, now: now, records: allRecords)
        if let sonnet = liveUsage?.sevenDaySonnet {
            // Use sevenDay reset time as fallback when sonnet has no activity (resets_at: null)
            let fallback = liveUsage?.sevenDay?.resetsAt
            windowRow(menu, label: "Sonnet (7d)", secs: 7*24*3600, bucket: sonnet, fallbackResetAt: fallback, now: now, records: allRecords)
        }
        menu.addItem(.separator())

        // ── Plan ──────────────────────────────────────────────────────────────
        let email = currentAccount?.email ?? UserDefaults.standard.string(forKey: "lastKnownEmail") ?? "default"
        let (pl1, pl2) = planLines(email: email)
        addBody(menu, pl1)
        addCaption(menu, pl2)
        menu.addItem(.separator())

        // ── Recent Sessions (submenu) ─────────────────────────────────────────
        menu.addItem(recentSessionsItem(sessions: parser.recentSessions(from: allRecords, count: 10)))
        menu.addItem(.separator())
    }

    private func buildCodexSections(_ menu: NSMenu, now: Date) {
        let todayRecs = codexParser.records(for: now, from: codexRecords)
        let inFresh = todayRecs.reduce(0) { $0 + $1.usage.inputTokens }
        let cacheR  = todayRecs.reduce(0) { $0 + $1.usage.cacheReadTokens }
        let out     = todayRecs.reduce(0) { $0 + $1.usage.outputTokens }
        let cost    = todayRecs.reduce(0.0) { $0 + $1.cost }
        let inTotal = inFresh + cacheR

        // ── Header ────────────────────────────────────────────────────────────
        let planLabel = codexPlan.map { "  \u{00B7}  \($0.capitalized)" } ?? ""
        addHeader(menu, "\u{25CF}  Codex\(planLabel)")
        addCaption(menu, "This Mac only  \u{00B7}  Local session logs")
        menu.addItem(.separator())

        // ── Today ─────────────────────────────────────────────────────────────
        let df = DateFormatter(); df.dateFormat = "EEEE, d MMM"
        addHeader(menu, "Today  \u{00B7}  \(df.string(from: now))")
        addMono(menu, "\u{2193} \(CostCalculator.formatTokens(inTotal))  \u{2191} \(CostCalculator.formatTokens(out))   \u{2022}   \(CostCalculator.formatCost(cost))")
        // Codex has no cache-write concept; only fresh vs cached input.
        addCaption(menu, "in: \(CostCalculator.formatTokens(inFresh)) fresh  \u{00B7}  \(CostCalculator.formatTokens(cacheR)) cache↺")
        menu.addItem(.separator())

        // ── Usage Windows ─────────────────────────────────────────────────────
        windowRow(menu, label: "Session (5h)", secs: 5*3600,    bucket: codexPrimary,   fallbackResetAt: nil, now: now, records: codexRecords)
        windowRow(menu, label: "Weekly (7d)",  secs: 7*24*3600, bucket: codexSecondary, fallbackResetAt: nil, now: now, records: codexRecords)
        if codexPrimary == nil && codexSecondary == nil {
            // rate_limits absent (e.g. only `codex exec` used, or older build) — windows estimated.
            addCaption(menu, "Live limits unavailable \u{00B7} estimated from logs")
        }
        menu.addItem(.separator())

        // ── Recent Sessions (submenu) ─────────────────────────────────────────
        menu.addItem(recentSessionsItem(sessions: codexParser.recentSessions(from: codexRecords, count: 10)))
        menu.addItem(.separator())
    }

    /// Builds the shared "Recent Sessions" submenu item from aggregated session rows.
    private func recentSessionsItem(
        sessions: [(sessionId: String, lastTimestamp: Date, cost: Double, projectName: String)]
    ) -> NSMenuItem {
        let sessionsItem = NSMenuItem(title: "Recent Sessions", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Recent Sessions")
        submenu.appearance = NSAppearance(named: isDarkMenu ? .darkAqua : .aqua)
        if sessions.isEmpty {
            let empty = NSMenuItem(title: "No sessions found", action: nil, keyEquivalent: "")
            empty.isEnabled = false; submenu.addItem(empty)
        } else {
            let sf = DateFormatter(); sf.dateFormat = "MMM d  HH:mm"
            for s in sessions {
                let raw = s.projectName
                let proj = raw.count > 24 ? String(raw.prefix(24)) : raw.padding(toLength: 24, withPad: " ", startingAt: 0)
                let title = "\(proj)  \(sf.string(from: s.lastTimestamp))  \(CostCalculator.formatCost(s.cost))"
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                item.attributedTitle = NSAttributedString(string: title, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.labelColor])
                submenu.addItem(item)
            }
        }
        sessionsItem.submenu = submenu
        return sessionsItem
    }

    // MARK: - Window row (compact two-line)

    private func windowRow(_ menu: NSMenu, label: String, secs: TimeInterval,
                            bucket: Bucket?, fallbackResetAt: Date?, now: Date,
                            records: [UsageRecord])
    {
        let wRecs = records.filter { $0.timestamp >= now.addingTimeInterval(-secs) }
        let tokens = wRecs.reduce(0) {
            $0 + $1.usage.inputTokens + $1.usage.outputTokens
                + $1.usage.cacheCreationTokens + $1.usage.cacheReadTokens
        }
        let cost = wRecs.reduce(0.0) { $0 + $1.cost }

        let pct: Double; let resetStr: String
        if let b = bucket {
            pct = b.utilization
            let resetDate = b.resetsAt ?? fallbackResetAt
            if let rd = resetDate {
                let rem = rd.timeIntervalSince(now)
                resetStr = rem > 0 ? fmtReset(rd, now: now) : "resetting"
            } else { resetStr = "--" }
        } else {
            pct = 0
            if let first = wRecs.first {
                let rem = first.timestamp.addingTimeInterval(secs).timeIntervalSince(now)
                resetStr = rem > 0 ? "~\(fmtDuration(rem))" : "reset"
            } else { resetStr = "reset" }
        }

        let isLive = bucket != nil
        let pctStr = isLive ? String(format: "%.0f%%", pct) : "--"
        let bar    = progressBar(pct)
        // Compact: label + pct + reset on line 1; bar + tokens on line 2
        let line1 = "\(label)   \(pctStr)   \(resetStr)"
        let line2 = "\(bar)  \(CostCalculator.formatTokens(tokens))  est. \(CostCalculator.formatCost(cost))"

        let combined = NSMutableAttributedString()
        combined.append(NSAttributedString(string: line1 + "\n",
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]))
        combined.append(NSAttributedString(string: line2, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor]))
        let item = NSMenuItem(title: line1, action: nil, keyEquivalent: "")
        item.isEnabled = false; item.attributedTitle = combined
        menu.addItem(item)
    }

    // MARK: - Helpers

    private func progressBar(_ pct: Double, width: Int = 20) -> String {
        let filled = Int(Double(width) * min(max(pct / 100.0, 0), 1.0))
        return String(repeating: "\u{2588}", count: filled)
             + String(repeating: "\u{2591}", count: width - filled)
    }

    private func fmtDuration(_ s: TimeInterval) -> String {
        let t = Int(s); let d = t/86400; let h = (t%86400)/3600; let m = (t%3600)/60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h\(m < 10 ? "0" : "")\(m)m" }
        return "\(m)m"
    }

    private func fmtReset(_ date: Date, now: Date) -> String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.day, .hour, .minute], from: now, to: date)
        let d = comps.day ?? 0; let h = comps.hour ?? 0; let m = comps.minute ?? 0
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private func compactTime(_ s: TimeInterval) -> String {
        guard s > 0 else { return "now" }
        let t = Int(s); let d = t/86400; let h = (t%86400)/3600; let m = (t%3600)/60
        if d > 0 { return "\(d)d\(h)h" }
        if h > 0 { return "\(h)h\(m < 10 ? "0" : "")\(m)m" }
        return "\(m)m"
    }

    /// Returns the anchor date (renewal day) for a given year+month, clamping to the last
    /// day of that month if the requested day doesn't exist (e.g. day=31 in April → April 30).
    private func billingAnchor(day: Int, year: Int, month: Int, cal: Calendar) -> Date? {
        var c = DateComponents(); c.year = year; c.month = month; c.day = 1
        guard let first = cal.date(from: c),
              let daysInMonth = cal.range(of: .day, in: .month, for: first)?.count else { return nil }
        c.day = min(day, daysInMonth)
        return cal.date(from: c)
    }

    private func billingPeriodStart(renewalDay: Int, now: Date) -> Date {
        let cal = Calendar.current
        let y = cal.component(.year, from: now)
        let m = cal.component(.month, from: now)
        guard let thisMonthAnchor = billingAnchor(day: renewalDay, year: y, month: m, cal: cal) else { return now }
        if now >= thisMonthAnchor { return thisMonthAnchor }
        // Anchor hasn't been reached yet this month — period started last month
        let prevM = m == 1 ? 12 : m - 1
        let prevY = m == 1 ? y - 1 : y
        return billingAnchor(day: renewalDay, year: prevY, month: prevM, cal: cal) ?? now
    }

    private func planLines(email: String) -> (String, String) {
        let stored = UserDefaults.standard.double(forKey: "planCost_\(email)")
        let plan = stored > 0 ? stored : 20.0
        let rdStored = UserDefaults.standard.integer(forKey: "billingDay_\(email)")
        let renewalDay = rdStored > 0 ? rdStored : 1

        let cal = Calendar.current; let now = Date()
        let periodStart = billingPeriodStart(renewalDay: renewalDay, now: now)
        let psY = cal.component(.year, from: periodStart)
        let psM = cal.component(.month, from: periodStart)
        let nextM = psM == 12 ? 1 : psM + 1
        let nextY = psM == 12 ? psY + 1 : psY
        guard let periodEnd = billingAnchor(day: renewalDay, year: nextY, month: nextM, cal: cal) else {
            return ("--", "--")
        }

        let periodRecs = allRecords.filter { $0.timestamp >= periodStart && $0.timestamp < periodEnd }
        let mtd = periodRecs.reduce(0.0) { $0 + $1.cost }

        // Days elapsed = start-of-today minus start-of-period + 1 (count today as day 1)
        let daysElapsed = max(1, (cal.dateComponents([.day],
            from: cal.startOfDay(for: periodStart),
            to: cal.startOfDay(for: now)).day ?? 0) + 1)
        let daysTotal = max(1, cal.dateComponents([.day], from: periodStart, to: periodEnd).day ?? 30)

        let target = plan / Double(daysTotal)
        let avg = mtd / Double(daysElapsed)
        let ratio = target > 0 ? avg / target : 0.0
        let status = ratio >= 0.8 ? "on pace" : ratio >= 0.4 ? "below target" : "well below target"
        return (
            "\(CostCalculator.formatCost(avg))/day  \u{00B7}  target \(CostCalculator.formatCost(target))  \u{00B7}  \(status)",
            "MTD: \(CostCalculator.formatCost(mtd))  /  \(CostCalculator.formatCost(plan))"
        )
    }

    private func makePillImage(pct: Double, text: String, width: CGFloat = 46) -> NSImage {
        let height: CGFloat = 16
        let img = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let r = rect.insetBy(dx: 0.75, dy: 0.75)
            let corner = r.height / 2
            let track = NSBezierPath(roundedRect: r, xRadius: corner, yRadius: corner)
            NSColor.white.withAlphaComponent(0.15).setFill(); track.fill()
            NSColor.white.withAlphaComponent(0.30).setStroke()
            track.lineWidth = 0.75; track.stroke()
            NSGraphicsContext.saveGraphicsState()
            track.addClip()
            let frac = CGFloat(min(max(pct / 100.0, 0), 1.0))
            if frac > 0 {
                let fillRect = NSRect(x: r.minX, y: r.minY, width: r.width * frac, height: r.height)
                let col: NSColor = pct >= 80 ? .systemRed : pct >= 50 ? .systemOrange : .systemBlue
                col.withAlphaComponent(0.90).setFill()
                NSBezierPath(rect: fillRect).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
            shadow.shadowOffset = NSSize(width: 0, height: -0.5)
            shadow.shadowBlurRadius = 1.5
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .bold),
                .foregroundColor: NSColor.white,
                .shadow: shadow]
            let s = NSAttributedString(string: text, attributes: attrs)
            let sz = s.size()
            s.draw(at: NSPoint(x: (width - sz.width) / 2, y: (height - sz.height) / 2 + 0.5))
            return true
        }
        return img
    }

    private func makeContainerImage(fh: Bucket, sd: Bucket, now: Date) -> NSImage {
        let fhT = fh.resetsAt.map { compactTime($0.timeIntervalSince(now)) } ?? "--"
        let sdT = sd.resetsAt.map { compactTime($0.timeIntervalSince(now)) } ?? "--"

        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white]
        let dimAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55)]

        let fhTAS = NSAttributedString(string: fhT, attributes: textAttrs)
        let sdTAS = NSAttributedString(string: sdT, attributes: textAttrs)
        let dotAS = NSAttributedString(string: "·", attributes: dimAttrs)

        let pillW: CGFloat = 46, pillH: CGFloat = 16
        let padX: CGFloat = 9, gap: CGFloat = 5
        let height: CGFloat = 22

        let contentW = pillW + gap + fhTAS.size().width
                     + gap + dotAS.size().width + gap
                     + pillW + gap + sdTAS.size().width
        let totalW = padX * 2 + contentW

        // Pre-render pills before entering drawing block
        let pill1 = makePillImage(pct: fh.utilization, text: "\(Int(fh.utilization))%")
        let pill2 = makePillImage(pct: sd.utilization, text: "\(Int(sd.utilization))%")

        let img = NSImage(size: NSSize(width: totalW, height: height), flipped: false) { rect in
            // Dark rounded container background
            let bg = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 11, yRadius: 11)
            NSColor(calibratedWhite: 0.08, alpha: 0.82).setFill(); bg.fill()
            NSColor.white.withAlphaComponent(0.14).setStroke(); bg.lineWidth = 0.75; bg.stroke()

            let cy = height / 2
            var x = padX

            func drawText(_ s: NSAttributedString) {
                let sz = s.size()
                s.draw(at: NSPoint(x: x, y: cy - sz.height / 2 + 0.5))
                x += sz.width + gap
            }
            func drawPill(_ p: NSImage) {
                p.draw(in: NSRect(x: x, y: cy - pillH / 2, width: pillW, height: pillH))
                x += pillW + gap
            }

            drawPill(pill1)
            drawText(fhTAS)
            drawText(dotAS)
            drawPill(pill2)
            let sz = sdTAS.size()
            sdTAS.draw(at: NSPoint(x: x, y: cy - sz.height / 2 + 0.5))
            return true
        }
        img.isTemplate = false
        return img
    }

    /// Live 5h/7d buckets for a provider, if both are available for the menu bar.
    private func menubarBuckets(_ p: Provider) -> (Bucket, Bucket)? {
        switch p {
        case .claude:
            guard let fh = liveUsage?.fiveHour, let sd = liveUsage?.sevenDay else { return nil }
            return (fh, sd)
        case .codex:
            guard let fh = codexPrimary, let sd = codexSecondary else { return nil }
            return (fh, sd)
        }
    }

    /// Compact combined menu-bar image for ≥2 providers in ONE dark container:
    /// per provider `<tag> [5h%][7d%] <5h-reset>`, separated by a dim dot. Keeps both
    /// windows + the session "time left" at a glance without doubling the width.
    private func makeCombinedImage(_ entries: [(tag: String, fh: Bucket, sd: Bucket)], now: Date) -> NSImage {
        let pillW: CGFloat = 40, pillH: CGFloat = 16, height: CGFloat = 22
        let padX: CGFloat = 9, gTag: CGFloat = 4, gPill: CGFloat = 3, gReset: CGFloat = 5, gSep: CGFloat = 7

        let tagAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.70)]
        let dimAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55)]

        struct Cell { let tag: NSAttributedString; let pill5: NSImage; let pill7: NSImage; let reset: NSAttributedString }
        let cells: [Cell] = entries.map { e in
            Cell(tag: NSAttributedString(string: e.tag, attributes: tagAttrs),
                 pill5: makePillImage(pct: e.fh.utilization, text: "\(Int(e.fh.utilization))%", width: pillW),
                 pill7: makePillImage(pct: e.sd.utilization, text: "\(Int(e.sd.utilization))%", width: pillW),
                 reset: NSAttributedString(string: e.fh.resetsAt.map { compactTime($0.timeIntervalSince(now)) } ?? "--",
                                           attributes: dimAttrs))
        }
        let sepAS = NSAttributedString(string: "·", attributes: dimAttrs)

        var contentW: CGFloat = 0
        for (i, c) in cells.enumerated() {
            contentW += c.tag.size().width + gTag + pillW + gPill + pillW + gReset + c.reset.size().width
            if i < cells.count - 1 { contentW += gSep + sepAS.size().width + gSep }
        }
        let totalW = padX * 2 + contentW

        let img = NSImage(size: NSSize(width: totalW, height: height), flipped: false) { rect in
            let bg = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 11, yRadius: 11)
            NSColor(calibratedWhite: 0.08, alpha: 0.82).setFill(); bg.fill()
            NSColor.white.withAlphaComponent(0.14).setStroke(); bg.lineWidth = 0.75; bg.stroke()

            let cy = height / 2
            var x = padX
            func drawText(_ s: NSAttributedString, gapAfter: CGFloat) {
                let sz = s.size()
                s.draw(at: NSPoint(x: x, y: cy - sz.height / 2 + 0.5))
                x += sz.width + gapAfter
            }
            func drawPill(_ p: NSImage, gapAfter: CGFloat) {
                p.draw(in: NSRect(x: x, y: cy - pillH / 2, width: pillW, height: pillH))
                x += pillW + gapAfter
            }
            for (i, c) in cells.enumerated() {
                drawText(c.tag, gapAfter: gTag)
                drawPill(c.pill5, gapAfter: gPill)
                drawPill(c.pill7, gapAfter: gReset)
                drawText(c.reset, gapAfter: i < cells.count - 1 ? gSep : 0)
                if i < cells.count - 1 { drawText(sepAS, gapAfter: gSep) }
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    private func updateTitle() {
        guard let btn = statusItem.button else { return }
        let now = Date()

        // Which providers does the user want in the menu bar, and which have live data?
        var requested: [Provider]
        switch menubarSource {
        case .claude: requested = [.claude]
        case .codex:  requested = [.codex]
        case .both:   requested = [.claude, .codex]
        }
        // Codex can't be shown while tracking is off; never end up requesting nothing.
        if !codexEnabled { requested.removeAll { $0 == .codex } }
        if requested.isEmpty { requested = [.claude] }
        let available = isLoading ? [] : requested.filter { menubarBuckets($0) != nil }

        if available.count >= 2 {
            // Both providers: one compact combined container.
            let entries = available.compactMap { p -> (tag: String, fh: Bucket, sd: Bucket)? in
                guard let (fh, sd) = menubarBuckets(p) else { return nil }
                return (p.menubarTag, fh, sd)
            }
            btn.image = makeCombinedImage(entries, now: now)
            btn.imageScaling = .scaleNone
            btn.imagePosition = .imageOnly
            btn.title = ""
        } else if let p = available.first, let (fh, sd) = menubarBuckets(p) {
            // Single provider: full layout with both reset times.
            btn.image = makeContainerImage(fh: fh, sd: sd, now: now)
            btn.imageScaling = .scaleNone
            btn.imagePosition = .imageOnly
            btn.title = ""
        } else {
            btn.image = nil
            btn.imagePosition = .noImage
            // Text fallback: today's cost summed over the requested provider(s).
            let cost = requested.reduce(0.0) { acc, p in
                switch p {
                case .claude: return acc + parser.records(for: now, from: allRecords).reduce(0.0) { $0 + $1.cost }
                case .codex:  return acc + codexParser.records(for: now, from: codexRecords).reduce(0.0) { $0 + $1.cost }
                }
            }
            let text = isLoading ? "$--.--" : CostCalculator.formatCost(cost)
            btn.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)])
        }
    }

    // MARK: - Item constructors

    private func addHeader(_ menu: NSMenu, _ t: String) {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false
        i.attributedTitle = NSAttributedString(string: t, attributes:
            [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        menu.addItem(i)
    }
    private func addBody(_ menu: NSMenu, _ t: String) {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false
        i.attributedTitle = NSAttributedString(string: t, attributes:
            [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
        menu.addItem(i)
    }
    private func addCaption(_ menu: NSMenu, _ t: String) {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false
        i.attributedTitle = NSAttributedString(string: t, attributes:
            [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        menu.addItem(i)
    }
    private func addMono(_ menu: NSMenu, _ t: String) {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false
        i.attributedTitle = NSAttributedString(string: t, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.labelColor])
        menu.addItem(i)
    }

    @objc private func toggleTheme() { isDarkMenu.toggle(); rebuildMenu() }

    @objc private func switchAccount() {
        let script = "tell application \"Terminal\"\n  activate\n  do script \"claude auth login\"\nend tell"
        if let as_ = NSAppleScript(source: script) {
            var err: NSDictionary?; as_.executeAndReturnError(&err)
            if err != nil { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")) }
        }
    }
    @objc private func openSettings() {
        let email = currentAccount?.email ?? UserDefaults.standard.string(forKey: "lastKnownEmail") ?? "default"
        settingsWindowController?.configure(for: email); settingsWindowController?.showPanel()
    }
    @objc func refreshAction() {
        if let btn = statusItem.button {
            btn.image = nil
            btn.imagePosition = .noImage
            btn.attributedTitle = NSAttributedString(string: "$--.--", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)])
        }
        refresh()
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let c = StatusBarController(); statusBarController = c; c.start()
    }
    func applicationWillTerminate(_ notification: Notification) {}
}

// MARK: - Entry Point

// Headless diagnostic: `ClaudeUsage --codex-dump` parses the Codex logs (honoring
// CODEX_HOME) and prints a summary, then exits without launching the menu bar.
if CommandLine.arguments.contains("--codex-dump") {
    let p = CodexLogParser()
    let recs = p.parseAll()
    let now = Date()
    let today = UsageMath.records(for: now, from: recs)
    func sum(_ rs: [UsageRecord], _ kp: (TokenUsage) -> Int) -> Int { rs.reduce(0) { $0 + kp($1.usage) } }
    let f = ISO8601DateFormatter()
    print("installed: \(p.isInstalled)")
    print("records: \(recs.count)")
    print("today.fresh: \(sum(today, { $0.inputTokens }))")
    print("today.cacheRead: \(sum(today, { $0.cacheReadTokens }))")
    print("today.output: \(sum(today, { $0.outputTokens }))")
    print("today.cost: \(String(format: "%.5f", today.reduce(0.0) { $0 + $1.cost }))")
    print("plan: \(p.latestPlan ?? "nil")")
    print("primary: \(p.latestPrimary.map { "\($0.utilization)% resets=\($0.resetsAt.map { f.string(from: $0) } ?? "nil")" } ?? "nil")")
    print("secondary: \(p.latestSecondary.map { "\($0.utilization)% resets=\($0.resetsAt.map { f.string(from: $0) } ?? "nil")" } ?? "nil")")
    for s in p.recentSessions(from: recs, count: 5) {
        print("session: \(s.projectName) | \(f.string(from: s.lastTimestamp)) | $\(String(format: "%.5f", s.cost))")
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.run()

import DeckCore
import Foundation

/// Cheap checks made while a hook event is handled: is this session one of the Cursor sessions?
@MainActor
final class SessionDiscovery {
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var claudeLive: Set<String> = []
    private var codexFromIDE: [String: Bool] = [:]

    func noteLiveClaude(_ ids: Set<String>) {
        claudeLive = ids
    }

    /// Only sessions inside Cursor take part; headless runs (`claude -p`, `codex exec`) are left alone.
    func isInteractive(_ envelope: HookEnvelope) -> Bool {
        guard let id = envelope.sessionId else { return false }
        switch envelope.tool {
        case .claude:
            if !claudeLive.contains(id) {
                let registry = ClaudeRegistry.load(directory: home.appendingPathComponent(".claude/sessions"))
                claudeLive = Set(ClaudeRegistry.liveIDESessions(registry).map(\.sessionId))
            }
            return claudeLive.contains(id)
        case .codex:
            if let known = codexFromIDE[id] { return known }
            guard let path = envelope.payload["transcript_path"]?.string,
                  let line = CodexRollouts.firstLine(of: URL(fileURLWithPath: path)),
                  let thread = CodexRollouts.parseMeta(firstLine: line, file: URL(fileURLWithPath: path)) else { return false }
            codexFromIDE[id] = thread.isFromIDE
            return thread.isFromIDE
        }
    }
}

/// The periodic disk scan, off the main actor: transcripts can be many megabytes.
actor DiskScanner {
    struct Found: Sendable {
        let id: String
        let cwd: String
        let title: String?
        let busy: Bool?
        let activeAt: Date?
    }

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var transcripts: [String: URL] = [:]
    private var titles: [String: (offset: UInt64, title: String?)] = [:]
    private var codexNames: [String: String] = [:]
    private var codexIndexModified: Date?
    private var codexActivity: [String: (modified: Date, activity: (running: Bool, at: Date)?)] = [:]

    /// Open Cursor windows, one per Claude Code extension lock file.
    func cursorWindows() -> [IDEWindow] {
        IDELocks.load(directory: home.appendingPathComponent(".claude/ide")).filter { $0.ideName == "Cursor" }
    }

    func liveClaudeSessions() -> [Found] {
        ClaudeRegistry.liveIDESessions(ClaudeRegistry.load(directory: home.appendingPathComponent(".claude/sessions")))
            .map { Found(id: $0.sessionId, cwd: $0.cwd, title: claudeTitle(for: $0.sessionId), busy: $0.status == "busy",
                         activeAt: $0.activeAt) }
    }

    /// Codex threads from the Cursor plugin written to in the last two hours, in a Cursor window that is
    /// still open. Hooks are the main signal, but they only arrive on the next event, so after a restart
    /// this brings running threads back at once.
    func recentCodexThreads() -> [Found] {
        let root = home.appendingPathComponent(".codex/sessions")
        let windows = IDELocks.load(directory: home.appendingPathComponent(".claude/ide")).filter { $0.ideName == "Cursor" }
        let now = Date()
        var found: [Found] = []
        for thread in CodexRollouts.recent(sessionsRoot: root, within: 2 * 3600, now: now) {
            guard thread.isFromIDE, windows.contains(where: { $0.contains(path: thread.cwd) }),
                  let modified = try? thread.file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
            if codexActivity[thread.id]?.modified != modified {
                codexActivity[thread.id] = (modified, CodexRollouts.latestActivity(in: thread.file))
            }
            let activity = codexActivity[thread.id]?.activity
            found.append(Found(id: thread.id, cwd: thread.cwd, title: nil, busy: activity?.running,
                               activeAt: activity?.at))
        }
        return found
    }

    func codexTitles(for ids: [String]) -> [String: String] {
        let index = home.appendingPathComponent(".codex/session_index.jsonl")
        let modified = try? index.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if modified != codexIndexModified, let data = try? Data(contentsOf: index) {
            codexNames = Titles.codexThreadNames(in: data)
            codexIndexModified = modified
        }
        return codexNames.filter { ids.contains($0.key) }
    }

    /// Reads only what the transcript gained since last time.
    private func claudeTitle(for id: String) -> String? {
        guard let url = transcript(for: id), let handle = try? FileHandle(forReadingFrom: url) else { return titles[id]?.title }
        defer { try? handle.close() }
        var (offset, title) = titles[id] ?? (0, nil)
        guard let end = try? handle.seekToEnd(), end > offset else { return title }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: Int(end - offset)),
              let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return title }
        let complete = data[data.startIndex...lastNewline]
        title = Titles.claudeAITitle(in: Data(complete)) ?? title
        offset += UInt64(complete.count)
        titles[id] = (offset, title)
        return title
    }

    private func transcript(for id: String) -> URL? {
        if let known = transcripts[id] { return known }
        let projects = home.appendingPathComponent(".claude/projects")
        let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        let match = folders.lazy.map { $0.appendingPathComponent("\(id).jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        transcripts[id] = match
        return match
    }
}

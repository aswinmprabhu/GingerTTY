import Foundation

/// A single saved AI agent session (one agent tab).
struct SavedAgentSession: Codable, Equatable {
    let workingDirectory: String
    let kind: String          // "claude" or "copilot"
    let sessionID: String?
}

/// The single on-disk save slot. Overwritten each time the user saves on quit.
struct SavedAgentSessions: Codable, Equatable {
    static let currentVersion = 1

    var version: Int = currentVersion
    var savedAt: Date
    var sessions: [SavedAgentSession]
}

/// Persists and restores running Claude/Copilot agent sessions across launches.
/// There is exactly one save slot on disk.
enum AgentSessionStore {
    static var fileURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return appSupport
            .appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
            .appendingPathComponent("saved-agent-sessions.json")
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// Loads the saved sessions, or nil if none exist (or the file is empty/invalid).
    static func load() -> SavedAgentSessions? {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? makeDecoder().decode(SavedAgentSessions.self, from: data),
              !saved.sessions.isEmpty else {
            return nil
        }
        return saved
    }

    /// Overwrites the save slot with `sessions`. A no-op when `sessions` is empty.
    static func save(_ sessions: [SavedAgentSession], at date: Date = Date()) {
        guard !sessions.isEmpty else { return }
        let payload = SavedAgentSessions(savedAt: date, sessions: sessions)
        guard let data = try? makeEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Removes the save slot (after a one-shot restore or a declined restore).
    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// The shell input (including trailing newline) that resumes a saved agent session.
    /// Uses the session id when available, otherwise resumes the most recent conversation
    /// in the directory.
    static func resumeInput(for session: SavedAgentSession) -> String {
        let cli = session.kind == "copilot" ? "copilot" : "claude"

        guard let id = session.sessionID, !id.isEmpty else {
            return "\(cli) --continue\n"
        }

        switch session.kind {
        case "copilot":
            return "copilot --resume=\(id)\n"
        default:
            return "claude --resume \(id)\n"
        }
    }
}

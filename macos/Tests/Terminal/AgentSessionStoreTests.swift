import Foundation
import Testing
@testable import Ghostty

struct AgentSessionStoreTests {
    @Test
    func claudeResumeUsesSessionIDWithSpace() {
        let session = SavedAgentSession(workingDirectory: "/x", kind: "claude", sessionID: "abc123")
        #expect(AgentSessionStore.resumeInput(for: session) == "claude --resume abc123\n")
    }

    @Test
    func copilotResumeUsesSessionIDWithEquals() {
        let session = SavedAgentSession(workingDirectory: "/x", kind: "copilot", sessionID: "abc123")
        #expect(AgentSessionStore.resumeInput(for: session) == "copilot --resume=abc123\n")
    }

    @Test
    func missingOrEmptySessionIDFallsBackToContinue() {
        #expect(
            AgentSessionStore.resumeInput(
                for: SavedAgentSession(workingDirectory: "/x", kind: "claude", sessionID: nil)
            ) == "claude --continue\n"
        )
        #expect(
            AgentSessionStore.resumeInput(
                for: SavedAgentSession(workingDirectory: "/x", kind: "copilot", sessionID: "")
            ) == "copilot --continue\n"
        )
    }

    @Test
    func savedSessionsCodableRoundTrip() throws {
        let original = SavedAgentSessions(
            savedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sessions: [
                SavedAgentSession(workingDirectory: "/a", kind: "claude", sessionID: "id1"),
                SavedAgentSession(workingDirectory: "/b", kind: "copilot", sessionID: nil),
            ]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(SavedAgentSessions.self, from: encoder.encode(original))
        #expect(decoded == original)
        #expect(decoded.version == SavedAgentSessions.currentVersion)
    }
}

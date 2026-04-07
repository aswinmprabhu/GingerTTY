import AppKit
import Foundation

enum TerminalPermissionRequestDecision {
    case allow
    case deny
    case allowForSession(suggestionsJSON: String?)
}

struct TerminalPermissionRequest: Identifiable, Equatable {
    let id: String
    let terminalID: String
    let sessionID: String
    let agentID: String
    let toolName: String
    let toolInputSummary: String
    let suggestionsJSON: String?
    let responseFilePath: String
    let requestedAt: Date
    let expiresAt: Date

    var responseURL: URL {
        URL(fileURLWithPath: responseFilePath)
    }

    var isExpired: Bool {
        Date() >= expiresAt
    }

    @discardableResult
    func writeDecision(_ decision: TerminalPermissionRequestDecision) -> Bool {
        Self.writeDecisionToPath(responseFilePath, decision: decision)
    }

    @discardableResult
    static func writeDecisionToPath(
        _ path: String,
        decision: TerminalPermissionRequestDecision
    ) -> Bool {
        let url = URL(fileURLWithPath: path)
        let payload = PermissionHookResponse(decision: decision)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        do {
            let responseDirectory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: responseDirectory,
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(payload)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Hook response encoding

    private struct PermissionHookResponse: Encodable {
        let hookSpecificOutput: HookSpecificOutput

        init(decision: TerminalPermissionRequestDecision) {
            self.hookSpecificOutput = HookSpecificOutput(decision: decision)
        }
    }

    private struct HookSpecificOutput: Encodable {
        let hookEventName = "PermissionRequest"
        let decision: Decision

        init(decision: TerminalPermissionRequestDecision) {
            self.decision = Decision(decision: decision)
        }
    }

    private struct Decision: Encodable {
        let behavior: String
        let message: String?
        let updatedPermissions: [PermissionUpdateEntry]?

        init(decision: TerminalPermissionRequestDecision) {
            switch decision {
            case .allow:
                self.behavior = "allow"
                self.message = nil
                self.updatedPermissions = nil
            case .deny:
                self.behavior = "deny"
                self.message = "Permission denied from GingerTTY."
                self.updatedPermissions = nil
            case .allowForSession(let suggestionsJSON):
                self.behavior = "allow"
                self.message = nil
                self.updatedPermissions = Self.sessionScopedPermissions(
                    from: suggestionsJSON
                )
            }
        }

        /// Decode Claude Code's `permission_suggestions` and force every entry's
        /// `destination` to `"session"` so rules stay in-memory only.
        private static func sessionScopedPermissions(
            from suggestionsJSON: String?
        ) -> [PermissionUpdateEntry]? {
            guard let json = suggestionsJSON,
                  let data = json.data(using: .utf8) else {
                return nil
            }

            guard var entries = try? JSONDecoder().decode(
                [PermissionUpdateEntry].self, from: data
            ) else {
                return nil
            }

            for index in entries.indices {
                entries[index].destination = "session"
            }
            return entries.isEmpty ? nil : entries
        }
    }

    /// Minimal representation of a Claude Code permission update entry.
    /// Supports `addRules`, `addDirectories`, and other types via passthrough.
    struct PermissionUpdateEntry: Codable {
        let type: String
        var destination: String
        let rules: [PermissionRule]?
        let behavior: String?
        let directories: [String]?
        let mode: String?
    }

    struct PermissionRule: Codable {
        let toolName: String
        let ruleContent: String?
    }
}

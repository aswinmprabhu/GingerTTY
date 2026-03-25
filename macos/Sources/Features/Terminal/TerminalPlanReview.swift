import Foundation

enum TerminalPlanReviewDecision: String, Codable, Equatable {
    case approve
    case requestChanges = "request_changes"
}

struct TerminalPlanReviewComment: Identifiable, Codable, Equatable {
    let id: UUID
    let startLine: Int
    let endLine: Int
    let text: String

    init(
        id: UUID = UUID(),
        startLine: Int,
        endLine: Int,
        text: String
    ) {
        self.id = id
        self.startLine = startLine
        self.endLine = endLine
        self.text = text
    }
}

struct TerminalPlanReviewSession: Equatable {
    let terminalID: String
    let sessionID: String
    let agentID: String
    let scratchFilePath: String
    let responseFilePath: String
    let originalContent: String
}

struct TerminalPlanReviewResponseComment: Codable, Equatable {
    let startLine: Int
    let endLine: Int
    let text: String
}

struct TerminalPlanReviewResponse: Codable, Equatable {
    let decision: TerminalPlanReviewDecision
    let comments: [TerminalPlanReviewResponseComment]
    let finalFilePath: String
    let edited: Bool
}

enum TerminalPlanReviewParser {
    static func extractFirstProposedPlan(from message: String) -> String? {
        guard let start = message.range(of: "<proposed_plan>"),
              let end = message.range(of: "</proposed_plan>", range: start.upperBound..<message.endIndex) else {
            return nil
        }

        let plan = message[start.upperBound..<end.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plan.isEmpty else { return nil }
        return plan + "\n"
    }

    static func buildRequestChangesReason(from response: TerminalPlanReviewResponse) -> String {
        var lines = [
            "Plan review requested changes.",
        ]

        let sortedComments = response.comments.sorted {
            if $0.startLine == $1.startLine {
                return $0.endLine < $1.endLine
            }
            return $0.startLine < $1.startLine
        }

        if !sortedComments.isEmpty {
            lines.append("Reviewer comments:")
            for comment in sortedComments {
                let rangeLabel = comment.startLine == comment.endLine
                    ? "L\(comment.startLine)"
                    : "L\(comment.startLine)-L\(comment.endLine)"
                lines.append("- \(rangeLabel): \(comment.text)")
            }
        }

        if response.edited {
            lines.append("The reviewer directly edited the plan markdown.")
        }

        lines.append("Treat this reviewed markdown file as the source of truth: \(response.finalFilePath)")
        return lines.joined(separator: "\n")
    }
}

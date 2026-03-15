import Foundation
import Testing
@testable import Ghostty

struct TerminalTabStateTests {
    @Test
    func applyPullRequestStateRefreshesActiveReviewThread() {
        let tab = TerminalTabState()
        let staleThread = makeThread(
            id: "thread-1",
            isResolved: false,
            comments: [makeComment(id: "comment-1", body: "Original comment", createdAt: 1)]
        )
        let updatedThread = makeThread(
            id: "thread-1",
            isResolved: false,
            comments: [
                makeComment(id: "comment-1", body: "Original comment", createdAt: 1),
                makeComment(id: "comment-2", body: "Fresh reply", createdAt: 2),
            ]
        )

        tab.activeReviewThread = staleThread
        tab.applyPullRequestState(summary: nil, checks: [], threads: [updatedThread])

        #expect(tab.reviewThreads.first?.comments.count == 2)
        #expect(tab.activeReviewThread?.comments.last?.body == "Fresh reply")
    }

    @Test
    func appendOptimisticReplyUpdatesSidebarAndActiveThread() {
        let tab = TerminalTabState()
        let thread = makeThread(
            id: "thread-1",
            isResolved: false,
            comments: [makeComment(id: "comment-1", body: "Original comment", createdAt: 1)]
        )

        tab.applyPullRequestState(summary: nil, checks: [], threads: [thread])
        tab.activeReviewThread = thread
        tab.appendOptimisticReply(toThreadID: "thread-1", body: "Local reply")

        #expect(tab.reviewThreads.first?.comments.count == 2)
        #expect(tab.reviewThreads.first?.comments.last?.body == "Local reply")
        #expect(tab.activeReviewThread?.comments.last?.authorLogin == "you")
    }

    @Test
    func setReviewThreadResolvedUpdatesSidebarAndActiveThread() {
        let tab = TerminalTabState()
        let thread = makeThread(
            id: "thread-1",
            isResolved: false,
            comments: [makeComment(id: "comment-1", body: "Original comment", createdAt: 1)]
        )

        tab.applyPullRequestState(summary: nil, checks: [], threads: [thread])
        tab.activeReviewThread = thread
        tab.setReviewThreadResolved(threadID: "thread-1", isResolved: true)

        #expect(tab.reviewThreads.first?.isResolved == true)
        #expect(tab.activeReviewThread?.isResolved == true)
    }
}

private func makeThread(
    id: String,
    isResolved: Bool,
    comments: [TerminalPullRequestReviewComment]
) -> TerminalPullRequestReviewThread {
    TerminalPullRequestReviewThread(
        id: id,
        path: "Sources/App.swift",
        line: 42,
        originalLine: 42,
        startLine: 42,
        originalStartLine: 42,
        diffSide: "RIGHT",
        isResolved: isResolved,
        isOutdated: false,
        comments: comments,
        hasMoreComments: false
    )
}

private func makeComment(
    id: String,
    body: String,
    createdAt: TimeInterval
) -> TerminalPullRequestReviewComment {
    TerminalPullRequestReviewComment(
        id: id,
        body: body,
        url: URL(string: "https://github.com/linkedin-multiproduct/li-productivity-agents/pull/1")!,
        authorLogin: "reviewer",
        createdAt: Date(timeIntervalSince1970: createdAt),
        path: "Sources/App.swift",
        line: 42,
        originalLine: 42,
        startLine: 42,
        originalStartLine: 42,
        replyToID: nil
    )
}

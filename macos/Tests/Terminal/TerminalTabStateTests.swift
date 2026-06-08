import Foundation
import Testing
@testable import Ghostty

struct TerminalTabStateTests {
    @Test
    func contentTabsStartWithPersistentTerminal() {
        let tab = TerminalTabState()

        #expect(tab.contentTabs.count == 1)
        #expect(tab.contentTabs.first?.id == TerminalTabState.terminalContentTabID)
        #expect(tab.activeContentTabKind == .terminal)
    }

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

    @Test
    func openFileViewerKeepsDiffTabAndStartsLoadingFileTab() {
        let tab = TerminalTabState()
        let file = TerminalRepositoryChangeFile(
            id: "file-1",
            path: "Sources/App.swift",
            additions: 3,
            deletions: 1,
            isBinary: false,
            badges: [],
            sectionTitle: "Uncommitted"
        )

        tab.openDiffForFile(file)
        tab.setDiffRawText("diff --git a/Sources/App.swift b/Sources/App.swift", fileContent: "print(\"old\")")
        tab.openCombinedDiff(title: "All Changes")
        tab.openFileViewer(path: "Sources/App.swift")

        #expect(tab.viewerFilePath == "Sources/App.swift")
        #expect(tab.viewerLayoutMode == .editorOnly)
        #expect(tab.viewerOriginalContent == nil)
        #expect(tab.viewerFileContent == nil)
        #expect(tab.isViewerLoading == true)
        #expect(tab.isViewerSaving == false)
        #expect(tab.combinedDiffTitle == "All Changes")
        #expect(tab.contentTabs.contains { $0.id == TerminalTabState.diffContentTabID })
        #expect(tab.contentTabs.filter { $0.kind == .file }.count == 1)
        #expect(tab.activeContentTabKind == .file)
    }

    @Test
    func openingSecondDiffReusesDiffTabWithoutClosingFiles() {
        let tab = TerminalTabState()
        let first = TerminalRepositoryChangeFile(
            id: "file-1",
            path: "Sources/App.swift",
            additions: 3,
            deletions: 1,
            isBinary: false,
            badges: [],
            sectionTitle: "Uncommitted"
        )
        let second = TerminalRepositoryChangeFile(
            id: "file-2",
            path: "Sources/Other.swift",
            additions: 1,
            deletions: 0,
            isBinary: false,
            badges: [],
            sectionTitle: "Uncommitted"
        )

        tab.openFileViewer(path: "README.md")
        tab.setViewerLoadedContent("# GingerTTY\n")
        tab.openDiffForFile(first)
        tab.setDiffRawText("first")
        tab.openDiffForFile(second)

        #expect(tab.contentTabs.filter { $0.id == TerminalTabState.diffContentTabID }.count == 1)
        #expect(tab.contentTabs.filter { $0.kind == .file }.count == 1)
        #expect(tab.activeContentTabKind == .diff)
        #expect(tab.selectedDiffFile?.path == "Sources/Other.swift")
        #expect(tab.diffRawText == nil)
    }

    @Test
    func openingExistingFileFocusesExistingTabAndRestoresDraft() {
        let tab = TerminalTabState()

        tab.openFileViewer(path: "README.md")
        tab.setViewerLoadedContent("# GingerTTY\n")
        tab.setViewerDraftContent("# Edited\n")
        tab.openFileViewer(path: "Sources/App.swift")
        tab.setViewerLoadedContent("print(\"hello\")\n")
        tab.openFileViewer(path: "README.md")

        #expect(tab.contentTabs.filter { $0.kind == .file }.count == 2)
        #expect(tab.viewerFilePath == "README.md")
        #expect(tab.viewerFileContent == "# Edited\n")
        #expect(tab.isViewerDirty)
    }

    @Test
    func setViewerDraftContentMarksViewerDirty() {
        let tab = TerminalTabState()

        tab.openFileViewer(path: "Sources/App.swift")
        tab.setViewerLoadedContent("print(\"hello\")\n")

        #expect(tab.isViewerDirty == false)
        #expect(tab.canSaveViewerFile == false)
        #expect(tab.canRevertViewerFile == false)

        tab.setViewerDraftContent("print(\"edited\")\n")

        #expect(tab.viewerFileContent == "print(\"edited\")\n")
        #expect(tab.viewerOriginalContent == "print(\"hello\")\n")
        #expect(tab.isViewerDirty == true)
        #expect(tab.canSaveViewerFile == true)
        #expect(tab.canRevertViewerFile == true)
    }

    @Test
    func markdownDraftEditsStillMarkViewerDirty() {
        let tab = TerminalTabState()

        tab.openFileViewer(path: "README.md")

        #expect(tab.viewerLayoutMode == .markdownSplitPreview)
        tab.setViewerLoadedContent("# GingerTTY\n")

        #expect(tab.isViewerDirty == false)
        #expect(tab.canSaveViewerFile == false)
        #expect(tab.canRevertViewerFile == false)

        tab.setViewerDraftContent("# GingerTTY Preview\n")

        #expect(tab.viewerFileContent == "# GingerTTY Preview\n")
        #expect(tab.viewerOriginalContent == "# GingerTTY\n")
        #expect(tab.isViewerDirty == true)
        #expect(tab.canSaveViewerFile == true)
        #expect(tab.canRevertViewerFile == true)
    }

    @Test
    func completeViewerSavePromotesDraftToOriginal() {
        let tab = TerminalTabState()

        tab.openFileViewer(path: "Sources/App.swift")
        tab.setViewerLoadedContent("print(\"hello\")\n")
        tab.setViewerDraftContent("print(\"edited\")\n")
        tab.beginViewerSave()
        tab.completeViewerSave(with: "print(\"edited\")\n")

        #expect(tab.viewerOriginalContent == "print(\"edited\")\n")
        #expect(tab.viewerFileContent == "print(\"edited\")\n")
        #expect(tab.isViewerDirty == false)
        #expect(tab.isViewerSaving == false)
        #expect(tab.viewerSaveError == nil)
        #expect(tab.canSaveViewerFile == false)
    }

    @Test
    func markdownSavePromotesDraftToOriginal() {
        let tab = TerminalTabState()

        tab.openFileViewer(path: "README.md")
        tab.setViewerLoadedContent("# GingerTTY\n")
        tab.setViewerDraftContent("# GingerTTY Preview\n")
        tab.beginViewerSave()
        tab.completeViewerSave(with: "# GingerTTY Preview\n")

        #expect(tab.viewerOriginalContent == "# GingerTTY Preview\n")
        #expect(tab.viewerFileContent == "# GingerTTY Preview\n")
        #expect(tab.isViewerDirty == false)
        #expect(tab.isViewerSaving == false)
        #expect(tab.viewerSaveError == nil)
        #expect(tab.canSaveViewerFile == false)
    }

    @Test
    func closeFileViewerClearsViewerEditingState() {
        let tab = TerminalTabState()

        tab.openFileViewer(path: "Sources/App.swift")
        tab.setViewerLoadedContent("print(\"hello\")\n")
        tab.setViewerDraftContent("print(\"edited\")\n")
        tab.beginViewerSave()
        tab.setViewerSaveError("Save failed")
        tab.closeFileViewer()

        #expect(tab.viewerFilePath == nil)
        #expect(tab.viewerLayoutMode == .editorOnly)
        #expect(tab.viewerOriginalContent == nil)
        #expect(tab.viewerFileContent == nil)
        #expect(tab.isViewerLoading == false)
        #expect(tab.isViewerSaving == false)
        #expect(tab.viewerLoadError == nil)
        #expect(tab.viewerSaveError == nil)
        #expect(tab.isViewerDirty == false)
    }

    @Test
    func closeDiffClearsDiffStateAndReturnsToTerminal() {
        let tab = TerminalTabState()
        let file = TerminalRepositoryChangeFile(
            id: "file-1",
            path: "Sources/App.swift",
            additions: 3,
            deletions: 1,
            isBinary: false,
            badges: [],
            sectionTitle: "Uncommitted"
        )

        tab.openDiffForFile(file)
        tab.setDiffRawText("diff --git a/Sources/App.swift b/Sources/App.swift", fileContent: "print(\"old\")")
        tab.showCommentBox = true
        tab.pendingSelectionStart = 10
        tab.pendingSelectionEnd = 12
        tab.pendingSelectionSide = "RIGHT"
        tab.pendingCommentText = "Needs work"
        tab.activeReviewThread = makeThread(
            id: "thread-1",
            isResolved: false,
            comments: [makeComment(id: "comment-1", body: "Original comment", createdAt: 1)]
        )

        tab.closeDiff()

        #expect(tab.selectedDiffFile == nil)
        #expect(tab.diffRawText == nil)
        #expect(tab.diffFileContent == nil)
        #expect(tab.isDiffLoading == false)
        #expect(tab.showCommentBox == false)
        #expect(tab.pendingSelectionStart == nil)
        #expect(tab.pendingSelectionEnd == nil)
        #expect(tab.pendingSelectionSide == nil)
        #expect(tab.pendingCommentText.isEmpty)
        #expect(tab.activeReviewThread == nil)
        #expect(tab.viewerFilePath == nil)
        #expect(tab.combinedDiffTitle == nil)
        #expect(tab.activeContentTabKind == .terminal)
        #expect(!tab.contentTabs.contains { $0.id == TerminalTabState.diffContentTabID })
    }

    @Test
    func closeCombinedDiffClearsCombinedDiffStateAndReturnsToTerminal() {
        let tab = TerminalTabState()

        tab.openCombinedDiff(title: "All Changes")
        tab.setCombinedDiffText("diff --git a/Sources/App.swift b/Sources/App.swift")
        tab.closeCombinedDiff()

        #expect(tab.combinedDiffTitle == nil)
        #expect(tab.combinedDiffRawText == nil)
        #expect(tab.isCombinedDiffLoading == false)
        #expect(tab.selectedDiffFile == nil)
        #expect(tab.viewerFilePath == nil)
        #expect(tab.activeContentTabKind == .terminal)
        #expect(!tab.contentTabs.contains { $0.id == TerminalTabState.diffContentTabID })
    }

    @Test
    func setAgentStatusTracksLastActivityTimestamp() {
        let tab = TerminalTabState()
        let startedAt = Date(timeIntervalSince1970: 10)
        let finishedAt = Date(timeIntervalSince1970: 20)

        tab.setAgentStatus("Running", updatedAt: startedAt)
        #expect(tab.agentStatus == "Running")
        #expect(tab.lastAgentActivityAt == startedAt)

        tab.setAgentStatus("Done", updatedAt: finishedAt)
        #expect(tab.agentStatus == "Done")
        #expect(tab.lastAgentActivityAt == finishedAt)
    }

    @Test
    func setAgentStatusRunningClearsPendingPermissionRequest() {
        let tab = TerminalTabState()
        let request = makePermissionRequest(
            requestedAt: Date(timeIntervalSince1970: 10),
            expiresAt: Date(timeIntervalSince1970: 40)
        )

        tab.presentPermissionRequest(request)
        #expect(tab.pendingPermissionRequest == request)

        tab.setAgentStatus("Running", updatedAt: Date(timeIntervalSince1970: 11))
        #expect(tab.pendingPermissionRequest == nil)
    }

    @Test
    func presentPermissionRequestStoresPendingApproval() {
        let tab = TerminalTabState()
        let request = makePermissionRequest(
            requestedAt: Date(timeIntervalSince1970: 42),
            expiresAt: Date(timeIntervalSince1970: 72)
        )

        tab.setAgentStatus("Running", updatedAt: Date(timeIntervalSince1970: 21))
        tab.presentPermissionRequest(request)

        #expect(tab.pendingPermissionRequest == request)
        #expect(tab.lastAgentActivityAt == request.requestedAt)
    }

    @Test
    func clearExpiredPermissionRequestRemovesStaleApproval() {
        let tab = TerminalTabState()
        let request = makePermissionRequest(
            requestedAt: Date(timeIntervalSince1970: 10),
            expiresAt: Date(timeIntervalSince1970: 15)
        )

        tab.presentPermissionRequest(request)
        tab.clearExpiredPermissionRequest(now: Date(timeIntervalSince1970: 14))
        #expect(tab.pendingPermissionRequest == request)

        tab.clearExpiredPermissionRequest(now: Date(timeIntervalSince1970: 16))
        #expect(tab.pendingPermissionRequest == nil)
    }

    @Test
    func updateReviewCommentReplacesTrimmedBody() {
        let tab = TerminalTabState()
        let comment = TerminalLocalReviewComment(
            id: UUID(),
            filePath: "Sources/App.swift",
            startLine: 12,
            endLine: 12,
            side: "new",
            text: "Original"
        )
        tab.addReviewComment(comment)

        tab.updateReviewComment(id: comment.id, text: "  Updated body  ")

        #expect(tab.localReviewComments.count == 1)
        #expect(tab.localReviewComments.first?.text == "Updated body")

        tab.updateReviewComment(id: comment.id, text: "   ")
        #expect(tab.localReviewComments.first?.text == "Updated body")
    }

    @Test
    func clearReviewCommentsClearsSelectedReviewComment() {
        let tab = TerminalTabState()
        let comment = TerminalLocalReviewComment(
            id: UUID(),
            filePath: "Sources/App.swift",
            startLine: 40,
            endLine: 40,
            side: "new",
            text: "Needs guard"
        )
        tab.addReviewComment(comment)
        tab.selectedReviewCommentID = comment.id

        tab.clearReviewComments()

        #expect(tab.localReviewComments.isEmpty)
        #expect(tab.selectedReviewCommentID == nil)
    }

    @Test
    func externalReviewCommentsParserParsesCommentsPayload() throws {
        let payload = """
        {
          "replaceExisting": false,
          "comments": [
            {
              "path": "macos/Sources/Features/Terminal/TerminalController.swift",
              "line_start": 100,
              "line_end": 101,
              "side": "left",
              "text": "Can we avoid opening diff when path is missing?"
            }
          ]
        }
        """

        let parsed = try TerminalExternalReviewCommentsParser.parse(
            payloadJSON: payload,
            defaultReplaceExisting: true
        )

        #expect(parsed.replaceExisting == false)
        #expect(parsed.comments.count == 1)
        #expect(parsed.comments.first?.filePath == "macos/Sources/Features/Terminal/TerminalController.swift")
        #expect(parsed.comments.first?.startLine == 100)
        #expect(parsed.comments.first?.endLine == 101)
        #expect(parsed.comments.first?.side == "old")
    }

    @Test
    func externalReviewCommentsParserParsesIssuesPayload() throws {
        let payload = """
        {
          "issues": [
            {
              "severity": "high",
              "category": "functional-bug",
              "title": "Thread can be nil",
              "description": "This branch dereferences thread without checking.",
              "file": "macos/Sources/Features/Terminal/TerminalDiffView.swift",
              "line_start": 398,
              "line_end": 403,
              "suggested_fix": "Guard and return when thread is nil.",
              "confidence": 8
            }
          ]
        }
        """

        let parsed = try TerminalExternalReviewCommentsParser.parse(
            payloadJSON: payload,
            defaultReplaceExisting: true
        )

        #expect(parsed.replaceExisting == true)
        #expect(parsed.comments.count == 1)
        #expect(parsed.comments.first?.filePath == "macos/Sources/Features/Terminal/TerminalDiffView.swift")
        #expect(parsed.comments.first?.startLine == 398)
        #expect(parsed.comments.first?.endLine == 403)
        #expect(parsed.comments.first?.text.contains("Thread can be nil") == true)
        #expect(parsed.comments.first?.text.contains("Suggested fix: Guard and return when thread is nil.") == true)
    }

    @Test
    func externalReviewCommentsParserAppliesLineDefaults() throws {
        let payload = """
        {
          "comments": [
            {
              "path": "macos/Sources/Features/Terminal/TerminalSidebarView.swift",
              "text": "Can we reuse this helper?"
            }
          ]
        }
        """

        let parsed = try TerminalExternalReviewCommentsParser.parse(
            payloadJSON: payload,
            defaultReplaceExisting: true
        )

        #expect(parsed.replaceExisting == true)
        #expect(parsed.comments.count == 1)
        #expect(parsed.comments.first?.startLine == 1)
        #expect(parsed.comments.first?.endLine == 1)
        #expect(parsed.comments.first?.side == "new")
    }

    @Test
    func externalReviewCommentsParserRejectsUnsupportedPayload() {
        let payload = #"{"foo":"bar"}"#

        do {
            _ = try TerminalExternalReviewCommentsParser.parse(
                payloadJSON: payload,
                defaultReplaceExisting: true
            )
            Issue.record("Expected parser to reject unsupported payload.")
        } catch let error as TerminalExternalReviewCommentsParserError {
            #expect(error == .unsupportedPayload)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
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

private func makePermissionRequest(
    requestedAt: Date = Date(timeIntervalSince1970: 1),
    expiresAt: Date = Date(timeIntervalSince1970: 31)
) -> TerminalPermissionRequest {
    TerminalPermissionRequest(
        id: "request-1",
        terminalID: "terminal-1",
        sessionID: "session-1",
        agentID: "agent-1",
        toolName: "Bash",
        toolInputSummary: "npm test",
        suggestionsJSON: nil,
        responseFilePath: "/tmp/request-1.json",
        requestedAt: requestedAt,
        expiresAt: expiresAt
    )
}

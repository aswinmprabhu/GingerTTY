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

    @Test
    func openFileViewerClearsDiffStateAndStartsLoading() {
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
        #expect(tab.selectedDiffFile == nil)
        #expect(tab.combinedDiffTitle == nil)
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

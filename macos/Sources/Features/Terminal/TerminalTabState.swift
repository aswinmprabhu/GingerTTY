import Foundation

enum TerminalInspectorTab: String, CaseIterable, Codable, Identifiable {
    case changes
    case comments
    case checks
    case files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .changes:
            return "Changes"
        case .comments:
            return "Comments"
        case .checks:
            return "Checks"
        case .files:
            return "Files"
        }
    }
}

final class TerminalTabState: ObservableObject, Identifiable {
    let id: UUID

    // MARK: Repository identity

    @Published private(set) var workingDirectory: String?
    @Published private(set) var repositoryContext: TerminalRepositoryContext?

    var repositoryRoot: String? { repositoryContext?.repositoryRoot }
    var branchName: String? { repositoryContext?.branchName }
    var repositoryKey: TerminalRepositoryKey? { repositoryContext.map(TerminalRepositoryKey.init) }

    // MARK: Local repository state

    @Published private(set) var changeSummary: TerminalRepositoryChangeSummary?
    @Published private(set) var changeSummaryMessage: String?
    @Published private(set) var commitEntries: [TerminalCommitEntry] = []
    @Published private(set) var fileTree: FileTreeNode?
    @Published private(set) var localRepositoryLastUpdatedAt: Date?
    @Published private(set) var isLocalRepositoryRefreshing: Bool = false

    // MARK: Pull request state

    @Published private(set) var pullRequestSummary: TerminalPullRequestSummary?
    @Published private(set) var pullRequestChecks: [TerminalPullRequestCheck] = []
    @Published private(set) var reviewThreads: [TerminalPullRequestReviewThread] = []
    @Published private(set) var pullRequestMessage: String?
    @Published private(set) var pullRequestStatusMessage: String?
    @Published private(set) var pullRequestLastUpdatedAt: Date?
    @Published private(set) var isPullRequestRefreshing: Bool = false

    var hasPullRequestContent: Bool { pullRequestSummary != nil }
    var hasChangeSummary: Bool { changeSummary != nil }

    // MARK: Sidebar UI state

    @Published private(set) var rightSidebarSelection: TerminalInspectorTab
    @Published private(set) var isRightSidebarCollapsed: Bool
    @Published private(set) var rightSidebarSplit: CGFloat

    // MARK: Diff viewer state

    @Published var selectedDiffFile: TerminalRepositoryChangeFile?
    @Published var diffRows: [SplitDiffRow]?
    @Published var diffRawText: String?
    @Published var diffFileContent: String?
    @Published var isDiffLoading: Bool = false

    // MARK: Combined (multi-file) diff state

    @Published var combinedDiffTitle: String?
    @Published var combinedDiffRawText: String?
    @Published var isCombinedDiffLoading: Bool = false

    // MARK: Review comments

    @Published var localReviewComments: [TerminalLocalReviewComment] = []
    @Published var prThreadReviewComments: [TerminalLocalReviewComment] = []
    @Published var activeReviewThread: TerminalPullRequestReviewThread?

    // MARK: PR review mode

    @Published var isReviewMode: Bool = false
    @Published var reviewBodyText: String = ""
    @Published var isSubmittingReview: Bool = false
    @Published var reviewSubmitError: String?

    // MARK: Agent status (set via AppleScript by CLI wrappers)

    @Published private(set) var agentStatus: String?

    // MARK: Merge state

    @Published var mergeInProgress: Bool = false
    @Published var mergeError: String?

    // MARK: Pending comment state (driven by WKWebView line selection)

    @Published var showCommentBox: Bool = false
    @Published var pendingSelectionStart: Int?
    @Published var pendingSelectionEnd: Int?
    @Published var pendingSelectionSide: String?
    @Published var pendingCommentText: String = ""

    // MARK: File viewer state

    @Published var viewerFilePath: String?
    @Published private(set) var viewerLayoutMode: TerminalFileViewerLayoutMode = .editorOnly
    @Published var viewerOriginalContent: String?
    @Published var viewerFileContent: String?
    @Published var isViewerLoading: Bool = false
    @Published private(set) var isViewerSaving: Bool = false
    @Published private(set) var viewerLoadError: String?
    @Published private(set) var viewerSaveError: String?

    @Published var highlightedFilePath: String?

    var isViewerDirty: Bool {
        viewerFilePath != nil && viewerFileContent != viewerOriginalContent
    }

    var canSaveViewerFile: Bool {
        viewerFilePath != nil &&
            viewerFileContent != nil &&
            isViewerDirty &&
            !isViewerLoading &&
            !isViewerSaving
    }

    var canRevertViewerFile: Bool {
        viewerFilePath != nil &&
            viewerOriginalContent != nil &&
            isViewerDirty &&
            !isViewerLoading &&
            !isViewerSaving
    }

    // MARK: Init

    init(
        id: UUID = UUID(),
        workingDirectory: String? = nil
    ) {
        self.id = id
        self.workingDirectory = workingDirectory
        self.rightSidebarSelection = .changes
        self.isRightSidebarCollapsed = false
        self.rightSidebarSplit = 0.74
    }

    // MARK: Repository context

    func updateRepositoryContext(_ context: TerminalRepositoryContext?) {
        repositoryContext = context
        if let context {
            workingDirectory = context.workingDirectory
        }
    }

    func setWorkingDirectory(_ newValue: String?) {
        workingDirectory = newValue
    }

    func setAgentStatus(_ status: String?) {
        // Don't let "Need input" overwrite "Done" — a Notification event
        // often fires right after Stop just to alert the user, not because
        // the agent actually needs input.
        if status == "Need input" && agentStatus == "Done" {
            return
        }
        agentStatus = status
    }

    func resetRepositoryScopedState() {
        clearLocalRepositoryState()
        clearPullRequestState()
        clearReviewComments()
        clearPRThreadComments()
        activeReviewThread = nil
        reviewBodyText = ""
        reviewSubmitError = nil
        mergeInProgress = false
        mergeError = nil
        showCommentBox = false
        pendingSelectionStart = nil
        pendingSelectionEnd = nil
        pendingSelectionSide = nil
        pendingCommentText = ""
        closeDiff()
        closeCombinedDiff()
        closeFileViewer()
        highlightedFilePath = nil
    }

    // MARK: Local repository state

    func beginLocalRepositoryRefresh() {
        isLocalRepositoryRefreshing = true
    }

    func applyLocalRepositoryState(
        changeSummary: TerminalRepositoryChangeSummary,
        commitEntries: [TerminalCommitEntry],
        fileTree: FileTreeNode?,
        refreshedAt: Date = Date()
    ) {
        self.changeSummary = changeSummary
        self.changeSummaryMessage = nil
        self.commitEntries = commitEntries
        self.fileTree = fileTree
        self.localRepositoryLastUpdatedAt = refreshedAt
        self.isLocalRepositoryRefreshing = false

        if let highlightedFilePath,
           let fileTree,
           !fileTree.containsFile(relativePath: highlightedFilePath) {
            self.highlightedFilePath = nil
        }
    }

    func setLocalRepositoryError(_ message: String) {
        changeSummary = nil
        changeSummaryMessage = message
        commitEntries = []
        fileTree = nil
        isLocalRepositoryRefreshing = false
    }

    func clearLocalRepositoryState(message: String? = nil) {
        changeSummary = nil
        changeSummaryMessage = message
        commitEntries = []
        fileTree = nil
        localRepositoryLastUpdatedAt = nil
        isLocalRepositoryRefreshing = false
    }

    // MARK: Pull request state

    func beginPullRequestRefresh() {
        isPullRequestRefreshing = true
    }

    func applyPullRequestState(
        summary: TerminalPullRequestSummary?,
        checks: [TerminalPullRequestCheck],
        threads: [TerminalPullRequestReviewThread],
        message: String? = nil,
        statusMessage: String? = nil,
        refreshedAt: Date = Date()
    ) {
        pullRequestSummary = summary
        pullRequestChecks = checks
        reviewThreads = threads
        pullRequestMessage = message
        pullRequestStatusMessage = statusMessage
        pullRequestLastUpdatedAt = refreshedAt
        isPullRequestRefreshing = false

        if let activeThreadID = activeReviewThread?.id {
            activeReviewThread = threads.first { $0.id == activeThreadID }
        }
    }

    func setPullRequestError(
        message: String,
        preserveExistingData: Bool = false,
        statusMessage: String? = nil
    ) {
        if !preserveExistingData {
            pullRequestSummary = nil
            pullRequestChecks = []
            reviewThreads = []
        }
        pullRequestMessage = message
        pullRequestStatusMessage = statusMessage
        isPullRequestRefreshing = false
    }

    func clearPullRequestState(message: String? = nil) {
        pullRequestSummary = nil
        pullRequestChecks = []
        reviewThreads = []
        pullRequestMessage = message
        pullRequestStatusMessage = nil
        pullRequestLastUpdatedAt = nil
        isPullRequestRefreshing = false
    }

    // MARK: Sidebar UI

    func setRightSidebarSelection(_ newValue: TerminalInspectorTab) {
        rightSidebarSelection = newValue
    }

    func setRightSidebarCollapsed(_ newValue: Bool) {
        isRightSidebarCollapsed = newValue
    }

    func setRightSidebarSplit(_ newValue: CGFloat) {
        rightSidebarSplit = min(max(newValue, 0.2), 0.95)
    }

    // MARK: Diff viewer

    func openDiffForFile(_ file: TerminalRepositoryChangeFile) {
        selectedDiffFile = file
        diffRows = nil
        diffRawText = nil
        diffFileContent = nil
        isDiffLoading = true
        combinedDiffTitle = nil
        combinedDiffRawText = nil
        isCombinedDiffLoading = false
        viewerFilePath = nil
        viewerLayoutMode = .editorOnly
        viewerOriginalContent = nil
        viewerFileContent = nil
        isViewerLoading = false
        isViewerSaving = false
        viewerLoadError = nil
        viewerSaveError = nil
    }

    func setDiffRows(_ rows: [SplitDiffRow]) {
        diffRows = rows
        isDiffLoading = false
    }

    func setDiffRawText(_ text: String, fileContent: String? = nil) {
        diffRawText = text
        diffFileContent = fileContent
        isDiffLoading = false
    }

    func closeDiff() {
        selectedDiffFile = nil
        diffRows = nil
        diffRawText = nil
        diffFileContent = nil
        isDiffLoading = false
        showCommentBox = false
        pendingCommentText = ""
        pendingSelectionStart = nil
        pendingSelectionEnd = nil
        pendingSelectionSide = nil
        activeReviewThread = nil
    }

    // MARK: File viewer

    func openFileViewer(path: String) {
        viewerFilePath = path
        viewerLayoutMode = .forFilePath(path)
        viewerOriginalContent = nil
        viewerFileContent = nil
        isViewerLoading = true
        isViewerSaving = false
        viewerLoadError = nil
        viewerSaveError = nil
        highlightedFilePath = path
        rightSidebarSelection = .files
        if isRightSidebarCollapsed {
            isRightSidebarCollapsed = false
        }
        selectedDiffFile = nil
        diffRawText = nil
        diffFileContent = nil
        isDiffLoading = false
        combinedDiffTitle = nil
        combinedDiffRawText = nil
        isCombinedDiffLoading = false
    }

    func setViewerLoadedContent(_ content: String) {
        viewerOriginalContent = content
        viewerFileContent = content
        isViewerLoading = false
        isViewerSaving = false
        viewerLoadError = nil
        viewerSaveError = nil
    }

    func setViewerFileLoadError(_ message: String) {
        viewerOriginalContent = nil
        viewerFileContent = nil
        isViewerLoading = false
        isViewerSaving = false
        viewerLoadError = message
    }

    func setViewerDraftContent(_ content: String) {
        viewerFileContent = content
        viewerSaveError = nil
    }

    func beginViewerSave() {
        isViewerSaving = true
        viewerSaveError = nil
    }

    func completeViewerSave(with content: String) {
        viewerOriginalContent = content
        viewerFileContent = content
        isViewerSaving = false
        viewerSaveError = nil
        viewerLoadError = nil
    }

    func setViewerSaveError(_ message: String) {
        isViewerSaving = false
        viewerSaveError = message
    }

    func revertViewerDraftToSaved() {
        viewerFileContent = viewerOriginalContent
        viewerSaveError = nil
    }

    func closeFileViewer() {
        viewerFilePath = nil
        viewerLayoutMode = .editorOnly
        viewerOriginalContent = nil
        viewerFileContent = nil
        isViewerLoading = false
        isViewerSaving = false
        viewerLoadError = nil
        viewerSaveError = nil
    }

    // MARK: Combined diff

    func openCombinedDiff(title: String) {
        combinedDiffTitle = title
        combinedDiffRawText = nil
        isCombinedDiffLoading = true
        selectedDiffFile = nil
        diffRawText = nil
        diffFileContent = nil
        isDiffLoading = false
        viewerFilePath = nil
        viewerLayoutMode = .editorOnly
        viewerOriginalContent = nil
        viewerFileContent = nil
        isViewerLoading = false
        isViewerSaving = false
        viewerLoadError = nil
        viewerSaveError = nil
    }

    func setCombinedDiffText(_ text: String) {
        combinedDiffRawText = text
        isCombinedDiffLoading = false
    }

    func closeCombinedDiff() {
        combinedDiffTitle = nil
        combinedDiffRawText = nil
        isCombinedDiffLoading = false
    }

    // MARK: Review comments

    func addReviewComment(_ comment: TerminalLocalReviewComment) {
        localReviewComments.append(comment)
    }

    func removeReviewComment(id: UUID) {
        localReviewComments.removeAll { $0.id == id }
    }

    func clearReviewComments() {
        localReviewComments.removeAll()
    }

    func addPRThreadComment(_ comment: TerminalLocalReviewComment) {
        prThreadReviewComments.append(comment)
    }

    func clearPRThreadComments() {
        prThreadReviewComments.removeAll()
    }

    func replaceReviewThread(_ thread: TerminalPullRequestReviewThread) {
        if let threadIndex = reviewThreads.firstIndex(where: { $0.id == thread.id }) {
            var updatedThreads = reviewThreads
            updatedThreads[threadIndex] = thread
            reviewThreads = updatedThreads
        }

        if activeReviewThread?.id == thread.id {
            activeReviewThread = thread
        }
    }

    func appendOptimisticReply(toThreadID threadID: String, body: String) {
        guard let existingThread = reviewThreads.first(where: { $0.id == threadID }) ?? activeReviewThread,
              existingThread.id == threadID else {
            return
        }

        let optimisticComment = TerminalPullRequestReviewComment(
            id: "local-reply-\(UUID().uuidString)",
            body: body,
            url: existingThread.comments.last?.url ?? URL(string: "https://github.com")!,
            authorLogin: "you",
            createdAt: Date(),
            path: existingThread.path,
            line: existingThread.line,
            originalLine: existingThread.originalLine,
            startLine: existingThread.startLine,
            originalStartLine: existingThread.originalStartLine,
            replyToID: existingThread.comments.last?.id
        )

        let updatedThread = TerminalPullRequestReviewThread(
            id: existingThread.id,
            path: existingThread.path,
            line: existingThread.line,
            originalLine: existingThread.originalLine,
            startLine: existingThread.startLine,
            originalStartLine: existingThread.originalStartLine,
            diffSide: existingThread.diffSide,
            isResolved: existingThread.isResolved,
            isOutdated: existingThread.isOutdated,
            comments: existingThread.comments + [optimisticComment],
            hasMoreComments: existingThread.hasMoreComments
        )

        replaceReviewThread(updatedThread)
    }

    func setReviewThreadResolved(threadID: String, isResolved: Bool) {
        guard let existingThread = reviewThreads.first(where: { $0.id == threadID }) ?? activeReviewThread,
              existingThread.id == threadID else {
            return
        }

        let updatedThread = TerminalPullRequestReviewThread(
            id: existingThread.id,
            path: existingThread.path,
            line: existingThread.line,
            originalLine: existingThread.originalLine,
            startLine: existingThread.startLine,
            originalStartLine: existingThread.originalStartLine,
            diffSide: existingThread.diffSide,
            isResolved: isResolved,
            isOutdated: existingThread.isOutdated,
            comments: existingThread.comments,
            hasMoreComments: existingThread.hasMoreComments
        )

        replaceReviewThread(updatedThread)
    }
}

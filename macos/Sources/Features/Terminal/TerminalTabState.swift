import Foundation
import UserNotifications

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

    var systemImage: String {
        switch self {
        case .changes:
            return "plusminus"
        case .comments:
            return "text.bubble"
        case .checks:
            return "checkmark.seal"
        case .files:
            return "folder"
        }
    }
}

enum TerminalContentTabKind: Equatable {
    case terminal
    case diff
    case file
}

struct TerminalContentTab: Identifiable, Equatable {
    let id: String
    var kind: TerminalContentTabKind
    var title: String
    var subtitle: String?
    var isClosable: Bool
    var isDirty: Bool
}

private struct TerminalFileContentTabState: Equatable {
    let id: String
    let displayPath: String
    let resolvedPath: String?
    var layoutMode: TerminalFileViewerLayoutMode
    var originalContent: String?
    var content: String?
    var isLoading: Bool
    var isSaving: Bool
    var loadError: String?
    var saveError: String?

    var isDirty: Bool {
        content != originalContent
    }

    var contentTab: TerminalContentTab {
        TerminalContentTab(
            id: id,
            kind: .file,
            title: URL(fileURLWithPath: displayPath).lastPathComponent,
            subtitle: displayPath,
            isClosable: true,
            isDirty: isDirty
        )
    }
}

final class TerminalTabState: ObservableObject, Identifiable {
    static let terminalContentTabID = "terminal"
    static let diffContentTabID = "diff"

    let id: UUID

    // MARK: Inner content tabs

    @Published private(set) var contentTabs: [TerminalContentTab]
    @Published private(set) var activeContentTabID: String
    private var fileContentTabs: [String: TerminalFileContentTabState] = [:]

    var activeContentTab: TerminalContentTab? {
        contentTabs.first { $0.id == activeContentTabID }
    }

    var activeContentTabKind: TerminalContentTabKind {
        activeContentTab?.kind ?? .terminal
    }

    var activeFileContentTabID: String? {
        activeContentTabKind == .file ? activeContentTabID : nil
    }

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
    @Published var combinedDiffFileContents: [String: String] = [:]
    @Published var isCombinedDiffLoading: Bool = false
    @Published var diffReloadRevision: Int = 0

    // MARK: Review comments

    @Published var localReviewComments: [TerminalLocalReviewComment] = []
    @Published var prThreadReviewComments: [TerminalLocalReviewComment] = []
    @Published var activeReviewThread: TerminalPullRequestReviewThread?
    @Published var selectedReviewCommentID: UUID?

    // MARK: GingerTTY worktree

    /// Set when this tab was opened into a GingerTTY-created git worktree (via the
    /// New Worktree or PR Review flows). Drives the cleanup prompt on tab close.
    @Published var gingerttyWorktreePath: String?
    @Published var gingerttyWorktreeRepositoryRoot: String?

    // MARK: PR review mode

    @Published var isReviewMode: Bool = false
    @Published var reviewBodyText: String = ""
    @Published var isSubmittingReview: Bool = false
    @Published var reviewSubmitError: String?

    // MARK: Plan review state

    @Published private(set) var planReviewSession: TerminalPlanReviewSession?
    @Published var planReviewComments: [TerminalPlanReviewComment] = []
    @Published private(set) var isPlanReviewSubmitting: Bool = false

    // MARK: Agent status (set via AppleScript by CLI wrappers)

    @Published private(set) var agentStatus: String?
    @Published private(set) var lastAgentActivityAt: Date?
    @Published private(set) var pendingPermissionRequest: TerminalPermissionRequest?

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
    @Published private(set) var viewerResolvedFilePath: String?
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

    var isPlanReviewActive: Bool {
        planReviewSession != nil
    }

    var canRequestPlanReviewChanges: Bool {
        planReviewSession != nil &&
            !isViewerLoading &&
            !isViewerSaving &&
            !isPlanReviewSubmitting &&
            (!planReviewComments.isEmpty || isViewerDirty)
    }

    var canApprovePlanReview: Bool {
        planReviewSession != nil &&
            !isViewerLoading &&
            !isViewerSaving &&
            !isPlanReviewSubmitting
    }

    // MARK: Init

    init(
        id: UUID = UUID(),
        workingDirectory: String? = nil
    ) {
        self.id = id
        self.workingDirectory = workingDirectory
        self.contentTabs = [
            TerminalContentTab(
                id: Self.terminalContentTabID,
                kind: .terminal,
                title: "Terminal",
                subtitle: nil,
                isClosable: false,
                isDirty: false
            )
        ]
        self.activeContentTabID = Self.terminalContentTabID
        self.rightSidebarSelection = .changes
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

    func setAgentStatus(_ status: String?, updatedAt: Date = Date()) {
        // Don't let "Need input" overwrite "Done" — a Notification event
        // often fires right after Stop just to alert the user, not because
        // the agent actually needs input.
        if status == "Need input" && agentStatus == "Done" {
            return
        }
        agentStatus = status
        if status != nil {
            lastAgentActivityAt = updatedAt
        }
        if status == "Running" || status == "Done" {
            removePermissionNotification()
            pendingPermissionRequest = nil
        }
    }

    func presentPermissionRequest(_ request: TerminalPermissionRequest) {
        pendingPermissionRequest = request
        if agentStatus != nil {
            lastAgentActivityAt = request.requestedAt
        }
    }

    func clearPendingPermissionRequest() {
        removePermissionNotification()
        pendingPermissionRequest = nil
    }

    func clearExpiredPermissionRequest(now: Date = Date()) {
        guard let pendingPermissionRequest, pendingPermissionRequest.expiresAt <= now else {
            return
        }
        removePermissionNotification()
        self.pendingPermissionRequest = nil
    }

    private func removePermissionNotification() {
        guard let request = pendingPermissionRequest else { return }
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [request.id])
    }

    func resetRepositoryScopedState() {
        clearLocalRepositoryState()
        clearPullRequestState()
        clearReviewComments()
        clearPRThreadComments()
        activeReviewThread = nil
        selectedReviewCommentID = nil
        reviewBodyText = ""
        reviewSubmitError = nil
        mergeInProgress = false
        mergeError = nil
        removePermissionNotification()
        pendingPermissionRequest = nil
        planReviewSession = nil
        planReviewComments = []
        isPlanReviewSubmitting = false
        showCommentBox = false
        pendingSelectionStart = nil
        pendingSelectionEnd = nil
        pendingSelectionSide = nil
        pendingCommentText = ""
        closeDiff()
        closeCombinedDiff()
        closeAllFileViewers()
        highlightedFilePath = nil
    }

    // MARK: Content tabs

    func setActiveContentTab(_ id: String) {
        guard contentTabs.contains(where: { $0.id == id }) else { return }
        persistActiveFileContentTab()
        activeContentTabID = id
        restoreActiveFileContentTabIfNeeded()
        if activeContentTabKind != .file {
            clearViewerPresentationState()
        }
    }

    private static func fileContentTabID(displayPath: String, resolvedPath: String?) -> String {
        "file:\(resolvedPath ?? displayPath)"
    }

    private func ensureDiffContentTab() {
        if !contentTabs.contains(where: { $0.id == Self.diffContentTabID }) {
            contentTabs.append(TerminalContentTab(
                id: Self.diffContentTabID,
                kind: .diff,
                title: "Diff",
                subtitle: nil,
                isClosable: true,
                isDirty: false
            ))
        }
        setActiveContentTab(Self.diffContentTabID)
    }

    private func upsertActiveFileContentTab(_ state: TerminalFileContentTabState) {
        fileContentTabs[state.id] = state
        if let index = contentTabs.firstIndex(where: { $0.id == state.id }) {
            contentTabs[index] = state.contentTab
        } else {
            contentTabs.append(state.contentTab)
        }
        activeContentTabID = state.id
    }

    private func persistActiveFileContentTab() {
        guard var state = fileContentTabs[activeContentTabID] else { return }
        state.layoutMode = viewerLayoutMode
        state.originalContent = viewerOriginalContent
        state.content = viewerFileContent
        state.isLoading = isViewerLoading
        state.isSaving = isViewerSaving
        state.loadError = viewerLoadError
        state.saveError = viewerSaveError
        upsertActiveFileContentTab(state)
    }

    private func restoreActiveFileContentTabIfNeeded() {
        guard let state = fileContentTabs[activeContentTabID] else { return }
        viewerFilePath = state.displayPath
        viewerResolvedFilePath = state.resolvedPath
        viewerLayoutMode = state.layoutMode
        viewerOriginalContent = state.originalContent
        viewerFileContent = state.content
        isViewerLoading = state.isLoading
        isViewerSaving = state.isSaving
        viewerLoadError = state.loadError
        viewerSaveError = state.saveError
    }

    private func clearViewerPresentationState() {
        viewerFilePath = nil
        viewerResolvedFilePath = nil
        viewerLayoutMode = .editorOnly
        viewerOriginalContent = nil
        viewerFileContent = nil
        isViewerLoading = false
        isViewerSaving = false
        viewerLoadError = nil
        viewerSaveError = nil
    }

    private func selectFallbackContentTab(afterRemoving removedID: String) {
        if activeContentTabID != removedID {
            return
        }

        activeContentTabID = contentTabs.first?.id ?? Self.terminalContentTabID
        restoreActiveFileContentTabIfNeeded()
        if activeContentTabKind != .file {
            clearViewerPresentationState()
        }
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

    func setRightSidebarSplit(_ newValue: CGFloat) {
        rightSidebarSplit = min(max(newValue, 0.2), 0.95)
    }

    // MARK: Diff viewer

    func openDiffForFile(_ file: TerminalRepositoryChangeFile) {
        ensureDiffContentTab()
        selectedDiffFile = file
        diffRows = nil
        diffRawText = nil
        diffFileContent = nil
        isDiffLoading = true
        selectedReviewCommentID = nil
        combinedDiffTitle = nil
        combinedDiffRawText = nil
        combinedDiffFileContents = [:]
        isCombinedDiffLoading = false
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
        combinedDiffTitle = nil
        combinedDiffRawText = nil
        combinedDiffFileContents = [:]
        isCombinedDiffLoading = false
        showCommentBox = false
        pendingCommentText = ""
        pendingSelectionStart = nil
        pendingSelectionEnd = nil
        pendingSelectionSide = nil
        activeReviewThread = nil
        selectedReviewCommentID = nil
        closeDiffContentTab()
    }

    // MARK: File viewer

    func openFileViewer(path: String, resolvedPath: String? = nil) {
        persistActiveFileContentTab()

        let resolved = resolvedPath ?? path
        let tabID = Self.fileContentTabID(displayPath: path, resolvedPath: resolved)
        if let existing = fileContentTabs[tabID] {
            upsertActiveFileContentTab(existing)
            restoreActiveFileContentTabIfNeeded()
        } else {
            let state = TerminalFileContentTabState(
                id: tabID,
                displayPath: path,
                resolvedPath: resolved,
                layoutMode: .forFilePath(path),
                originalContent: nil,
                content: nil,
                isLoading: true,
                isSaving: false,
                loadError: nil,
                saveError: nil
            )
            upsertActiveFileContentTab(state)
            restoreActiveFileContentTabIfNeeded()
        }

        highlightedFilePath = resolvedPath == nil ? path : nil
        rightSidebarSelection = .files
        SidebarCollapseState.shared.isRightSidebarCollapsed = false
    }

    func setViewerLoadedContent(_ content: String, tabID: String? = nil) {
        if let tabID, tabID != activeContentTabID, var state = fileContentTabs[tabID] {
            state.originalContent = content
            state.content = content
            state.isLoading = false
            state.isSaving = false
            state.loadError = nil
            state.saveError = nil
            upsertInactiveFileContentTab(state)
            return
        }

        viewerOriginalContent = content
        viewerFileContent = content
        isViewerLoading = false
        isViewerSaving = false
        viewerLoadError = nil
        viewerSaveError = nil
        persistActiveFileContentTab()
    }

    func setViewerFileLoadError(_ message: String, tabID: String? = nil) {
        if let tabID, tabID != activeContentTabID, var state = fileContentTabs[tabID] {
            state.originalContent = nil
            state.content = nil
            state.isLoading = false
            state.isSaving = false
            state.loadError = message
            upsertInactiveFileContentTab(state)
            return
        }

        viewerOriginalContent = nil
        viewerFileContent = nil
        isViewerLoading = false
        isViewerSaving = false
        viewerLoadError = message
        persistActiveFileContentTab()
    }

    func setViewerDraftContent(_ content: String) {
        viewerFileContent = content
        viewerSaveError = nil
        persistActiveFileContentTab()
    }

    func beginViewerSave() {
        isViewerSaving = true
        viewerSaveError = nil
        persistActiveFileContentTab()
    }

    func completeViewerSave(with content: String) {
        viewerOriginalContent = content
        viewerFileContent = content
        isViewerSaving = false
        viewerSaveError = nil
        viewerLoadError = nil
        persistActiveFileContentTab()
    }

    func setViewerSaveError(_ message: String) {
        isViewerSaving = false
        viewerSaveError = message
        persistActiveFileContentTab()
    }

    func revertViewerDraftToSaved() {
        viewerFileContent = viewerOriginalContent
        viewerSaveError = nil
        persistActiveFileContentTab()
    }

    func closeFileViewer() {
        closeFileViewer(tabID: activeFileContentTabID)
    }

    func closeFileViewer(tabID: String?) {
        guard let tabID, fileContentTabs[tabID] != nil else { return }
        if tabID == activeContentTabID {
            persistActiveFileContentTab()
        }
        fileContentTabs.removeValue(forKey: tabID)
        contentTabs.removeAll { $0.id == tabID }
        selectFallbackContentTab(afterRemoving: tabID)
    }

    // MARK: Combined diff

    func openCombinedDiff(title: String) {
        ensureDiffContentTab()
        combinedDiffTitle = title
        combinedDiffRawText = nil
        combinedDiffFileContents = [:]
        isCombinedDiffLoading = true
        selectedDiffFile = nil
        diffRawText = nil
        diffFileContent = nil
        isDiffLoading = false
    }

    func setCombinedDiffText(_ text: String, fileContents: [String: String] = [:]) {
        combinedDiffRawText = text
        combinedDiffFileContents = fileContents
        isCombinedDiffLoading = false
    }

    func closeCombinedDiff() {
        combinedDiffTitle = nil
        combinedDiffRawText = nil
        combinedDiffFileContents = [:]
        isCombinedDiffLoading = false
        selectedDiffFile = nil
        diffRows = nil
        diffRawText = nil
        diffFileContent = nil
        isDiffLoading = false
        closeDiffContentTab()
    }

    private func closeDiffContentTab() {
        contentTabs.removeAll { $0.id == Self.diffContentTabID }
        selectFallbackContentTab(afterRemoving: Self.diffContentTabID)
    }

    private func closeAllFileViewers() {
        fileContentTabs.removeAll()
        contentTabs.removeAll { $0.kind == .file }
        if activeContentTabKind == .file {
            activeContentTabID = Self.terminalContentTabID
        }
        clearViewerPresentationState()
    }

    private func upsertInactiveFileContentTab(_ state: TerminalFileContentTabState) {
        fileContentTabs[state.id] = state
        if let index = contentTabs.firstIndex(where: { $0.id == state.id }) {
            contentTabs[index] = state.contentTab
        }
    }

    func requestDiffReload() {
        diffReloadRevision &+= 1
    }

    // MARK: Review comments

    func addReviewComment(_ comment: TerminalLocalReviewComment) {
        localReviewComments.append(comment)
    }

    func removeReviewComment(id: UUID) {
        localReviewComments.removeAll { $0.id == id }
        if selectedReviewCommentID == id {
            selectedReviewCommentID = nil
        }
    }

    func updateReviewComment(id: UUID, text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty,
              let index = localReviewComments.firstIndex(where: { $0.id == id }) else {
            return
        }

        let existing = localReviewComments[index]
        localReviewComments[index] = TerminalLocalReviewComment(
            id: existing.id,
            filePath: existing.filePath,
            startLine: existing.startLine,
            endLine: existing.endLine,
            side: existing.side,
            text: trimmedText
        )
    }

    func clearReviewComments() {
        localReviewComments.removeAll()
        selectedReviewCommentID = nil
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

    // MARK: Plan review

    func openPlanReview(_ session: TerminalPlanReviewSession) {
        planReviewSession = session
        planReviewComments = []
        isPlanReviewSubmitting = false
        openFileViewer(path: session.scratchFilePath, resolvedPath: session.scratchFilePath)
        rightSidebarSelection = .changes
    }

    func addPlanReviewComment(_ comment: TerminalPlanReviewComment) {
        planReviewComments.append(comment)
    }

    func removePlanReviewComment(id: UUID) {
        planReviewComments.removeAll { $0.id == id }
    }

    func clearPlanReviewComments() {
        planReviewComments.removeAll()
    }

    func beginPlanReviewSubmission() {
        isPlanReviewSubmitting = true
    }

    func completePlanReviewSubmission() {
        isPlanReviewSubmitting = false
        planReviewSession = nil
        planReviewComments = []
    }

    func failPlanReviewSubmission() {
        isPlanReviewSubmitting = false
    }

    func cancelPlanReviewSelection() {
        pendingCommentText = ""
        pendingSelectionStart = nil
        pendingSelectionEnd = nil
        pendingSelectionSide = nil
        showCommentBox = false
    }
}

import AppKit
import SwiftUI

struct TerminalWindowView: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject private var tab: TerminalTabState

    @State private var rightSidebarWidth: CGFloat = 300
    private let sidebarMinWidth: CGFloat = 200
    private let sidebarMaxWidth: CGFloat = 500
    private let rightSidebarRailWidth: CGFloat = 32

    init(controller: TerminalController) {
        self.controller = controller
        self.tab = controller.tabState
    }

    var body: some View {
        HStack(spacing: 0) {
            if controller.isSelectedRightSidebarCollapsed {
                terminalContent

                Divider()

                RightSidebarRail(controller: controller)
                    .frame(width: rightSidebarRailWidth)
            } else {
                terminalContent

                ResizableDivider(
                    dimension: $rightSidebarWidth,
                    minValue: sidebarMinWidth,
                    maxValue: sidebarMaxWidth,
                    inverted: true
                )

                TerminalRightSidebarView(controller: controller, tab: tab)
                    .frame(width: rightSidebarWidth)
            }
        }
        .sheet(item: $controller.worktreeSheetModel) { model in
            TerminalWorktreeSheet(model: model)
        }
        .sheet(item: $controller.prReviewSheetModel) { model in
            TerminalPRReviewSheet(model: model)
        }
        .sheet(item: $controller.fileCommandPaletteModel) { model in
            TerminalFileCommandPalette(model: model)
        }
        .background {
            Button("") {
                controller.presentFileCommandPalette()
            }
            .keyboardShortcut("p", modifiers: .command)
            .hidden()
        }
        .accessibilityIdentifier("terminal-window-view")
    }

    private var terminalContent: some View {
        Group {
            if tab.selectedDiffFile != nil {
                TerminalDiffView(controller: controller, tab: tab)
            } else if tab.combinedDiffTitle != nil {
                TerminalCombinedDiffView(controller: controller, tab: tab)
            } else if tab.viewerFilePath != nil {
                TerminalFileViewerView(controller: controller, tab: tab)
            } else {
                TerminalView(ghostty: controller.ghostty, viewModel: controller, delegate: controller)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TerminalRightSidebarView: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var tab: TerminalTabState

    var body: some View {
        RightSidebarInspector(controller: controller, tab: tab)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("terminal-right-sidebar")
    }
}

private struct RightSidebarRail: View {
    @ObservedObject var controller: TerminalController

    var body: some View {
        VStack(spacing: 0) {
            Button {
                controller.toggleSelectedRightSidebarCollapsed()
            } label: {
                Image(systemName: "sidebar.right")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar-right-toggle")

            Spacer()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("terminal-right-sidebar-rail")
    }
}

private struct RightSidebarInspector: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var tab: TerminalTabState

    var body: some View {
        VStack(spacing: 0) {
            PullRequestHeaderCard(controller: controller, tab: tab)
                .padding(14)

            HStack {
                Spacer(minLength: 0)
                Picker(
                    "",
                    selection: Binding(
                        get: { tab.rightSidebarSelection },
                        set: { controller.setSelectedRightSidebarSelection($0) }
                    )
                ) {
                    ForEach(TerminalInspectorTab.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .accessibilityIdentifier("sidebar-right-tabs")

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab.rightSidebarSelection {
                    case .changes:
                        ChangesInspectorView(controller: controller, tab: tab)
                    case .comments:
                        CommentsInspectorView(controller: controller, tab: tab)
                    case .checks:
                        ChecksInspectorView(controller: controller, tab: tab)
                    case .files:
                        FilesInspectorView(controller: controller, tab: tab)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct PullRequestHeaderCard: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var tab: TerminalTabState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("GitHub PR")
                    .font(.headline)

                Spacer()

                Button {
                    controller.refreshPullRequestFromUI()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar-right-refresh")

                Button {
                    controller.toggleSelectedRightSidebarCollapsed()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar-right-toggle")
            }

            if let summary = tab.pullRequestSummary {
                Link(destination: summary.url) {
                    Text("#\(summary.number) \(summary.title)")
                        .font(.body.weight(.semibold))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                HStack(spacing: 8) {
                    Text("Merge: \(summary.mergeStateStatus)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule(style: .continuous)
                                .fill(mergeStatusColor(summary.mergeStateStatus).opacity(0.12))
                        )
                        .foregroundStyle(mergeStatusColor(summary.mergeStateStatus))

                    if summary.isMergeable {
                        MergeButton(controller: controller, tab: tab)
                    }
                }

                if let error = tab.mergeError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                PRDescriptionView(
                    controller: controller,
                    tab: tab,
                    descriptionText: summary.body
                )
            } else {
                Text(tab.pullRequestMessage ?? "Open a repository branch to load pull request details.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let branchName = tab.branchName {
                Text(branchLabel(branchName: branchName, repositoryRoot: tab.repositoryRoot))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let workingDirectory = tab.workingDirectory {
                Text(workingDirectory)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let status = statusLine {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(
                        tab.pullRequestStatusMessage == nil
                            ? Color.secondary
                            : Color(nsColor: .systemOrange)
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .accessibilityIdentifier("sidebar-right-pr-panel")
    }

    private var statusLine: String? {
        if tab.isPullRequestRefreshing {
            return "Refreshing pull request…"
        }

        if let message = tab.pullRequestStatusMessage {
            return "Stale: \(message)"
        }

        guard let refreshedAt = tab.pullRequestLastUpdatedAt else { return nil }
        return "Refreshed \(refreshedAt.formatted(date: .omitted, time: .shortened))"
    }

    private func branchLabel(branchName: String, repositoryRoot: String?) -> String {
        if let repositoryRoot {
            return "\(URL(fileURLWithPath: repositoryRoot).lastPathComponent) • \(branchName)"
        }

        return "Branch: \(branchName)"
    }

    private func mergeStatusColor(_ status: String) -> Color {
        switch status.uppercased() {
        case "CLEAN": return .green
        case "UNSTABLE", "HAS_HOOKS": return .orange
        case "BLOCKED": return .red
        case "BEHIND": return .yellow
        default: return .secondary
        }
    }
}

private struct MergeButton: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var tab: TerminalTabState
    @State private var showConfirmation = false
    @State private var selectedMethod: TerminalMergeMethod = .squash

    var body: some View {
        Menu {
            ForEach(TerminalMergeMethod.allCases, id: \.self) { method in
                Button(method.label) {
                    selectedMethod = method
                    showConfirmation = true
                }
            }
        } label: {
            if tab.mergeInProgress {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Label("Merge", systemImage: "arrow.triangle.merge")
                    .font(.caption.weight(.semibold))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(tab.mergeInProgress)
        .alert("Merge Pull Request", isPresented: $showConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button(selectedMethod.label) {
                controller.mergePullRequest(method: selectedMethod)
            }
        } message: {
            Text("Are you sure you want to \(selectedMethod.label.lowercased()) this pull request? The branch will be deleted after merging.")
        }
    }
}

private struct ChangesInspectorView: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var tab: TerminalTabState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if tab.isReviewMode {
                ReviewSubmissionCard(controller: controller, tab: tab)
            }

            if !tab.localReviewComments.isEmpty {
                if tab.isReviewMode {
                    ReviewCommentsPreview(tab: tab)
                } else {
                    ReviewCommentsUberBox(controller: controller, tab: tab)
                }
            }

            if let summary = tab.changeSummary {
                ChangeSectionView(
                    section: summary.committed,
                    footnote: summary.baseBranchName.map { "Base branch: \($0)" },
                    controller: controller,
                    tab: tab
                )
                ChangeSectionView(
                    section: summary.uncommitted,
                    footnote: nil,
                    controller: controller,
                    tab: tab
                )

                CommitsSectionView(controller: controller, tab: tab)
            } else if tab.isLocalRepositoryRefreshing {
                Text("Loading…")
                    .foregroundStyle(.secondary)
            } else {
                Text(tab.changeSummaryMessage ?? "No repository changes are available.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct CommitsSectionView: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var tab: TerminalTabState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Commits")
                    .font(.headline)
                Spacer()
                if tab.isLocalRepositoryRefreshing && tab.commitEntries.isEmpty {
                    ProgressView()
                        .controlSize(.mini)
                }
            }

            if tab.commitEntries.isEmpty && !tab.isLocalRepositoryRefreshing {
                Text("No commits found.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tab.commitEntries) { commit in
                    CommitRow(commit: commit)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            controller.openCommitDiff(commit)
                        }
                        .onHover { hovering in
                            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }
            }
        }
    }
}

private struct CommitRow: View {
    let commit: TerminalCommitEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(commit.subject)
                .font(.caption.weight(.medium))
                .lineLimit(2)

            HStack(spacing: 6) {
                Text(commit.shortHash)
                    .font(.caption2.monospaced())
                    .foregroundColor(.accentColor)

                Text(commit.authorName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(commit.relativeDate)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct CommentsInspectorView: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var tab: TerminalTabState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !tab.prThreadReviewComments.isEmpty {
                PRThreadCommentsUberBox(controller: controller, tab: tab)
            }

            if tab.pullRequestSummary == nil, tab.reviewThreads.isEmpty, tab.isPullRequestRefreshing {
                Text("Loading…")
                    .foregroundStyle(.secondary)
            } else if tab.pullRequestSummary == nil, tab.reviewThreads.isEmpty {
                Text(tab.pullRequestMessage ?? "No pull request is available for review comments.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if tab.reviewThreads.isEmpty {
                Text("No review comments.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tab.reviewThreads) { thread in
                    ReviewThreadCard(
                        thread: thread,
                        onViewInDiff: { controller.openDiffForComment(thread) },
                        onAddToChat: { controller.addThreadToChat(thread) }
                    )
                }
            }
        }
    }
}

private struct ChecksInspectorView: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var tab: TerminalTabState
    @State private var fixErrorMessage: String?

    var body: some View {
        Group {
            if tab.pullRequestSummary == nil, tab.pullRequestChecks.isEmpty, tab.isPullRequestRefreshing {
                Text("Loading…")
                    .foregroundStyle(.secondary)
            } else if tab.pullRequestSummary == nil, tab.pullRequestChecks.isEmpty {
                Text(tab.pullRequestMessage ?? "No pull request is available for checks.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if tab.pullRequestChecks.isEmpty {
                Text("No checks.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if failingChecks.count > 0 {
                        Button {
                            sendFailingChecksToChat()
                        } label: {
                            Label("Fix errors in chat", systemImage: "wrench.and.screwdriver")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }

                    if let fixErrorMessage {
                        Text(fixErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    ForEach(tab.pullRequestChecks) { check in
                        CheckRow(check: check)
                    }
                }
            }
        }
    }

    private var failingChecks: [TerminalPullRequestCheck] {
        tab.pullRequestChecks.filter { $0.bucket == "fail" }
    }

    private func sendFailingChecksToChat() {
        fixErrorMessage = nil

        guard let surface = controller.focusedSurface else {
            fixErrorMessage = "No active terminal session. Open a terminal first."
            return
        }

        var message = "The following CI checks are failing on this PR. Please investigate and fix the errors:\n\n"
        for check in failingChecks {
            message += "- **\(check.name)**"
            if let workflow = check.workflow, !workflow.isEmpty {
                message += " (workflow: \(workflow))"
            }
            if let desc = check.description, !desc.isEmpty {
                message += ": \(desc)"
            }
            if let link = check.link {
                message += " — \(link.absoluteString)"
            }
            message += "\n"
        }

        guard let surfaceModel = surface.surfaceModel else {
            fixErrorMessage = "Terminal surface is not ready."
            return
        }
        surfaceModel.sendText(message)
    }
}

private struct ChangeSectionView: View {
    let section: TerminalRepositoryChangeSection
    let footnote: String?
    @ObservedObject var controller: TerminalController
    @ObservedObject var tab: TerminalTabState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(section.title)
                        .font(.headline)

                    if !section.files.isEmpty {
                        Button {
                            controller.openAllChangesDiff(section: section.title)
                        } label: {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help("View all \(section.title.lowercased()) changes")
                    }
                }

                summaryText

                if let footnote {
                    Text(footnote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let message = section.message, section.files.isEmpty {
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(section.files) { file in
                    let isSelected = tab.selectedDiffFile?.path == file.path
                    ChangeFileRow(file: file, isSelected: isSelected)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            let taggedFile = TerminalRepositoryChangeFile(
                                id: file.id,
                                path: file.path,
                                additions: file.additions,
                                deletions: file.deletions,
                                isBinary: file.isBinary,
                                badges: file.badges,
                                sectionTitle: section.title
                            )
                            controller.openDiffForFile(taggedFile)
                        }
                }
            }
        }
    }

    private var summaryText: Text {
        Text("\(section.fileCount) files, ")
            .font(.caption)
            .foregroundColor(.secondary)
        + Text("+\(section.additions)")
            .font(.caption)
            .foregroundColor(.green)
        + Text("/")
            .font(.caption)
            .foregroundColor(.secondary)
        + Text("-\(section.deletions)")
            .font(.caption)
            .foregroundColor(.red)
    }
}

private struct ChangeFileRow: View {
    let file: TerminalRepositoryChangeFile
    var isSelected: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                truncatedFilePath(file.path)
                    .lineLimit(2)

                Spacer(minLength: 8)

                if file.isBinary {
                    Text("binary")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 4) {
                        Text("+\(file.additions)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.green)
                        Text("-\(file.deletions)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.red)
                    }
                }
            }

            if !file.badges.isEmpty {
                HStack(spacing: 6) {
                    ForEach(file.badges, id: \.self) { badge in
                        Text(badge)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.accentColor.opacity(0.12))
                            )
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1.5)
        )
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    private func truncatedFilePath(_ path: String) -> Text {
        let url = URL(fileURLWithPath: path)
        let fileName = url.lastPathComponent
        let directory = url.deletingLastPathComponent().relativePath

        guard !directory.isEmpty, directory != "." else {
            return Text(fileName)
                .font(.body.monospaced().bold())
        }

        let components = directory.split(separator: "/")
        let maxDirLength = 40

        var dirDisplay = directory
        if directory.count > maxDirLength, components.count > 2 {
            let first = components.first.map(String.init) ?? ""
            let last = components.last.map(String.init) ?? ""
            dirDisplay = "\(first)/…/\(last)"
        }

        return Text(dirDisplay + "/")
            .font(.caption.monospaced())
            .foregroundColor(.secondary)
        + Text(fileName)
            .font(.body.monospaced().bold())
    }
}

private struct ReviewThreadCard: View {
    let thread: TerminalPullRequestReviewThread
    let onViewInDiff: () -> Void
    let onAddToChat: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                // Clickable file path — opens diff at comment location
                Button {
                    onViewInDiff()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                            .font(.caption)
                        Text(thread.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Review Thread")
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }

                if let locationLabel {
                    Text(locationLabel)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Add to chat button
                Button {
                    onAddToChat()
                } label: {
                    Image(systemName: "text.bubble")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Add to chat review")
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }

                Text(thread.isResolved ? "Resolved" : (thread.isOutdated ? "Outdated" : "Open"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(thread.isResolved ? .green : (thread.isOutdated ? .orange : .secondary))
            }

            ForEach(thread.comments) { comment in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Link(destination: comment.url) {
                            Text(comment.authorLogin)
                                .font(.caption.weight(.semibold))
                        }

                        Spacer()

                        Text(comment.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(comment.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
            }

            if thread.hasMoreComments {
                Text("Showing the first 100 comments in this review thread.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var locationLabel: String? {
        if let startLine = thread.startLine, let line = thread.line, startLine != line {
            return "L\(startLine)-L\(line)"
        }
        if let line = thread.line {
            return "L\(line)"
        }
        if let originalLine = thread.originalLine {
            return "L\(originalLine)"
        }
        return nil
    }
}

private struct ReviewSubmissionCard: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var tab: TerminalTabState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Submit Review")
                    .font(.headline)

                Spacer()

                if let summary = tab.pullRequestSummary {
                    Text("#\(summary.number)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            TextEditor(text: Binding(
                get: { tab.reviewBodyText },
                set: { tab.reviewBodyText = $0 }
            ))
            .font(.system(size: 12))
            .frame(minHeight: 60, maxHeight: 120)
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )

            if !tab.localReviewComments.isEmpty {
                Text("\(tab.localReviewComments.count) inline comment(s) will be included")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = tab.reviewSubmitError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Menu {
                ForEach(TerminalReviewEvent.allCases, id: \.self) { event in
                    Button {
                        controller.submitReview(event: event)
                    } label: {
                        Label(event.label, systemImage: event.icon)
                    }
                }
            } label: {
                Label("Submit review", systemImage: "paperplane.fill")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .menuStyle(.borderlessButton)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.green.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.green.opacity(0.3), lineWidth: 1)
            )
            .disabled(
                tab.isSubmittingReview
                    || tab.pullRequestSummary?.nodeID == nil
            )

            if tab.isSubmittingReview {
                HStack {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Submitting review…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

}

private struct PRDescriptionView: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var tab: TerminalTabState
    let descriptionText: String?

    @State private var isEditing = false
    @State private var editText = ""
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Description")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if isEditing {
                    Button("Cancel") {
                        isEditing = false
                    }
                    .font(.caption)
                    .buttonStyle(.plain)

                    Button(isSaving ? "Saving…" : "Save") {
                        savePRDescription()
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    .disabled(isSaving)
                } else {
                    Button {
                        editText = descriptionText ?? ""
                        isEditing = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            if isEditing {
                TextEditor(text: $editText)
                    .font(.system(size: 11))
                    .frame(maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
            } else if let desc = descriptionText, !desc.isEmpty {
                ScrollView {
                    Text(desc)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 100)
            } else {
                Text("No description.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func savePRDescription() {
        guard let root = tab.repositoryRoot else { return }
        isSaving = true
        Task {
            do {
                try await controller.repositoryService.updatePullRequestBody(
                    repositoryRoot: root,
                    body: editText
                )
                await MainActor.run {
                    isSaving = false
                    isEditing = false
                    controller.refreshPullRequestAfterMutation()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                }
            }
        }
    }
}

private struct ReviewCommentsPreview: View {
    @ObservedObject var tab: TerminalTabState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pending Comments")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text("\(tab.localReviewComments.count)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.accentColor.opacity(0.15))
                    )

                Button {
                    tab.clearReviewComments()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }

            ForEach(tab.localReviewComments) { comment in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(URL(fileURLWithPath: comment.filePath).lastPathComponent):\(comment.startLine == comment.endLine ? "L\(comment.startLine)" : "L\(comment.startLine)-L\(comment.endLine)")")
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(comment.text)
                        .font(.caption)
                        .lineLimit(3)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct CheckRow: View {
    let check: TerminalPullRequestCheck

    var body: some View {
        Group {
            if let link = check.link {
                Link(destination: link) {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var rowContent: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: check.iconName)
                .foregroundStyle(Color(nsColor: check.statusColor))

            VStack(alignment: .leading, spacing: 4) {
                Text(check.name)
                    .font(.body.weight(.semibold))
                    .multilineTextAlignment(.leading)

                if let workflow = check.workflow, !workflow.isEmpty {
                    Text(workflow)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let description = check.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(check.bucket.capitalized)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(nsColor: check.statusColor))
        }
    }
}

// MARK: - Files Inspector

private struct FilesInspectorView: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var tab: TerminalTabState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Files")
                    .font(.headline)
                Spacer()
                Button {
                    controller.refreshLocalRepositoryFromUI()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }

            if tab.isLocalRepositoryRefreshing && tab.fileTree == nil {
                Text("Loading…")
                    .foregroundStyle(.secondary)
            } else if let tree = tab.fileTree {
                if tree.children.isEmpty {
                    Text("No files found.")
                        .foregroundStyle(.secondary)
                } else {
                    FileTreeView(
                        node: tree,
                        depth: 0,
                        controller: controller,
                        highlightedPath: tab.highlightedFilePath
                    )
                }
            } else if tab.repositoryRoot == nil {
                Text("No repository root available.")
                    .foregroundStyle(.secondary)
            } else {
                Text(tab.changeSummaryMessage ?? "No files are available.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct FileTreeNode: Identifiable {
    let id = UUID()
    let name: String
    let relativePath: String
    var children: [FileTreeNode]
    let isDirectory: Bool

    func containsFile(relativePath: String) -> Bool {
        for child in children {
            if !child.isDirectory && child.relativePath == relativePath { return true }
            if child.isDirectory && child.containsFile(relativePath: relativePath) { return true }
        }
        return false
    }

    static func buildTree(from paths: [String], rootName: String) -> FileTreeNode {
        var root = FileTreeNode(name: rootName, relativePath: "", children: [], isDirectory: true)

        for path in paths {
            let components = path.split(separator: "/").map(String.init)
            insertPath(components: components, fullPath: path, currentPath: "", into: &root)
        }

        sortTree(&root)
        return root
    }

    private static func insertPath(
        components: [String],
        fullPath: String,
        currentPath: String,
        into node: inout FileTreeNode
    ) {
        guard let first = components.first else { return }

        if components.count == 1 {
            // It's a file
            node.children.append(FileTreeNode(name: first, relativePath: fullPath, children: [], isDirectory: false))
        } else {
            let directoryPath = currentPath.isEmpty ? first : "\(currentPath)/\(first)"

            // Find or create directory
            if let idx = node.children.firstIndex(where: { $0.name == first && $0.isDirectory }) {
                let remaining = Array(components.dropFirst())
                insertPath(
                    components: remaining,
                    fullPath: fullPath,
                    currentPath: directoryPath,
                    into: &node.children[idx]
                )
            } else {
                var dir = FileTreeNode(
                    name: first,
                    relativePath: directoryPath,
                    children: [],
                    isDirectory: true
                )
                let remaining = Array(components.dropFirst())
                insertPath(
                    components: remaining,
                    fullPath: fullPath,
                    currentPath: directoryPath,
                    into: &dir
                )
                node.children.append(dir)
            }
        }
    }

    private static func sortTree(_ node: inout FileTreeNode) {
        node.children.sort { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        for i in node.children.indices {
            if node.children[i].isDirectory {
                sortTree(&node.children[i])
            }
        }
    }
}

private struct FileTreeView: View {
    let node: FileTreeNode
    let depth: Int
    let controller: TerminalController
    let highlightedPath: String?

    var body: some View {
        ForEach(node.children) { child in
            if child.isDirectory {
                FileTreeDirectoryRow(
                    node: child, depth: depth,
                    controller: controller, highlightedPath: highlightedPath
                )
            } else {
                let isHighlighted = child.relativePath == highlightedPath
                FileTreeFileRow(node: child, depth: depth, isHighlighted: isHighlighted)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        controller.openFileViewer(relativePath: child.relativePath)
                    }
                    .onHover { hovering in
                        if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
            }
        }
    }
}

private struct FileTreeDirectoryRow: View {
    let node: FileTreeNode
    let depth: Int
    let controller: TerminalController
    let highlightedPath: String?
    @State private var isExpanded = false

    private var containsHighlightedFile: Bool {
        guard let hp = highlightedPath else { return false }
        return node.containsFile(relativePath: hp)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Image(systemName: "folder.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(node.name)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                Spacer()
            }
            .padding(.leading, CGFloat(depth) * 16)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture { isExpanded.toggle() }

            if isExpanded {
                FileTreeView(
                    node: node, depth: depth + 1,
                    controller: controller, highlightedPath: highlightedPath
                )
            }
        }
        .onAppear {
            if containsHighlightedFile {
                isExpanded = true
            }
        }
        .onChange(of: highlightedPath) { newValue in
            if newValue != nil && containsHighlightedFile {
                isExpanded = true
            }
        }
    }
}

private struct FileTreeFileRow: View {
    let node: FileTreeNode
    let depth: Int
    var isHighlighted: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: 12)
            Image(systemName: fileIcon(for: node.name))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(node.name)
                .font(.caption.monospaced())
                .lineLimit(1)
            Spacer()
        }
        .padding(.leading, CGFloat(depth) * 16)
        .padding(.vertical, 3)
        .background(
            isHighlighted
                ? RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
                : nil
        )
    }

    private func fileIcon(for name: String) -> String {
        guard let dotIdx = name.lastIndex(of: ".") else { return "doc" }
        let ext = String(name[name.index(after: dotIdx)...]).lowercased()
        switch ext {
        case "swift": return "swift"
        case "py": return "chevron.left.forwardslash.chevron.right"
        case "js", "ts", "jsx", "tsx": return "j.square"
        case "json", "yaml", "yml", "toml": return "gearshape"
        case "md", "txt": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "svg": return "photo"
        default: return "doc"
        }
    }
}

/// A draggable divider that resizes a dimension (width or height).
/// Set `inverted` to true for right-side panels where dragging left increases the dimension.
private struct ResizableDivider: View {
    @Binding var dimension: CGFloat
    let minValue: CGFloat
    let maxValue: CGFloat
    var inverted: Bool = false

    @State private var isDragging = false
    @State private var dragStartWidth: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor))
            .frame(width: 1)
            .padding(.horizontal, 2)
            .frame(width: 5)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            dragStartWidth = dimension
                        }
                        let delta = inverted ? -value.translation.width : value.translation.width
                        let newWidth = dragStartWidth + delta
                        dimension = min(max(newWidth, minValue), maxValue)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
    }
}

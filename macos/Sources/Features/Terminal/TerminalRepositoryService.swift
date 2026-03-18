import AppKit
import Darwin
import Foundation
import GhosttyKit

// MARK: - Repository Keys & State

struct TerminalRepositoryKey: Hashable {
    let repositoryRoot: String
    let branchName: String

    init(repositoryRoot: String, branchName: String) {
        self.repositoryRoot = repositoryRoot
        self.branchName = branchName
    }

    init(_ context: TerminalRepositoryContext) {
        self.repositoryRoot = context.repositoryRoot
        self.branchName = context.branchName
    }
}

// MARK: - Process Utilities

struct TerminalCommandOutput {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum TerminalCommandError: Error, LocalizedError {
    case commandNotFound(command: String)
    case nonZeroExit(command: String, exitCode: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case let .commandNotFound(command):
            return "\(command) is not available in PATH."
        case let .nonZeroExit(command, exitCode, stderr):
            if stderr.isEmpty {
                return "\(command) failed with exit code \(exitCode)."
            }
            return "\(command) failed with exit code \(exitCode): \(stderr)"
        }
    }
}

actor TerminalExecutableResolver {
    static let shared = TerminalExecutableResolver()

    private static let standardSearchPaths = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        "/opt/local/bin",
        "/opt/local/sbin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    private var cache: [String: String] = [:]

    func resolve(command: String) async -> String? {
        if command.contains("/") {
            return FileManager.default.isExecutableFile(atPath: command) ? command : nil
        }

        if let cached = cache[command], FileManager.default.isExecutableFile(atPath: cached) {
            return cached
        }

        if let resolved = Self.resolveFromSearchPaths(
            command: command,
            searchPaths: Self.defaultSearchPaths()
        ) {
            cache[command] = resolved
            return resolved
        }

        if let resolved = await Self.resolveViaLoginShell(command: command) {
            cache[command] = resolved
            return resolved
        }

        return nil
    }

    static func defaultSearchPaths(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let envPaths = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        var seen = Set<String>()
        var result: [String] = []

        for path in envPaths + standardSearchPaths {
            guard !path.isEmpty else { continue }
            guard seen.insert(path).inserted else { continue }
            result.append(path)
        }

        return result
    }

    static func resolveFromSearchPaths(command: String, searchPaths: [String]) -> String? {
        for directory in searchPaths {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(command, isDirectory: false)
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    private static func resolveViaLoginShell(command: String) async -> String? {
        guard let shellPath = loginShellPath() else { return nil }
        let shellName = URL(fileURLWithPath: shellPath).lastPathComponent
        let shellArguments: [String]
        switch shellName {
        case "bash", "sh", "zsh", "ksh", "fish":
            shellArguments = ["-ilc", "command -v \(Ghostty.Shell.quote(command)) 2>/dev/null || true"]
        default:
            shellArguments = ["-lc", "command -v \(Ghostty.Shell.quote(command)) 2>/dev/null || true"]
        }

        do {
            let output = try await TerminalProcessRunner.run(
                executable: shellPath,
                arguments: shellArguments
            )

            for line in output.stdout.split(whereSeparator: \.isNewline).reversed() {
                let candidate = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard candidate.hasPrefix("/") else { continue }
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        } catch {
            return nil
        }

        return nil
    }

    private static func loginShellPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let shell = environment["SHELL"],
           shell.hasPrefix("/"),
           FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }

        guard let passwd = getpwuid(getuid()),
              let shellPointer = passwd.pointee.pw_shell else {
            return nil
        }

        let shell = String(cString: shellPointer)
        return FileManager.default.isExecutableFile(atPath: shell) ? shell : nil
    }
}

enum TerminalProcessRunner {
    static func run(
        executable: String,
        arguments: [String],
        currentDirectory: String? = nil,
        additionalSearchPaths: [String] = [],
        acceptedExitCodes: Set<Int32> = [0]
    ) async throws -> TerminalCommandOutput {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = processEnvironment(additionalSearchPaths: additionalSearchPaths)
            if let currentDirectory {
                process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let stdoutHandle = stdoutPipe.fileHandleForReading
            let stderrHandle = stderrPipe.fileHandleForReading

            try process.run()

            // Drain both pipes while the child process is still running so large
            // `git` outputs cannot block on a full pipe buffer.
            let stdoutTask = Task.detached(priority: .userInitiated) {
                stdoutHandle.readDataToEndOfFile()
            }
            let stderrTask = Task.detached(priority: .userInitiated) {
                stderrHandle.readDataToEndOfFile()
            }

            process.waitUntilExit()

            let stdoutData = await stdoutTask.value
            let stderrData = await stderrTask.value
            let stdout = String(decoding: stdoutData, as: UTF8.self)
            let stderr = String(decoding: stderrData, as: UTF8.self)
            let status = process.terminationStatus

            guard acceptedExitCodes.contains(status) else {
                throw TerminalCommandError.nonZeroExit(
                    command: ([executable] + arguments).joined(separator: " "),
                    exitCode: status,
                    stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }

            return TerminalCommandOutput(stdout: stdout, stderr: stderr, exitCode: status)
        }.value
    }

    static func runCommand(
        _ command: String,
        arguments: [String],
        currentDirectory: String? = nil,
        acceptedExitCodes: Set<Int32> = [0]
    ) async throws -> TerminalCommandOutput {
        guard let executable = await TerminalExecutableResolver.shared.resolve(command: command) else {
            throw TerminalCommandError.commandNotFound(command: command)
        }

        return try await run(
            executable: executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            additionalSearchPaths: [URL(fileURLWithPath: executable).deletingLastPathComponent().path],
            acceptedExitCodes: acceptedExitCodes
        )
    }

    private static func processEnvironment(
        additionalSearchPaths: [String] = [],
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        var seen = Set<String>()
        let searchPaths = (additionalSearchPaths + TerminalExecutableResolver.defaultSearchPaths(
            environment: base
        )).filter { path in
            guard !path.isEmpty else { return false }
            return seen.insert(path).inserted
        }
        environment["PATH"] = searchPaths.joined(separator: ":")
        return environment
    }
}

struct TerminalRepositoryContext: Equatable, Codable {
    let workingDirectory: String
    let repositoryRoot: String
    let repositoryName: String
    let branchName: String
}

struct TerminalLocalRepositoryState: Equatable {
    let changeSummary: TerminalRepositoryChangeSummary
    let commitEntries: [TerminalCommitEntry]
    let filePaths: [String]
}

struct TerminalRepositoryWatchTargets: Equatable {
    let repositoryRoot: String
    let gitDirectory: String
    let gitCommonDirectory: String

    var watchedPaths: [String] {
        var seen = Set<String>()
        var paths: [String] = []

        for rawPath in [repositoryRoot, gitDirectory, gitCommonDirectory] {
            let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            paths.append(path)
        }

        return paths
    }
}

// MARK: - Domain Models

struct TerminalPullRequestCheck: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let link: URL?
    let bucket: String
    let state: String
    let workflow: String?
    let description: String?
    let startedAt: Date?
    let completedAt: Date?

    var iconName: String {
        switch bucket {
        case "pass":
            return "checkmark.circle.fill"
        case "pending":
            return "arrow.triangle.2.circlepath.circle.fill"
        case "cancel":
            return "minus.circle.fill"
        case "skipping":
            return "forward.circle.fill"
        case "fail":
            fallthrough
        default:
            return "xmark.circle.fill"
        }
    }

    var sortPriority: Int {
        switch bucket {
        case "fail":
            return 0
        case "pending":
            return 1
        case "pass":
            return 2
        case "cancel":
            return 3
        case "skipping":
            return 4
        default:
            return 5
        }
    }

    var statusColor: NSColor {
        switch bucket {
        case "pass":
            return .systemGreen
        case "pending":
            return .systemYellow
        case "fail":
            return .systemRed
        case "cancel":
            return .systemGray
        case "skipping":
            return .secondaryLabelColor
        default:
            return .tertiaryLabelColor
        }
    }
}

struct TerminalPullRequestSummary: Equatable, Codable {
    let nodeID: String?
    let number: Int
    let title: String
    let url: URL
    let mergeStateStatus: String
    let baseRefName: String
    let updatedAt: Date
    let body: String?

    var isMergeable: Bool {
        let status = mergeStateStatus.uppercased()
        return status == "CLEAN" || status == "HAS_HOOKS" || status == "UNSTABLE"
    }
}

struct TerminalOpenPullRequest: Identifiable, Equatable {
    let number: Int
    let title: String
    let headRefName: String
    let authorLogin: String
    let updatedAt: Date
    let isDraft: Bool
    let url: URL

    var id: Int { number }
}

enum TerminalReviewEvent: String, CaseIterable {
    case comment = "COMMENT"
    case approve = "APPROVE"
    case requestChanges = "REQUEST_CHANGES"

    var label: String {
        switch self {
        case .comment: return "Comment"
        case .approve: return "Approve"
        case .requestChanges: return "Request Changes"
        }
    }

    var icon: String {
        switch self {
        case .comment: return "text.bubble"
        case .approve: return "checkmark.circle"
        case .requestChanges: return "exclamationmark.triangle"
        }
    }
}

enum TerminalMergeMethod: String, CaseIterable {
    case squash = "squash"
    case merge = "merge"
    case rebase = "rebase"

    var label: String {
        switch self {
        case .squash: return "Squash and merge"
        case .merge: return "Create a merge commit"
        case .rebase: return "Rebase and merge"
        }
    }
}

struct TerminalPullRequestReviewComment: Identifiable, Equatable, Codable {
    let id: String
    let body: String
    let url: URL
    let authorLogin: String
    let createdAt: Date
    let path: String?
    let line: Int?
    let originalLine: Int?
    let startLine: Int?
    let originalStartLine: Int?
    let replyToID: String?
}

struct TerminalPullRequestReviewThread: Identifiable, Equatable, Codable {
    let id: String
    let path: String?
    let line: Int?
    let originalLine: Int?
    let startLine: Int?
    let originalStartLine: Int?
    let diffSide: String?
    let isResolved: Bool
    let isOutdated: Bool
    let comments: [TerminalPullRequestReviewComment]
    let hasMoreComments: Bool

    var updatedAt: Date {
        comments.map(\.createdAt).max() ?? .distantPast
    }

    var chatSummary: String {
        var summary = "File: \(path ?? "unknown")\n"
        if let startLine, let line, startLine != line {
            summary += "Lines \(startLine)-\(line)\n"
        } else if let line {
            summary += "Line \(line)\n"
        }
        for comment in comments {
            summary += "\(comment.authorLogin): \(comment.body)\n"
        }
        return summary
    }
}

struct TerminalRepositoryChangeFile: Identifiable, Equatable, Codable {
    let id: String
    let path: String
    let additions: Int
    let deletions: Int
    let isBinary: Bool
    let badges: [String]

    var sectionTitle: String?
}

// MARK: - Diff Models

enum DiffLineType: String, Codable {
    case context
    case added
    case removed
    case hunkHeader
}

struct SplitDiffRow: Identifiable, Equatable {
    let id: Int
    let left: DiffSide?
    let right: DiffSide?
    let isHunkHeader: Bool
    let hunkHeaderText: String?
}

struct DiffSide: Equatable {
    let lineNumber: Int
    let content: String
    let type: DiffLineType
}

struct TerminalLocalReviewComment: Identifiable, Equatable {
    let id: UUID
    let filePath: String
    let startLine: Int
    let endLine: Int
    let side: String
    let text: String
}

struct TerminalRepositoryChangeSection: Equatable, Codable {
    let title: String
    let files: [TerminalRepositoryChangeFile]
    let fileCount: Int
    let additions: Int
    let deletions: Int
    let message: String?
}

struct TerminalRepositoryChangeSummary: Equatable, Codable {
    let committed: TerminalRepositoryChangeSection
    let uncommitted: TerminalRepositoryChangeSection
    let baseBranchName: String?
}

struct TerminalCommitEntry: Identifiable, Equatable {
    let hash: String
    let shortHash: String
    let subject: String
    let authorName: String
    let relativeDate: String

    var id: String { hash }
}

struct TerminalBranchDescriptor: Identifiable, Equatable, Hashable, Codable {
    enum Kind: String, Codable {
        case local
        case remote
    }

    let kind: Kind
    let reference: String
    let name: String

    var id: String { "\(kind.rawValue):\(reference)" }

    var displayName: String {
        switch kind {
        case .local:
            return name
        case .remote:
            return reference
        }
    }

    var shortBranchName: String {
        switch kind {
        case .local:
            return reference
        case .remote:
            return TerminalRepositoryService.shortBranchName(for: reference)
        }
    }

    var pickerLabel: String {
        switch kind {
        case .local:
            return "Local: \(reference)"
        case .remote:
            return "Remote: \(reference)"
        }
    }
}

struct TerminalBranchCatalog: Equatable {
    let local: [TerminalBranchDescriptor]
    let remote: [TerminalBranchDescriptor]

    var all: [TerminalBranchDescriptor] { local + remote }
}

enum TerminalWorktreeSelection: Equatable {
    case existing(TerminalBranchDescriptor)
    case newBranch(name: String, base: TerminalBranchDescriptor)
}

struct TerminalWorktreeRequest: Equatable {
    let repositoryRoot: String
    let selection: TerminalWorktreeSelection
}

struct TerminalWorktreeCreationResult: Equatable {
    let workingDirectory: String
    let branchName: String
    let reusedExistingPath: Bool
}

// MARK: - TerminalRepositoryServiceError

enum TerminalRepositoryServiceError: Error, LocalizedError {
    case missingWorkingDirectory
    case notARepository
    case detachedHead
    case ghUnavailable
    case noPullRequest
    case ghAuthenticationRequired
    case invalidResponse(String)
    case invalidExistingWorktree(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingWorkingDirectory:
            return "No working directory is available for the selected tab."
        case .notARepository:
            return "The selected tab is not inside a Git repository."
        case .detachedHead:
            return "The selected tab is on a detached HEAD, so there is no branch PR to display."
        case .ghUnavailable:
            return "`gh` is not available in PATH."
        case .noPullRequest:
            return "No pull request was found for the current branch."
        case .ghAuthenticationRequired:
            return "`gh` is not authenticated for this repository."
        case let .invalidResponse(message):
            return message
        case let .invalidExistingWorktree(path):
            return "The existing path at \(path) is not the requested worktree."
        case let .commandFailed(message):
            return message
        }
    }
}

// MARK: - TerminalRepositoryService

actor TerminalRepositoryService {
    static let shared = TerminalRepositoryService()

    private let workspaceRoot: URL
    private var preferredBaseBranchRefreshDates: [String: Date] = [:]
    private static let preferredBaseBranchRefreshInterval: TimeInterval = 30

    private struct PullRequestPayload: Decodable {
        let id: String?
        let number: Int
        let title: String
        let url: String
        let mergeStateStatus: String
        let baseRefName: String
        let updatedAt: Date
        let body: String?
    }

    private struct OpenPullRequestPayload: Decodable {
        struct AuthorPayload: Decodable {
            let login: String
        }

        let number: Int
        let title: String
        let url: String
        let headRefName: String
        let author: AuthorPayload?
        let updatedAt: Date
        let isDraft: Bool
    }

    private struct PullRequestCheckPayload: Decodable {
        let name: String
        let link: String?
        let bucket: String
        let state: String
        let workflow: String?
        let description: String?
        let startedAt: Date?
        let completedAt: Date?
    }

    private struct DefaultBranchPayload: Decodable {
        struct BranchRef: Decodable {
            let name: String
        }

        let defaultBranchRef: BranchRef?
    }

    private struct ReviewThreadsResponse: Decodable {
        let data: DataPayload

        struct DataPayload: Decodable {
            let repository: RepositoryPayload?
        }

        struct RepositoryPayload: Decodable {
            let pullRequest: PullRequestPayload?
        }

        struct PullRequestPayload: Decodable {
            let reviewThreads: ReviewThreadConnection
        }

        struct ReviewThreadConnection: Decodable {
            let nodes: [ReviewThreadNode]
            let pageInfo: PageInfo
        }

        struct PageInfo: Decodable {
            let hasNextPage: Bool
            let endCursor: String?
        }

        struct ReviewThreadNode: Decodable {
            let id: String
            let path: String?
            let line: Int?
            let originalLine: Int?
            let startLine: Int?
            let originalStartLine: Int?
            let diffSide: String?
            let isResolved: Bool
            let isOutdated: Bool
            let comments: ReviewCommentConnection
        }

        struct ReviewCommentConnection: Decodable {
            let totalCount: Int
            let nodes: [ReviewCommentNode]
        }

        struct ReviewCommentNode: Decodable {
            struct AuthorPayload: Decodable {
                let login: String
            }

            struct ReplyToPayload: Decodable {
                let id: String
            }

            let id: String
            let body: String
            let url: String
            let createdAt: Date
            let author: AuthorPayload?
            let path: String?
            let line: Int?
            let originalLine: Int?
            let startLine: Int?
            let originalStartLine: Int?
            let replyTo: ReplyToPayload?
        }
    }

    init(
        workspaceRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".workspace", isDirectory: true)
    ) {
        self.workspaceRoot = workspaceRoot
    }

    // MARK: Context Resolution

    func resolveContext(for workingDirectory: String?) async throws -> TerminalRepositoryContext {
        guard let workingDirectory, !workingDirectory.isEmpty else {
            throw TerminalRepositoryServiceError.missingWorkingDirectory
        }

        do {
            let repositoryRoot = try await git(
                ["-C", workingDirectory, "rev-parse", "--show-toplevel"]
            ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)

            let branchName = try await git(
                ["-C", workingDirectory, "rev-parse", "--abbrev-ref", "HEAD"]
            ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)

            guard branchName != "HEAD" else {
                throw TerminalRepositoryServiceError.detachedHead
            }

            return TerminalRepositoryContext(
                workingDirectory: workingDirectory,
                repositoryRoot: repositoryRoot,
                repositoryName: URL(fileURLWithPath: repositoryRoot).lastPathComponent,
                branchName: branchName
            )
        } catch let error as TerminalCommandError {
            if case .nonZeroExit = error {
                throw TerminalRepositoryServiceError.notARepository
            }

            throw TerminalRepositoryServiceError.commandFailed(error.localizedDescription)
        } catch let error as TerminalRepositoryServiceError {
            throw error
        } catch {
            throw TerminalRepositoryServiceError.commandFailed(error.localizedDescription)
        }
    }

    func resolveWatchTargets(for context: TerminalRepositoryContext) async throws -> TerminalRepositoryWatchTargets {
        let repositoryRoot = URL(fileURLWithPath: context.repositoryRoot).standardizedFileURL.path
        let gitDirectory = try await git(
            ["-C", context.workingDirectory, "rev-parse", "--path-format=absolute", "--git-dir"]
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let gitCommonDirectory = try await git(
            ["-C", context.workingDirectory, "rev-parse", "--path-format=absolute", "--git-common-dir"]
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        return TerminalRepositoryWatchTargets(
            repositoryRoot: repositoryRoot,
            gitDirectory: URL(fileURLWithPath: gitDirectory).standardizedFileURL.path,
            gitCommonDirectory: URL(fileURLWithPath: gitCommonDirectory).standardizedFileURL.path
        )
    }

    func fetchLocalRepositoryState(
        for context: TerminalRepositoryContext,
        preferredBaseBranch: String?
    ) async throws -> TerminalLocalRepositoryState {
        let changes = try await fetchRepositoryChanges(
            for: context,
            preferredBaseBranch: preferredBaseBranch,
            allowRemoteQueries: false
        )
        let commits = try await fetchCommitLog(
            for: context,
            preferredBaseBranch: preferredBaseBranch,
            allowRemoteQueries: false
        )
        let filePaths = try await listRepositoryFiles(repositoryRoot: context.repositoryRoot)

        return TerminalLocalRepositoryState(
            changeSummary: changes,
            commitEntries: commits,
            filePaths: filePaths
        )
    }

    func fetchPullRequestSummary(for context: TerminalRepositoryContext) async throws -> TerminalPullRequestSummary {
        let prOutput: TerminalCommandOutput
        do {
            prOutput = try await gh(
                [
                    "pr",
                    "view",
                    "--json",
                    "id,number,title,url,mergeStateStatus,baseRefName,updatedAt,body",
                ],
                currentDirectory: context.repositoryRoot
            )
        } catch let error as TerminalCommandError {
            throw mapGHError(error)
        }

        let decoder = Self.jsonDecoder()
        let payload: PullRequestPayload
        do {
            payload = try decoder.decode(PullRequestPayload.self, from: Data(prOutput.stdout.utf8))
        } catch {
            throw TerminalRepositoryServiceError.invalidResponse("Unable to decode pull request details from `gh pr view`.")
        }

        guard let url = URL(string: payload.url) else {
            throw TerminalRepositoryServiceError.invalidResponse("`gh pr view` returned an invalid pull request URL.")
        }

        return TerminalPullRequestSummary(
            nodeID: payload.id,
            number: payload.number,
            title: payload.title,
            url: url,
            mergeStateStatus: payload.mergeStateStatus,
            baseRefName: payload.baseRefName,
            updatedAt: payload.updatedAt,
            body: payload.body
        )
    }

    func replyToReviewThread(
        for context: TerminalRepositoryContext,
        pullRequestNumber: Int,
        commentID: String,
        body: String
    ) async throws {
        let query = """
        mutation($pullRequestReviewThreadId: ID!, $body: String!) {
          addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $pullRequestReviewThreadId, body: $body}) {
            comment {
              id
            }
          }
        }
        """
        do {
            _ = try await gh(
                [
                    "api", "graphql",
                    "-F", "pullRequestReviewThreadId=\(commentID)",
                    "-f", "body=\(body)",
                    "-f", "query=\(query)",
                ],
                currentDirectory: context.repositoryRoot
            )
        } catch let error as TerminalCommandError {
            throw mapGHError(error)
        }
    }

    func updatePullRequestBody(
        repositoryRoot: String,
        body: String
    ) async throws {
        do {
            _ = try await gh(
                ["pr", "edit", "--body", body],
                currentDirectory: repositoryRoot
            )
        } catch let error as TerminalCommandError {
            throw mapGHError(error)
        }
    }

    func resolveReviewThread(
        for context: TerminalRepositoryContext,
        threadID: String
    ) async throws {
        let query = """
        mutation($threadId: ID!) {
          resolveReviewThread(input: {threadId: $threadId}) {
            thread {
              isResolved
            }
          }
        }
        """
        do {
            _ = try await gh(
                [
                    "api", "graphql",
                    "-F", "threadId=\(threadID)",
                    "-f", "query=\(query)",
                ],
                currentDirectory: context.repositoryRoot
            )
        } catch let error as TerminalCommandError {
            throw mapGHError(error)
        }
    }

    func unresolveReviewThread(
        for context: TerminalRepositoryContext,
        threadID: String
    ) async throws {
        let query = """
        mutation($threadId: ID!) {
          unresolveReviewThread(input: {threadId: $threadId}) {
            thread {
              isResolved
            }
          }
        }
        """
        do {
            _ = try await gh(
                [
                    "api", "graphql",
                    "-F", "threadId=\(threadID)",
                    "-f", "query=\(query)",
                ],
                currentDirectory: context.repositoryRoot
            )
        } catch let error as TerminalCommandError {
            throw mapGHError(error)
        }
    }

    func mergePullRequest(
        for context: TerminalRepositoryContext,
        method: TerminalMergeMethod
    ) async throws {
        do {
            _ = try await gh(
                ["pr", "merge", "--\(method.rawValue)", "--delete-branch"],
                currentDirectory: context.repositoryRoot
            )
        } catch let error as TerminalCommandError {
            throw mapGHError(error)
        }
    }

    func fetchOpenPullRequests(repositoryRoot: String) async throws -> [TerminalOpenPullRequest] {
        let resolvedRoot: String
        do {
            resolvedRoot = try await git(
                ["-C", repositoryRoot, "rev-parse", "--show-toplevel"]
            ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw TerminalRepositoryServiceError.notARepository
        }

        let output: TerminalCommandOutput
        do {
            output = try await gh(
                [
                    "pr", "list",
                    "--state", "open",
                    "--json", "number,title,url,headRefName,author,updatedAt,isDraft",
                    "--limit", "100",
                ],
                currentDirectory: resolvedRoot
            )
        } catch let error as TerminalCommandError {
            throw mapGHError(error)
        }

        let decoder = Self.jsonDecoder()
        let payloads: [OpenPullRequestPayload]
        do {
            payloads = try decoder.decode([OpenPullRequestPayload].self, from: Data(output.stdout.utf8))
        } catch {
            throw TerminalRepositoryServiceError.invalidResponse("Unable to decode open pull requests from `gh pr list`.")
        }

        return payloads.compactMap { payload in
            guard let url = URL(string: payload.url) else { return nil }
            return TerminalOpenPullRequest(
                number: payload.number,
                title: payload.title,
                headRefName: payload.headRefName,
                authorLogin: payload.author?.login ?? "unknown",
                updatedAt: payload.updatedAt,
                isDraft: payload.isDraft,
                url: url
            )
        }
    }

    func fetchRemoteBranch(repositoryRoot: String, branchName: String) async throws {
        _ = try? await git(
            ["-C", repositoryRoot, "fetch", "origin",
             "refs/heads/\(branchName):refs/remotes/origin/\(branchName)"],
            acceptedExitCodes: [0, 1, 128]
        )
    }

    private func refreshPreferredBaseBranchIfNeeded(
        repositoryRoot: String,
        preferredBaseBranch: String?
    ) async {
        guard let preferredBaseBranch = preferredBaseBranch?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !preferredBaseBranch.isEmpty else {
            return
        }

        let standardizedRoot = URL(fileURLWithPath: repositoryRoot).standardizedFileURL.path
        let refreshKey = "\(standardizedRoot)::\(preferredBaseBranch)"
        let now = Date()

        if let lastRefresh = preferredBaseBranchRefreshDates[refreshKey],
           now.timeIntervalSince(lastRefresh) < Self.preferredBaseBranchRefreshInterval {
            return
        }

        preferredBaseBranchRefreshDates[refreshKey] = now
        try? await fetchRemoteBranch(
            repositoryRoot: repositoryRoot,
            branchName: preferredBaseBranch
        )
    }

    func submitPullRequestReview(
        for context: TerminalRepositoryContext,
        nodeID: String,
        event: TerminalReviewEvent,
        body: String?,
        comments: [TerminalLocalReviewComment]
    ) async throws {
        let query: String
        if comments.isEmpty {
            query = """
            mutation($pullRequestId: ID!, $event: PullRequestReviewEvent!, $body: String) {
              addPullRequestReview(input: {pullRequestId: $pullRequestId, event: $event, body: $body}) {
                pullRequestReview { id }
              }
            }
            """
        } else {
            query = """
            mutation($pullRequestId: ID!, $event: PullRequestReviewEvent!, $body: String, $threads: [DraftPullRequestReviewThread!]) {
              addPullRequestReview(input: {pullRequestId: $pullRequestId, event: $event, body: $body, threads: $threads}) {
                pullRequestReview { id }
              }
            }
            """
        }

        var variables: [String: Any] = [
            "pullRequestId": nodeID,
            "event": event.rawValue,
            "body": body ?? "",
        ]

        if !comments.isEmpty {
            var threads: [[String: Any]] = []
            for comment in comments {
                var thread: [String: Any] = [
                    "path": comment.filePath,
                    "line": comment.endLine,
                    "body": comment.text,
                    "side": comment.side == "old" ? "LEFT" : "RIGHT",
                ]
                if comment.startLine != comment.endLine {
                    thread["startLine"] = comment.startLine
                    thread["startSide"] = comment.side == "old" ? "LEFT" : "RIGHT"
                }
                threads.append(thread)
            }
            variables["threads"] = threads
        }

        let requestBody: [String: Any] = [
            "query": query,
            "variables": variables,
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-review-\(UUID().uuidString).json")
        try jsonData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            _ = try await gh(
                ["api", "graphql", "--input", tempURL.path],
                currentDirectory: context.repositoryRoot
            )
        } catch let error as TerminalCommandError {
            throw mapGHError(error)
        }
    }

    func fetchPullRequestChecks(for context: TerminalRepositoryContext) async throws -> [TerminalPullRequestCheck] {
        let checksOutput: TerminalCommandOutput
        do {
            checksOutput = try await gh(
                [
                    "pr",
                    "checks",
                    "--json",
                    "name,link,bucket,state,workflow,description,startedAt,completedAt",
                ],
                currentDirectory: context.repositoryRoot,
                acceptedExitCodes: [0, 8]
            )
        } catch let error as TerminalCommandError {
            throw mapGHError(error)
        }

        let decoder = Self.jsonDecoder()
        let checkPayloads: [PullRequestCheckPayload]
        do {
            checkPayloads = try decoder.decode([PullRequestCheckPayload].self, from: Data(checksOutput.stdout.utf8))
        } catch {
            throw TerminalRepositoryServiceError.invalidResponse("Unable to decode check results from `gh pr checks`.")
        }

        return checkPayloads.map { payload in
            TerminalPullRequestCheck(
                id: payload.link ?? payload.name,
                name: payload.name,
                link: payload.link.flatMap(URL.init(string:)),
                bucket: payload.bucket,
                state: payload.state,
                workflow: payload.workflow,
                description: payload.description,
                startedAt: payload.startedAt,
                completedAt: payload.completedAt
            )
        }
    }

    func fetchReviewThreads(
        for context: TerminalRepositoryContext,
        pullRequestNumber: Int
    ) async throws -> [TerminalPullRequestReviewThread] {
        var allThreads: [TerminalPullRequestReviewThread] = []
        var endCursor: String?

        while true {
            let query = """
            query($owner: String!, $repo: String!, $number: Int!, $cursor: String) {
              repository(owner: $owner, name: $repo) {
                pullRequest(number: $number) {
                  reviewThreads(first: 100, after: $cursor) {
                    nodes {
                      id
                      path
                      line
                      originalLine
                      startLine
                      originalStartLine
                      diffSide
                      isResolved
                      isOutdated
                      comments(first: 100) {
                        totalCount
                        nodes {
                          id
                          body
                          url
                          createdAt
                          author {
                            login
                          }
                          path
                          line
                          originalLine
                          startLine
                          originalStartLine
                          replyTo {
                            id
                          }
                        }
                      }
                    }
                    pageInfo {
                      hasNextPage
                      endCursor
                    }
                  }
                }
              }
            }
            """

            var arguments = [
                "api",
                "graphql",
                "-F",
                "owner={owner}",
                "-F",
                "repo={repo}",
                "-F",
                "number=\(pullRequestNumber)",
                "-f",
                "query=\(query)",
            ]
            if let endCursor {
                arguments.append(contentsOf: ["-F", "cursor=\(endCursor)"])
            }

            let output: TerminalCommandOutput
            do {
                output = try await gh(arguments, currentDirectory: context.repositoryRoot)
            } catch let error as TerminalCommandError {
                throw mapGHError(error)
            }

            let payload: ReviewThreadsResponse
            do {
                payload = try Self.jsonDecoder().decode(ReviewThreadsResponse.self, from: Data(output.stdout.utf8))
            } catch {
                throw TerminalRepositoryServiceError.invalidResponse("Unable to decode pull request review comments from GitHub.")
            }

            guard let connection = payload.data.repository?.pullRequest?.reviewThreads else {
                return allThreads
            }

            allThreads.append(contentsOf: connection.nodes.map(Self.makeReviewThread))
            guard connection.pageInfo.hasNextPage, let cursor = connection.pageInfo.endCursor else {
                return allThreads.sorted { $0.updatedAt > $1.updatedAt }
            }

            endCursor = cursor
        }
    }

    func fetchRepositoryChanges(
        for context: TerminalRepositoryContext,
        preferredBaseBranch: String?,
        allowRemoteQueries: Bool = true
    ) async throws -> TerminalRepositoryChangeSummary {
        await refreshPreferredBaseBranchIfNeeded(
            repositoryRoot: context.repositoryRoot,
            preferredBaseBranch: preferredBaseBranch
        )
        let baseBranchName = try await resolveBaseBranchName(
            for: context,
            preferredBaseBranch: preferredBaseBranch,
            allowRemoteQueries: allowRemoteQueries
        )
        let committed = try await committedSection(
            repositoryRoot: context.repositoryRoot,
            baseBranchName: baseBranchName
        )
        let uncommitted = try await uncommittedSection(repositoryRoot: context.repositoryRoot)

        return TerminalRepositoryChangeSummary(
            committed: committed,
            uncommitted: uncommitted,
            baseBranchName: baseBranchName
        )
    }

    func fetchAllChangesDiff(
        for context: TerminalRepositoryContext,
        section: String,
        preferredBaseBranch: String?
    ) async throws -> String {
        let repositoryRoot = context.repositoryRoot

        if section == "Committed" {
            await refreshPreferredBaseBranchIfNeeded(
                repositoryRoot: repositoryRoot,
                preferredBaseBranch: preferredBaseBranch
            )
            let baseBranchName = try await resolveBaseBranchName(
                for: context,
                preferredBaseBranch: preferredBaseBranch,
                allowRemoteQueries: true
            )
            if let baseBranchName,
               let baseRef = try await resolveExistingBaseReference(
                   repositoryRoot: repositoryRoot,
                   branchName: baseBranchName
               ),
               let mergeBase = try await resolveMergeBase(
                   repositoryRoot: repositoryRoot,
                   baseReference: baseRef
               ) {
                return try await git(
                    ["-C", repositoryRoot, "diff", "-U3", mergeBase, "HEAD"],
                    acceptedExitCodes: [0, 1]
                ).stdout
            }
            return ""
        } else {
            return try await git(
                ["-C", repositoryRoot, "diff", "-U3", "HEAD"],
                acceptedExitCodes: [0, 1]
            ).stdout
        }
    }

    func fetchCommitLog(
        for context: TerminalRepositoryContext,
        preferredBaseBranch: String?,
        allowRemoteQueries: Bool = true
    ) async throws -> [TerminalCommitEntry] {
        let repositoryRoot = context.repositoryRoot
        await refreshPreferredBaseBranchIfNeeded(
            repositoryRoot: repositoryRoot,
            preferredBaseBranch: preferredBaseBranch
        )
        let baseBranchName = try await resolveBaseBranchName(
            for: context,
            preferredBaseBranch: preferredBaseBranch,
            allowRemoteQueries: allowRemoteQueries
        )

        guard let baseBranchName,
              let baseRef = try await resolveExistingBaseReference(
                  repositoryRoot: repositoryRoot,
                  branchName: baseBranchName
              ) else {
            return []
        }

        guard let mergeBase = try await resolveMergeBase(
            repositoryRoot: repositoryRoot,
            baseReference: baseRef
        ) else {
            return []
        }

        let logOutput = try await git(
            ["-C", repositoryRoot, "log", "--format=%H%n%h%n%s%n%an%n%cr", "\(mergeBase)..HEAD"]
        ).stdout

        let lines = logOutput.components(separatedBy: "\n")
        var entries: [TerminalCommitEntry] = []
        var i = 0
        while i + 4 < lines.count {
            let hash = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            let shortHash = lines[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = lines[i + 2].trimmingCharacters(in: .whitespacesAndNewlines)
            let author = lines[i + 3].trimmingCharacters(in: .whitespacesAndNewlines)
            let date = lines[i + 4].trimmingCharacters(in: .whitespacesAndNewlines)
            if !hash.isEmpty {
                entries.append(TerminalCommitEntry(
                    hash: hash,
                    shortHash: shortHash,
                    subject: subject,
                    authorName: author,
                    relativeDate: date
                ))
            }
            i += 5
        }
        return entries
    }

    func fetchCommitDiff(
        repositoryRoot: String,
        commitHash: String
    ) async throws -> String {
        return try await git(
            ["-C", repositoryRoot, "diff", "-U3", "\(commitHash)~1", commitHash],
            acceptedExitCodes: [0, 1]
        ).stdout
    }

    func fetchFileDiffRaw(
        for context: TerminalRepositoryContext,
        file: TerminalRepositoryChangeFile,
        preferredBaseBranch: String?
    ) async throws -> String {
        let repositoryRoot = context.repositoryRoot
        let isCommitted = file.sectionTitle == "Committed"

        if isCommitted {
            await refreshPreferredBaseBranchIfNeeded(
                repositoryRoot: repositoryRoot,
                preferredBaseBranch: preferredBaseBranch
            )
            let baseBranchName = try await resolveBaseBranchName(
                for: context,
                preferredBaseBranch: preferredBaseBranch,
                allowRemoteQueries: true
            )
            if let baseBranchName,
               let baseRef = try await resolveExistingBaseReference(
                   repositoryRoot: repositoryRoot,
                   branchName: baseBranchName
               ),
               let mergeBase = try await resolveMergeBase(
                   repositoryRoot: repositoryRoot,
                   baseReference: baseRef
               ) {
                return try await git(
                    ["-C", repositoryRoot, "diff", "-U3", mergeBase, "HEAD", "--", file.path],
                    acceptedExitCodes: [0, 1]
                ).stdout
            } else {
                return ""
            }
        } else {
            return try await git(
                ["-C", repositoryRoot, "diff", "-U3", "HEAD", "--", file.path],
                acceptedExitCodes: [0, 1]
            ).stdout
        }
    }

    func fetchFileDiff(
        for context: TerminalRepositoryContext,
        file: TerminalRepositoryChangeFile,
        preferredBaseBranch: String?
    ) async throws -> [SplitDiffRow] {
        let rawDiff = try await fetchFileDiffRaw(
            for: context,
            file: file,
            preferredBaseBranch: preferredBaseBranch
        )
        return Self.parseUnifiedDiffToSplitRows(rawDiff)
    }

    static func parseUnifiedDiffToSplitRows(_ diff: String) -> [SplitDiffRow] {
        guard !diff.isEmpty else { return [] }

        let lines = diff.components(separatedBy: "\n")
        var rows: [SplitDiffRow] = []
        var rowID = 0
        var oldLine = 0
        var newLine = 0
        var inHeader = true

        var pendingRemoved: [(Int, String)] = []
        var pendingAdded: [(Int, String)] = []

        func flushPending() {
            let maxCount = max(pendingRemoved.count, pendingAdded.count)
            for i in 0..<maxCount {
                let left: DiffSide? = i < pendingRemoved.count
                    ? DiffSide(lineNumber: pendingRemoved[i].0, content: pendingRemoved[i].1, type: .removed)
                    : nil
                let right: DiffSide? = i < pendingAdded.count
                    ? DiffSide(lineNumber: pendingAdded[i].0, content: pendingAdded[i].1, type: .added)
                    : nil
                rows.append(SplitDiffRow(id: rowID, left: left, right: right, isHunkHeader: false, hunkHeaderText: nil))
                rowID += 1
            }
            pendingRemoved.removeAll()
            pendingAdded.removeAll()
        }

        let hunkRegex = try? NSRegularExpression(pattern: #"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)"#)

        for line in lines {
            if inHeader {
                if line.hasPrefix("diff --git") || line.hasPrefix("index ") ||
                    line.hasPrefix("old mode") || line.hasPrefix("new mode") ||
                    line.hasPrefix("similarity index") || line.hasPrefix("rename from") ||
                    line.hasPrefix("rename to") || line.hasPrefix("new file mode") ||
                    line.hasPrefix("deleted file mode") ||
                    line.hasPrefix("---") || line.hasPrefix("+++") {
                    continue
                }
                if line.hasPrefix("Binary files") || line.contains("GIT binary patch") {
                    continue
                }
                if line.hasPrefix("@@") {
                    inHeader = false
                } else {
                    continue
                }
            }

            if line.hasPrefix("\\ No newline at end of file") || line.hasPrefix("\\") {
                continue
            }

            if line.hasPrefix("diff --git") {
                flushPending()
                inHeader = true
                continue
            }

            if line.hasPrefix("@@") {
                flushPending()
                let nsLine = line as NSString
                if let match = hunkRegex?.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)),
                   match.numberOfRanges >= 4 {
                    oldLine = Int(nsLine.substring(with: match.range(at: 1))) ?? 0
                    newLine = Int(nsLine.substring(with: match.range(at: 3))) ?? 0
                }
                rows.append(SplitDiffRow(id: rowID, left: nil, right: nil, isHunkHeader: true, hunkHeaderText: line))
                rowID += 1
                continue
            }

            if line.hasPrefix("-") {
                let content = String(line.dropFirst())
                pendingRemoved.append((oldLine, content))
                oldLine += 1
            } else if line.hasPrefix("+") {
                let content = String(line.dropFirst())
                pendingAdded.append((newLine, content))
                newLine += 1
            } else {
                flushPending()
                let content = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                if !line.isEmpty || oldLine > 0 {
                    rows.append(SplitDiffRow(
                        id: rowID,
                        left: DiffSide(lineNumber: oldLine, content: content, type: .context),
                        right: DiffSide(lineNumber: newLine, content: content, type: .context),
                        isHunkHeader: false,
                        hunkHeaderText: nil
                    ))
                    rowID += 1
                    oldLine += 1
                    newLine += 1
                }
            }
        }

        flushPending()
        return rows
    }

    func listBranches(in repositoryRoot: String) async throws -> TerminalBranchCatalog {
        let output = try await git(
            [
                "-C",
                repositoryRoot,
                "for-each-ref",
                "--format=%(refname)",
                "refs/heads",
                "refs/remotes",
            ]
        ).stdout

        var local: [TerminalBranchDescriptor] = []
        var remote: [TerminalBranchDescriptor] = []

        for line in output.split(whereSeparator: \.isNewline) {
            let ref = String(line)
            if ref.hasPrefix("refs/heads/") {
                let name = String(ref.dropFirst("refs/heads/".count))
                local.append(
                    TerminalBranchDescriptor(kind: .local, reference: name, name: name)
                )
                continue
            }

            guard ref.hasPrefix("refs/remotes/") else { continue }
            let name = String(ref.dropFirst("refs/remotes/".count))
            guard !name.hasSuffix("/HEAD") else { continue }
            remote.append(
                TerminalBranchDescriptor(kind: .remote, reference: name, name: Self.shortBranchName(for: name))
            )
        }

        local.sort { $0.reference.localizedStandardCompare($1.reference) == .orderedAscending }
        remote.sort { $0.reference.localizedStandardCompare($1.reference) == .orderedAscending }

        return TerminalBranchCatalog(local: local, remote: remote)
    }

    func createOrReuseWorktree(request: TerminalWorktreeRequest) async throws -> TerminalWorktreeCreationResult {
        let repositoryRoot = request.repositoryRoot

        let branchName: String
        let worktreePath: String
        switch request.selection {
        case let .existing(branch):
            branchName = branch.shortBranchName
            worktreePath = Self.defaultWorktreePath(
                repositoryName: repositoryRoot,
                branchName: branchName,
                workspaceRoot: workspaceRoot
            )
        case let .newBranch(name, _):
            branchName = name
            worktreePath = Self.defaultWorktreePath(
                repositoryName: repositoryRoot,
                branchName: name,
                workspaceRoot: workspaceRoot
            )
        }

        if let existingPath = try await findExistingWorktreePath(
            repositoryRoot: repositoryRoot,
            branchName: branchName
        ) {
            return TerminalWorktreeCreationResult(
                workingDirectory: existingPath,
                branchName: branchName,
                reusedExistingPath: true
            )
        }

        if FileManager.default.fileExists(atPath: worktreePath) {
            guard try await validateExistingWorktree(
                at: worktreePath,
                repositoryRoot: repositoryRoot,
                expectedBranch: branchName
            ) else {
                throw TerminalRepositoryServiceError.invalidExistingWorktree(worktreePath)
            }

            return TerminalWorktreeCreationResult(
                workingDirectory: worktreePath,
                branchName: branchName,
                reusedExistingPath: true
            )
        }

        let worktreeDirectoryURL = URL(fileURLWithPath: worktreePath).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: worktreeDirectoryURL,
            withIntermediateDirectories: true
        )

        switch request.selection {
        case let .existing(branch):
            if branch.kind == .remote {
                try await ensureTrackingBranchExists(
                    repositoryRoot: repositoryRoot,
                    localBranch: branch.shortBranchName,
                    remoteReference: branch.reference
                )
            }

            _ = try await git(
                [
                    "-C",
                    repositoryRoot,
                    "worktree",
                    "add",
                    worktreePath,
                    branch.shortBranchName,
                ]
            )

        case let .newBranch(name, base):
            _ = try await git(
                [
                    "-C",
                    repositoryRoot,
                    "worktree",
                    "add",
                    "-b",
                    name,
                    worktreePath,
                    base.reference,
                ]
            )
        }

        return TerminalWorktreeCreationResult(
            workingDirectory: worktreePath,
            branchName: branchName,
            reusedExistingPath: false
        )
    }

    private func validateExistingWorktree(
        at path: String,
        repositoryRoot: String,
        expectedBranch: String
    ) async throws -> Bool {
        do {
            let root = try await git(
                ["-C", path, "rev-parse", "--show-toplevel"]
            ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let branch = try await git(
                ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"]
            ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let worktreeCommonDirectory = try await git(
                ["-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"]
            ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let repositoryCommonDirectory = try await git(
                ["-C", repositoryRoot, "rev-parse", "--path-format=absolute", "--git-common-dir"]
            ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)

            let standardizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
            let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            let standardizedWorktreeCommonDirectory = URL(
                fileURLWithPath: worktreeCommonDirectory
            ).standardizedFileURL.path
            let standardizedRepositoryCommonDirectory = URL(
                fileURLWithPath: repositoryCommonDirectory
            ).standardizedFileURL.path
            return standardizedRoot == standardizedPath &&
                branch == expectedBranch &&
                standardizedWorktreeCommonDirectory == standardizedRepositoryCommonDirectory
        } catch {
            return false
        }
    }

    private func findExistingWorktreePath(
        repositoryRoot: String,
        branchName: String
    ) async throws -> String? {
        let output: TerminalCommandOutput
        do {
            output = try await git(
                ["-C", repositoryRoot, "worktree", "list", "--porcelain"],
                acceptedExitCodes: [0]
            )
        } catch {
            return nil
        }

        let blocks = output.stdout.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.components(separatedBy: "\n")
            var path: String?
            var branch: String?
            for line in lines {
                if line.hasPrefix("worktree ") {
                    path = String(line.dropFirst("worktree ".count))
                } else if line.hasPrefix("branch refs/heads/") {
                    branch = String(line.dropFirst("branch refs/heads/".count))
                }
            }
            if let path, let branch, branch == branchName {
                let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
                let standardizedRoot = URL(fileURLWithPath: repositoryRoot).standardizedFileURL.path
                if standardizedPath != standardizedRoot {
                    return standardizedPath
                }
            }
        }
        return nil
    }

    private func ensureTrackingBranchExists(
        repositoryRoot: String,
        localBranch: String,
        remoteReference: String
    ) async throws {
        if (try? await git(
            ["-C", repositoryRoot, "rev-parse", "--verify", "--quiet", "refs/heads/\(localBranch)"]
        )) != nil {
            return
        }

        _ = try await git(
            [
                "-C",
                repositoryRoot,
                "branch",
                "--track",
                localBranch,
                remoteReference,
            ]
        )
    }

    private func resolveBaseBranchName(
        for context: TerminalRepositoryContext,
        preferredBaseBranch: String?,
        allowRemoteQueries: Bool
    ) async throws -> String? {
        if let preferredBaseBranch, !preferredBaseBranch.isEmpty {
            return preferredBaseBranch
        }

        if allowRemoteQueries,
           let branch = try await defaultBranchNameFromGH(repositoryRoot: context.repositoryRoot) {
            return branch
        }

        if let remoteHead = try await originHeadBranchName(repositoryRoot: context.repositoryRoot) {
            return remoteHead
        }

        if try await branchExists(named: "main", repositoryRoot: context.repositoryRoot) {
            return "main"
        }

        if try await branchExists(named: "master", repositoryRoot: context.repositoryRoot) {
            return "master"
        }

        return nil
    }

    private func defaultBranchNameFromGH(repositoryRoot: String) async throws -> String? {
        let output: TerminalCommandOutput
        do {
            output = try await gh(
                ["repo", "view", "--json", "defaultBranchRef"],
                currentDirectory: repositoryRoot
            )
        } catch let error as TerminalCommandError {
            let mapped = mapGHError(error)
            switch mapped {
            case .ghUnavailable, .ghAuthenticationRequired, .commandFailed(_):
                return nil
            case .missingWorkingDirectory, .notARepository, .detachedHead, .noPullRequest,
                    .invalidResponse(_), .invalidExistingWorktree(_):
                return nil
            }
        }

        let payload = try? Self.jsonDecoder().decode(DefaultBranchPayload.self, from: Data(output.stdout.utf8))
        return payload?.defaultBranchRef?.name
    }

    private func originHeadBranchName(repositoryRoot: String) async throws -> String? {
        let output = try await git(
            [
                "-C",
                repositoryRoot,
                "symbolic-ref",
                "--quiet",
                "--short",
                "refs/remotes/origin/HEAD",
            ],
            acceptedExitCodes: [0, 1]
        )
        let value = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return Self.shortBranchName(for: value)
    }

    private func branchExists(named branchName: String, repositoryRoot: String) async throws -> Bool {
        let output = try await git(
            [
                "-C",
                repositoryRoot,
                "rev-parse",
                "--verify",
                "--quiet",
                "refs/heads/\(branchName)",
            ],
            acceptedExitCodes: [0, 1]
        )
        return output.exitCode == 0
    }

    private func committedSection(
        repositoryRoot: String,
        baseBranchName: String?
    ) async throws -> TerminalRepositoryChangeSection {
        guard let baseBranchName else {
            return TerminalRepositoryChangeSection(
                title: "Committed",
                files: [],
                fileCount: 0,
                additions: 0,
                deletions: 0,
                message: "Unable to determine a base branch for committed changes."
            )
        }

        guard let baseReference = try await resolveExistingBaseReference(
            repositoryRoot: repositoryRoot,
            branchName: baseBranchName
        ) else {
            return TerminalRepositoryChangeSection(
                title: "Committed",
                files: [],
                fileCount: 0,
                additions: 0,
                deletions: 0,
                message: "Unable to resolve `\(baseBranchName)` in this repository."
            )
        }

        guard let mergeBase = try await resolveMergeBase(
            repositoryRoot: repositoryRoot,
            baseReference: baseReference
        ) else {
            return TerminalRepositoryChangeSection(
                title: "Committed",
                files: [],
                fileCount: 0,
                additions: 0,
                deletions: 0,
                message: "Current branch does not share a merge base with `\(baseBranchName)`."
            )
        }

        let numstat = try await git(
            ["-C", repositoryRoot, "diff", "--numstat", mergeBase, "HEAD"]
        ).stdout
        let files = Self.parseNumstatFiles(numstat, badges: [])
        return Self.changeSection(title: "Committed", files: files)
    }

    private func resolveExistingBaseReference(
        repositoryRoot: String,
        branchName: String
    ) async throws -> String? {
        let candidates = [
            "refs/remotes/origin/\(branchName)",
            "refs/heads/\(branchName)",
            branchName,
        ]

        for candidate in candidates {
            let output = try await git(
                ["-C", repositoryRoot, "rev-parse", "--verify", "--quiet", candidate],
                acceptedExitCodes: [0, 1]
            )
            if output.exitCode == 0 {
                return candidate
            }
        }

        return nil
    }

    private func resolveMergeBase(
        repositoryRoot: String,
        baseReference: String
    ) async throws -> String? {
        let output = try await git(
            ["-C", repositoryRoot, "merge-base", baseReference, "HEAD"],
            acceptedExitCodes: [0, 1]
        )
        guard output.exitCode == 0 else { return nil }

        let mergeBase = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return mergeBase.isEmpty ? nil : mergeBase
    }

    private func uncommittedSection(repositoryRoot: String) async throws -> TerminalRepositoryChangeSection {
        let stagedNumstat = try await git(
            ["-C", repositoryRoot, "diff", "--numstat", "--cached"]
        ).stdout
        let unstagedNumstat = try await git(
            ["-C", repositoryRoot, "diff", "--numstat"]
        ).stdout
        let untrackedOutput = try await git(
            ["-C", repositoryRoot, "ls-files", "--others", "--exclude-standard"]
        ).stdout

        var merged: [String: TerminalRepositoryChangeFile] = [:]

        for file in Self.parseNumstatFiles(stagedNumstat, badges: ["Staged"]) {
            merged[file.path] = file
        }

        for file in Self.parseNumstatFiles(unstagedNumstat, badges: ["Unstaged"]) {
            if let existing = merged[file.path] {
                merged[file.path] = TerminalRepositoryChangeFile(
                    id: existing.id,
                    path: existing.path,
                    additions: existing.additions + file.additions,
                    deletions: existing.deletions + file.deletions,
                    isBinary: existing.isBinary || file.isBinary,
                    badges: Array(Set(existing.badges + file.badges)).sorted()
                )
            } else {
                merged[file.path] = file
            }
        }

        for line in untrackedOutput.split(whereSeparator: \.isNewline) {
            let path = String(line)
            guard !path.isEmpty else { continue }
            if let existing = merged[path] {
                merged[path] = TerminalRepositoryChangeFile(
                    id: existing.id,
                    path: existing.path,
                    additions: existing.additions,
                    deletions: existing.deletions,
                    isBinary: existing.isBinary,
                    badges: Array(Set(existing.badges + ["Untracked"])).sorted()
                )
            } else {
                merged[path] = TerminalRepositoryChangeFile(
                    id: path,
                    path: path,
                    additions: 0,
                    deletions: 0,
                    isBinary: false,
                    badges: ["Untracked"]
                )
            }
        }

        return Self.changeSection(
            title: "Uncommitted",
            files: merged.values.sorted {
                $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
        )
    }

    private func listRepositoryFiles(repositoryRoot: String) async throws -> [String] {
        let output = try await git(
            ["-C", repositoryRoot, "ls-files", "--cached", "--others", "--exclude-standard"]
        ).stdout

        return output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func git(
        _ arguments: [String],
        acceptedExitCodes: Set<Int32> = [0]
    ) async throws -> TerminalCommandOutput {
        do {
            return try await TerminalProcessRunner.runCommand(
                "git",
                arguments: arguments,
                acceptedExitCodes: acceptedExitCodes
            )
        } catch let error as TerminalCommandError {
            switch error {
            case .commandNotFound:
                throw TerminalRepositoryServiceError.commandFailed("`git` is not available in PATH.")
            case .nonZeroExit:
                throw error
            }
        } catch {
            throw TerminalRepositoryServiceError.commandFailed(error.localizedDescription)
        }
    }

    private func gh(
        _ arguments: [String],
        currentDirectory: String,
        acceptedExitCodes: Set<Int32> = [0]
    ) async throws -> TerminalCommandOutput {
        do {
            return try await TerminalProcessRunner.runCommand(
                "gh",
                arguments: arguments,
                currentDirectory: currentDirectory,
                acceptedExitCodes: acceptedExitCodes
            )
        } catch let error as TerminalCommandError {
            throw error
        } catch {
            throw TerminalRepositoryServiceError.commandFailed(error.localizedDescription)
        }
    }

    private func mapGHError(_ error: TerminalCommandError) -> TerminalRepositoryServiceError {
        switch error {
        case .commandNotFound:
            return .ghUnavailable
        case let .nonZeroExit(_, _, stderr):
            let lowercased = stderr.lowercased()
            if lowercased.contains("could not find pull request") ||
                lowercased.contains("no pull requests found") {
                return .noPullRequest
            }
            if lowercased.contains("please run") && lowercased.contains("gh auth login") {
                return .ghAuthenticationRequired
            }
            if lowercased.contains("not logged in") {
                return .ghAuthenticationRequired
            }
            if lowercased.contains("no such file or directory") ||
                lowercased.contains("env: gh:") {
                return .ghUnavailable
            }

            return .commandFailed(error.localizedDescription)
        }
    }

    private static func jsonDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func makeReviewThread(
        from payload: ReviewThreadsResponse.ReviewThreadNode
    ) -> TerminalPullRequestReviewThread {
        let comments = payload.comments.nodes.map { comment in
            TerminalPullRequestReviewComment(
                id: comment.id,
                body: comment.body,
                url: URL(string: comment.url) ?? URL(string: "https://github.com")!,
                authorLogin: comment.author?.login ?? "ghost",
                createdAt: comment.createdAt,
                path: comment.path ?? payload.path,
                line: comment.line ?? payload.line,
                originalLine: comment.originalLine ?? payload.originalLine,
                startLine: comment.startLine ?? payload.startLine,
                originalStartLine: comment.originalStartLine ?? payload.originalStartLine,
                replyToID: comment.replyTo?.id
            )
        }.sorted { $0.createdAt < $1.createdAt }

        return TerminalPullRequestReviewThread(
            id: payload.id,
            path: payload.path,
            line: payload.line,
            originalLine: payload.originalLine,
            startLine: payload.startLine,
            originalStartLine: payload.originalStartLine,
            diffSide: payload.diffSide,
            isResolved: payload.isResolved,
            isOutdated: payload.isOutdated,
            comments: comments,
            hasMoreComments: payload.comments.totalCount > comments.count
        )
    }

    static func parseNumstatFiles(
        _ output: String,
        badges: [String]
    ) -> [TerminalRepositoryChangeFile] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let columns = String(line).split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard columns.count == 3 else { return nil }

            let additionsValue = String(columns[0])
            let deletionsValue = String(columns[1])
            let path = String(columns[2])

            let isBinary = additionsValue == "-" || deletionsValue == "-"
            let additions = Int(additionsValue) ?? 0
            let deletions = Int(deletionsValue) ?? 0

            return TerminalRepositoryChangeFile(
                id: path,
                path: path,
                additions: additions,
                deletions: deletions,
                isBinary: isBinary,
                badges: badges
            )
        }
    }

    static func changeSection(
        title: String,
        files: [TerminalRepositoryChangeFile]
    ) -> TerminalRepositoryChangeSection {
        TerminalRepositoryChangeSection(
            title: title,
            files: files,
            fileCount: files.count,
            additions: files.reduce(0) { $0 + $1.additions },
            deletions: files.reduce(0) { $0 + $1.deletions },
            message: files.isEmpty ? "No \(title.lowercased()) changes." : nil
        )
    }

    static func sanitizedPathComponent(from branchName: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_."))
        let transformed = branchName.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(String(scalar)) : "-"
        }

        let sanitized = String(transformed)
            .replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))

        return sanitized.isEmpty ? "worktree" : sanitized
    }

    static func shortBranchName(for reference: String) -> String {
        guard let slash = reference.firstIndex(of: "/") else {
            return reference
        }

        return String(reference[reference.index(after: slash)...])
    }

    static func defaultWorktreePath(
        repositoryName repositoryRoot: String,
        branchName: String,
        workspaceRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".workspace", isDirectory: true)
    ) -> String {
        let repositoryName = URL(fileURLWithPath: repositoryRoot).lastPathComponent
        return workspaceRoot
            .appendingPathComponent(repositoryName, isDirectory: true)
            .appendingPathComponent(sanitizedPathComponent(from: branchName), isDirectory: true)
            .path
    }
}

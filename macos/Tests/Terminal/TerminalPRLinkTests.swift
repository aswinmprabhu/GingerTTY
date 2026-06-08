import Foundation
import Testing
@testable import Ghostty

struct TerminalPRLinkTests {
    @Test
    func parsesStandardPullRequestURL() {
        let parsed = TerminalRepositoryService.parseGitHubPRURL(
            "https://github.com/linkedin/GingerTTY/pull/42"
        )

        #expect(parsed?.owner == "linkedin")
        #expect(parsed?.repo == "GingerTTY")
        #expect(parsed?.number == 42)
    }

    @Test
    func parsesURLWithTrailingPathAndWhitespace() {
        let parsed = TerminalRepositoryService.parseGitHubPRURL(
            "  https://github.com/owner/repo/pull/7/files  "
        )

        #expect(parsed == TerminalRepositoryService.ParsedPRURL(owner: "owner", repo: "repo", number: 7))
    }

    @Test
    func rejectsNonPullRequestURLs() {
        #expect(TerminalRepositoryService.parseGitHubPRURL("https://github.com/owner/repo") == nil)
        #expect(TerminalRepositoryService.parseGitHubPRURL("https://github.com/owner/repo/issues/3") == nil)
        #expect(TerminalRepositoryService.parseGitHubPRURL("https://github.com/owner/repo/pull/abc") == nil)
    }

    @Test
    func rejectsNonGitHubHosts() {
        #expect(TerminalRepositoryService.parseGitHubPRURL("https://gitlab.com/owner/repo/pull/1") == nil)
        #expect(TerminalRepositoryService.parseGitHubPRURL("not a url") == nil)
    }

    @Test
    func parsesAlreadyUsedWorktreePathFromGitError() {
        let stderr = """
        Preparing worktree (checking out 'prevent-failover-during-deployment')
        fatal: 'prevent-failover-during-deployment' is already used by worktree at '/Users/asprabhu/code/grid-ldap-sentry'
        """

        #expect(
            TerminalRepositoryService.parseAlreadyCheckedOutPath(fromStderr: stderr)
                == "/Users/asprabhu/code/grid-ldap-sentry"
        )
    }

    @Test
    func returnsNilWhenGitErrorHasNoExistingWorktree() {
        #expect(TerminalRepositoryService.parseAlreadyCheckedOutPath(fromStderr: "fatal: some other error") == nil)
    }
}

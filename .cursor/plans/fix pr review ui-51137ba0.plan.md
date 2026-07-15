<!-- 51137ba0-04c0-49b6-a55d-d8f015d2af90 -->
# Fix PR Review UI Issues

## Scope
Update the macOS PR review/diff UI in `macos/Sources/Features/Terminal/` so commit ranges, thread interactions, and combined diff rendering behave correctly for real GitHub PRs.

## Planned Changes
- `macos/Sources/Features/Terminal/TerminalRepositoryService.swift`
  - Make committed-change and commit-list calculations use a fresh base-branch ref when a PR base branch is known, instead of relying on whatever stale `origin/<base>` ref happens to exist locally.
  - Reuse the existing `fetchRemoteBranch(...)` path before computing merge-base driven results so branch-only commits for worktrees like `abalode/grid-jira-hybrid-adapter` match the PR’s actual base branch.
  - Keep the existing local fallback behavior for repos without PR metadata.

- `macos/Sources/Features/Terminal/TerminalController.swift`
  - Update reply handling so a successful thread reply is reflected in app state immediately instead of waiting for a later full PR refresh cycle.
  - Sync `activeReviewThread` and the matching entry in `tab.reviewThreads` after reply/resolve mutations, then still invalidate and refresh as reconciliation.
  - Route “send queued PR comments to chat” through a single helper so successful sends also clear `tab.prThreadReviewComments`.

- `macos/Sources/Features/Terminal/TerminalTabState.swift`
  - Add small mutation helpers for replacing/updating a review thread by ID and for clearing queued thread comments after a successful chat handoff.
  - This keeps the controller logic simple and avoids stale `activeReviewThread` state.

- `macos/Sources/Features/Terminal/TerminalDiffView.swift`
  - Make `PierreDiffWebView.updateNSView(...)` reload when the active review thread changes, not only when `diffText` or draft count changes.
  - Remove the custom combined-diff hunk separator debug fallback that currently renders raw metadata like `[keys: slotName,hunkIndex,lines,type,expandable]`.
  - Align the combined diff renderer with the working single-file config (`hunkSeparators: 'line-info'`, expandable separators intact) so collapsed hunks render cleanly and can be expanded again.

## Key Code Paths
- Commit range is currently derived from merge-base against `resolveBaseBranchName(...)` and `resolveExistingBaseReference(...)` in `TerminalRepositoryService.fetchCommitLog(...)` and `committedSection(...)`.
- Diff thread replies currently go through `TerminalController.replyToThread(...)`, but `PierreDiffWebView.updateNSView(...)` only reloads when `diffText` or draft count changes.
- Queued sidebar comments are sent from `PRThreadCommentsUberBox.sendToChat()` in `TerminalDiffView.swift`, and today that path does not clear `tab.prThreadReviewComments` after success.
- Combined diff separators are customized in `PierreCombinedDiffWebView.buildCombinedHTML(...)`, where the current callback injects the debug text and bypasses the renderer’s normal expansion behavior.

## Tests
- `macos/Tests/Terminal/TerminalSidebarDataTests.swift`
  - Add `fetchLocalRepositoryStateRefreshesPreferredBaseBranchBeforeComputingCommitList`
    - Creates a remote + clone setup with a stale local base ref, then verifies the commit list reflects only commits still ahead of the fetched PR base branch.
  - Add `fetchRepositoryChangesRefreshesPreferredBaseBranchBeforeCommittedDiff`
    - Verifies committed change summary matches the refreshed base branch instead of the stale local ref.

- `macos/Tests/Terminal/TerminalTabStateTests.swift`
  - Add `updateReviewThreadReplacesMatchingSidebarAndActiveThread`
    - Verifies replying/resolving a thread updates both `reviewThreads` and `activeReviewThread` consistently.
  - Add `clearPRThreadCommentsEmptiesQueuedComments`
    - Covers the queued comment clearing path used after successful send-to-chat.

## Validation
- Run `macos/build.nu --action test`
- If the PR review UI has no existing automated coverage for the WKWebView rendering path, do a manual smoke check in GingerTTY:
  - Open a PR-backed worktree whose local base ref is stale and verify only the expected commits show.
  - Reply to a thread from the diff view and confirm the new reply appears immediately.
  - Send queued “Comments for Chat” and confirm the sidebar box clears.
  - Open committed/commit combined diff and confirm hunk separators are readable and expandable.

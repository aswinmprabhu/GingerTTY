<h1>
<p align="center">
  <img src="images/icons/icon_128.png" alt="Logo" width="128">
  <br>GingerTTY
</h1>
  <p align="center">
    A terminal for AI-native development. Fork of <a href="https://ghostty.org">Ghostty</a>.
  </p>
</p>

https://github.com/user-attachments/assets/15b35302-72a5-43c0-a1b0-42e653841a00

## About

GingerTTY is a macOS terminal emulator built for developers who work with CLI agents like [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and [Codex](https://openai.com/index/codex/). It's a thin SwiftUI wrapper on top of [Ghostty](https://ghostty.org), inheriting its speed, standards compliance, and native Metal renderer while adding features tailored for agentic workflows.

## Features

- **Custom Vertical Tab Bar** — A sidebar tab bar showing tab title, git branch, and live agent status (Running / Done / Need input). Resizable, with per-tab colors and rename support.
- **Git Sidebar Inspector** — A right-side panel with four tabs:
  - **Changes**: Committed and uncommitted file changes, commit list, and review submission
  - **Comments**: GitHub PR review threads with reply and resolve support
  - **Checks**: GitHub Actions CI status for the current PR
  - **Files**: File tree of changed files
- **PR Review Workflow** — Command-palette for selecting open PRs, auto-creates a worktree for the PR branch, and opens it in a new tab for review.
- **Diff Viewer** — Side-by-side split diffs with syntax highlighting. Supports in-page search, line selection for inline review comments, and combined multi-file diffs.
- **File Viewer & Editor** — View and edit any file with full syntax highlighting. Markdown files open in a split preview mode.
- **Fuzzy File Search** — VS Code-style quick open (`Cmd+P`) with fuzzy scoring.
- **Git Worktrees** — Create or reuse worktrees from the UI. Supports existing and new branches, opens the worktree in a new tab.
- **Agent Status Hooks** — AppleScript interface for CLI agents to report their status in the tab bar.
- **Repository Watcher** — Auto-refreshes local git state on filesystem changes.
- **PR Merge** — Merge PRs directly from the sidebar with squash, merge, or rebase options.

## Principles

- **Terminal first.** GingerTTY is a terminal emulator. It doesn't try to be an IDE, agent orchestrator, or platform. The terminal is the interface.
- **AI-native development for CLI agents.** Built around the workflow of CLI agents like Claude Code and Codex — doesn't try to reinvent the wheel with a UI for agentic development.
- **No logins, API keys, or subscriptions.** GingerTTY integrates with tools you already have installed locally (like `gh` CLI) rather than requiring accounts or cloud services.
- **macOS only.** A focused, native SwiftUI app — not a cross-platform compromise.
- **Full Ghostty compatibility.** All of Ghostty's core macOS features — config, keybindings, themes, splits, tabs, Metal rendering — work as expected.

## Architecture

GingerTTY's core terminal (the Zig-based `libghostty` / GhosttyKit) is upstream Ghostty, untouched. All GingerTTY-specific code lives in the macOS SwiftUI layer.

**Key technologies:**

- **[Monaco Editor](https://microsoft.github.io/monaco-editor/)** — VS Code's editor, bundled and loaded via WKWebView. Powers the file viewer/editor with full syntax highlighting and markdown split preview.
- **[Pierre Diffs](https://www.npmjs.com/package/@anthropic-ai/pierre-diffs)** — A diff rendering library loaded via WKWebView to render side-by-side split diffs with syntax highlighting and theme support.
- **`gh` CLI** — GitHub CLI for fetching PRs, CI checks, review threads, submitting reviews, and merging.
- **SwiftUI + AppKit** — All UI is SwiftUI with AppKit bridges for WebViews and search fields.

## Configuration

GingerTTY reads its own config keys from the standard Ghostty config file (`~/.config/ghostty/config`). These are silently ignored by Ghostty's config parser.

### `macos-tab-bar`

Controls the tab bar style.

| Value | Description |
|---|---|
| `vertical` (default) | GingerTTY's custom vertical tab bar sidebar |
| `horizontal` | Custom horizontal tab bar |
| `native` | macOS native tab bar (upstream Ghostty behavior) |

### `gingertty-allow-from-notification-behavior`

Controls what the "Allow" button does on permission request notifications.

| Value | Description |
|---|---|
| `once` (default) | Allows the single tool invocation that triggered the prompt |
| `session` | Allows the tool for the rest of the Claude Code session (in-memory only, not persisted to disk) |

Any key prefixed with `gingertty-` is reserved for GingerTTY configuration and will not produce unknown-key warnings.

All other Ghostty configuration works as documented at [ghostty.org/docs](https://ghostty.org/docs).

## Claude Code Integration

GingerTTY ships a `claude` wrapper script and a hook handler (`gingertty-hook.sh`) that are automatically placed on `PATH` inside GingerTTY terminals. When you run `claude` inside GingerTTY:

1. **Tab status** — The tab bar shows live agent status (Running, Done, Need input) via Claude Code hooks.
2. **Permission notifications** — When Claude Code needs tool permission, a macOS notification appears with an "Allow" button. Denial is handled from the terminal prompt.
3. **Plan review** — When Claude proposes a plan, GingerTTY opens it in the built-in file viewer for review with inline comments.

The wrapper injects hooks via `--settings` and sets environment variables (`GINGERTTY`, `GINGERTTY_TERMINAL_ID`, `GINGERTTY_BIN_DIR`) so hooks can communicate back to the app via AppleScript. Outside GingerTTY, the wrapper passes through to the real `claude` binary transparently.

## AppleScript

GingerTTY extends Ghostty's AppleScript dictionary with commands for agent integration. These are called by GingerTTY's hook scripts but can also be used directly.

### `set agent status`

Sets or clears the agent status indicator on a terminal tab.

```applescript
tell application "GingerTTY" to set agent status "Running" on terminal id "TERMINAL-UUID"
```

Supported status values: `"Running"`, `"Done"`, `"Need input"`, or `""` to clear.

### `present permission request`

Presents a macOS notification for a Claude Code permission request.

```applescript
tell application "GingerTTY" to present permission request "npm test" ¬
    response path "/tmp/response.json" ¬
    session id "session-1" ¬
    agent id "main" ¬
    tool name "Bash" ¬
    suggestions json "[{\"type\":\"addRules\", ...}]" ¬
    on terminal id "TERMINAL-UUID"
```

Parameters:
- **direct parameter** — Summary of the tool input
- **response path** — Where to write the permission decision JSON
- **session id** / **agent id** — Claude session and agent identifiers
- **tool name** — The Claude tool requesting permission (e.g., `Bash`, `Write`)
- **suggestions json** (optional) — Claude's `permission_suggestions` for session-scoped allow rules
- **on** — Target terminal

### `open plan review`

Opens a markdown plan in the built-in file viewer for review.

```applescript
tell application "GingerTTY" to open plan review "/tmp/plan.md" ¬
    response path "/tmp/review-response.json" ¬
    session id "session-1" ¬
    agent id "main" ¬
    on terminal id "TERMINAL-UUID"
```

The reviewer can approve the plan or request changes with inline comments. The decision is written as JSON to the response path.

### `import review comments`

Imports structured review comments from external tools into GingerTTY's local/draft review comment list for the target terminal tab.

```applescript
set payload to "{\"comments\":[{\"path\":\"macos/Sources/Features/Terminal/TerminalController.swift\",\"line_start\":956,\"line_end\":970,\"side\":\"new\",\"text\":\"Can we guard this path earlier to avoid opening an empty diff?\"}],\"replaceExisting\":true}"

tell application "GingerTTY" to import review comments payload ¬
    replace existing true ¬
    on terminal id "TERMINAL-UUID"
```

Behavior:
- In **review mode**, imported comments become pending draft review comments.
- In **non-review mode**, imported comments become local review comments (with `Fix in chat` support).

Supported payload shapes:
- `{ "comments": [...] }`
- `{ "issues": [...] }` (for review tools that emit issue objects)
- `{ "findings": [...] }`
- `[...]` (array of comment/issue-like objects)

Common fields:
- **path/file/filePath** — repository-relative file path
- **line_start/lineStart/line** and **line_end/lineEnd** — line range
- **side** — `new`/`right` or `old`/`left`
- **text/body/comment** — comment body
- **replaceExisting** (optional) — whether to clear existing local/draft comments before import (default: `true`)

## Ghostty

GingerTTY is built on top of Ghostty. For documentation on terminal features, configuration, keybindings, themes, and more, see:

- [Ghostty Website](https://ghostty.org)
- [Ghostty Documentation](https://ghostty.org/docs)
- [Ghostty GitHub](https://github.com/ghostty-org/ghostty)

## Disclaimer

The SwiftUI components in this project are AI-coded, with human review of architectural decisions and high-level correctness. The WebUI parts (Monaco integration, Pierre diffs rendering) are vibe coded with spec-driven development.

## License

MIT — see [LICENSE](LICENSE).

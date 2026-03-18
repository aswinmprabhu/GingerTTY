<h1>
<p align="center">
  <img src="images/icons/icon_128.png" alt="Logo" width="128">
  <br>GingerTTY
</h1>
  <p align="center">
    A terminal for AI-native development. Fork of <a href="https://ghostty.org">Ghostty</a>.
  </p>
</p>

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

Any key prefixed with `gingertty-` is also reserved for future GingerTTY configuration and will not produce unknown-key warnings.

All other Ghostty configuration works as documented at [ghostty.org/docs](https://ghostty.org/docs).

## AppleScript: Agent Status

GingerTTY extends Ghostty's AppleScript dictionary with a `set agent status` command that lets CLI agents report their status in the tab bar.

```applescript
tell application "GingerTTY" to set agent status "Running" on terminal id "TERMINAL-UUID"
```

Supported status values: `"Running"`, `"Done"`, `"Need input"`, or `""` to clear.

## Ghostty

GingerTTY is built on top of Ghostty. For documentation on terminal features, configuration, keybindings, themes, and more, see:

- [Ghostty Website](https://ghostty.org)
- [Ghostty Documentation](https://ghostty.org/docs)
- [Ghostty GitHub](https://github.com/ghostty-org/ghostty)

## Disclaimer

The SwiftUI components in this project are AI-coded, with human review of architectural decisions and high-level correctness. The WebUI parts (Monaco integration, Pierre diffs rendering) are vibe coded with spec-driven development.

## License

MIT — see [LICENSE](LICENSE).

<h1>
<p align="center">
  <img src="images/icons/icon_128.png" alt="GingerTTY logo" width="128">
  <br>GingerTTY
</h1>
<p align="center">
  A fast, native macOS terminal for AI-native development.
  <br>Fork of <a href="https://ghostty.org">Ghostty</a>, with tools for working alongside CLI agents.
</p>

<p align="center">
  <img src="https://github.com/user-attachments/assets/15b35302-72a5-43c0-a1b0-42e653841a00" alt="GingerTTY demo">
</p>

## What is GingerTTY?

GingerTTY is a macOS terminal emulator for developers who work with command-line agents such as [Claude Code](https://docs.anthropic.com/en/docs/claude-code), [GitHub Copilot CLI](https://github.com/features/copilot/cli), and [Codex](https://openai.com/index/codex/).

It keeps the terminal as the primary interface, then adds the surrounding workflow: agent-aware tabs, Git and GitHub inspection, worktrees, code review, an editor, and an in-tab browser. It is a thin SwiftUI layer over Ghostty, so Ghostty's terminal performance, configuration, themes, splits, tabs, and Metal renderer remain available.

## Install

Download the latest universal macOS build from [GitHub Releases](https://github.com/aswinmprabhu/GingerTTY/releases), unzip it, and move `GingerTTY.app` to `/Applications`.

For the GitHub features, install the [GitHub CLI](https://cli.github.com/) and authenticate it once:

```sh
brew install gh
gh auth login
```

GingerTTY does not require its own login, API key, or subscription. GitHub actions use the local `gh` session. Claude Code and Copilot CLI are also optional: install whichever agents you use and make sure their commands are available in your `PATH`.

## The daily workflow

1. Open a terminal tab and start your agent as usual. The custom tab bar shows the tab title, Git branch, and agent status.
2. Use **New…** at the bottom of the tab bar to open a regular tab, create a worktree, review a pull request, or open a browser tab.
3. Use the right-hand inspector to understand the repository without leaving the terminal:
   - **Changes** shows uncommitted, untracked, and committed files, diffs, and commits.
   - **Comments** shows GitHub review threads and local/imported comments.
   - **Checks** shows CI status for the current pull request.
   - **Files** shows the changed-file tree.
4. Open a file or diff when you need to inspect it. Markdown files have a split source/preview view; diffs support search, copy, syntax highlighting, and inline comments.
5. Submit or merge a pull request from the inspector when the review is complete. Merge supports squash, merge, and rebase.

The right inspector can be toggled with `Cmd+B`. The fuzzy file picker opens with `Cmd+P`. `Escape` closes the active diff, editor, or review surface.

## Features

### Terminal and tabs

- Native Ghostty terminal with tabs, splits, themes, keybindings, and Metal rendering.
- Custom vertical or horizontal tab bars with branch labels, agent-status icons, tab colors, and tab renaming.
- A compact **New…** split button for tabs, worktrees, PR reviews, and browser tabs.
- Multiple content tabs inside a terminal tab for terminal sessions, diffs, files, and web pages.
- Sidebar widths and the right-inspector visibility are shared across tabs and windows.

### Git, worktrees, and pull requests

- Live repository state refreshes as files change.
- Create a worktree from an existing branch or a new branch; worktrees open in their own tab.
- When a worktree-backed tab closes, GingerTTY offers to remove the worktree.
- Start a PR review by choosing an open PR or pasting a GitHub PR URL. GingerTTY resolves the local checkout, creates or reuses a worktree for the PR branch, and opens it in a new tab.
- Review changes in side-by-side diffs, browse the file tree, inspect commits, view CI checks, reply to or resolve review threads, and submit a review. Thread annotations appear in both individual-file and combined diffs; combined diffs keep filenames visible while you scroll and let you click a filename to open the full file.
- Imported review findings can be shown as local comments or draft PR comments. Comments can be queued as context for the agent with **Fix in chat**.

### Files and browser

- Open any repository file with `Cmd+P` and edit it in the Monaco-based editor.
- Markdown files open with a live split preview.
- Open a web page as a content tab with back, forward, reload, editable URL, find-in-page, and open-in-browser controls.
- `Cmd`-click links in the terminal to choose between GingerTTY's browser and the system browser.

### Agent integration

GingerTTY provides wrappers for `claude` and `copilot` inside its terminals. They pass through to the real CLI commands and are harmless outside GingerTTY.

- **Status in tabs:** running, done, and needs-input states are reflected in the tab bar.
- **Claude Code permission notifications:** permission requests can appear as macOS notifications with an **Allow** action. Denials continue through the terminal prompt.
- **Claude Code plan review:** proposed Markdown plans open in the built-in viewer, where you can approve or request changes with inline comments.
- **Session save and restore:** when quitting with a Claude Code or Copilot session running, GingerTTY offers to save it. On the next launch, it can restore the agent tab in its original directory and resume the session.

The wrappers set `GINGERTTY`, `GINGERTTY_TERMINAL_ID`, and `GINGERTTY_BIN_DIR` while running inside the app. Claude hooks are supplied per invocation; Copilot hooks are installed in `~/.copilot/hooks/gingertty.json` and are guarded so they do nothing outside GingerTTY.

## Configuration

GingerTTY reads its settings from the standard Ghostty configuration file:

```text
~/.config/ghostty/config
```

GingerTTY-specific keys are ignored by upstream Ghostty and use the `gingertty-` prefix.

### Tab bar

```text
macos-tab-bar = vertical
```

| Value | Behavior |
| --- | --- |
| `vertical` | GingerTTY's custom vertical tab bar (default) |
| `horizontal` | GingerTTY's custom horizontal tab bar |
| `native` | Ghostty's native macOS tab bar |

### Permission notification behavior

```text
gingertty-allow-from-notification-behavior = once
```

| Value | Behavior |
| --- | --- |
| `once` | Allow only the tool invocation that triggered the notification (default) |
| `session` | Allow the tool for the rest of the Claude Code session; this is in-memory and is not written to disk |

### Local repository directory for PR links

When a PR is opened by URL, GingerTTY looks for the matching repository below `~/code` by default:

```text
gingertty-code-directory = ~/code
```

Change this when your local repositories live elsewhere. A PR for `https://github.com/example/project/pull/42` will resolve to `<code-directory>/project`.

All other Ghostty configuration is documented at [ghostty.org/docs](https://ghostty.org/docs).

## AppleScript automation

GingerTTY extends Ghostty's AppleScript dictionary so agent hooks and external tools can target tabs directly. The commands below are the GingerTTY-specific additions:

| Command | Purpose |
| --- | --- |
| `set agent status` | Set or clear the tab indicator: `Running`, `Done`, or `Need input` |
| `register agent session` | Register a Claude or Copilot session for save/restore; pass an empty agent kind to clear it |
| `open browser tab` | Open an `http` or `https` URL as a browser content tab |
| `present permission request` | Show a Claude Code permission notification and write its decision to a response file |
| `open plan review` | Open a Markdown plan and write the approval or requested changes to a response file |
| `import review comments` | Import comments from a review tool into the selected tab |

Example:

```applescript
tell application "GingerTTY" to set agent status "Running" ¬
    on terminal id "TERMINAL-UUID"

tell application "GingerTTY" to register agent session "claude" ¬
    session id "SESSION-ID" ¬
    on terminal id "TERMINAL-UUID"

tell application "GingerTTY" to open browser tab "https://github.com"
```

`import review comments` accepts a JSON object with `comments`, `issues`, or `findings`, or a raw array. Each item can provide a repository-relative `path`, a line or line range, a `side` (`new`/`old`), and comment text. In review mode, imported items become draft PR comments; otherwise they become local comments.

## Build from source

GingerTTY is a macOS Xcode app with the Ghostty Zig library as its terminal core. From the repository root:

```sh
env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  xcodebuild -project macos/Ghostty.xcodeproj \
  -scheme Ghostty -configuration Debug SYMROOT=macos/build build
```

The built app is written to `macos/macos/build/Debug/GingerTTY.app`. See [`AGENTS.md`](AGENTS.md) for the release build, test, and install commands used by the project.

## Architecture

The terminal core (`libghostty` / `GhosttyKit`) is upstream Ghostty. GingerTTY-specific work lives in the macOS SwiftUI layer.

- **SwiftUI + AppKit** provide the native application and window/tab experience.
- **Monaco Editor** renders and edits files in a bundled `WKWebView`.
- **Pierre Diffs** renders themed side-by-side diffs in a bundled `WKWebView`.
- **`gh` CLI** supplies GitHub PR, review, checks, and merge operations.

## Ghostty documentation

For terminal configuration, keybindings, themes, and upstream platform behavior, see:

- [Ghostty website](https://ghostty.org)
- [Ghostty documentation](https://ghostty.org/docs)
- [Ghostty GitHub](https://github.com/ghostty-org/ghostty)

## License

MIT — see [LICENSE](LICENSE).

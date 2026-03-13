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

## Principles

- **Terminal first.** GingerTTY is a terminal emulator. It doesn't try to be an IDE, agent orchestrator, or platform. The terminal is the interface.
- **AI-native development for CLI agents.** Built around the workflow of CLI agents like Claude Code and Codex — doesn't try to reinvent the wheel with a UI for agentic development.
- **No logins, API keys, or subscriptions.** GingerTTY integrates with tools you already have installed locally (like `gh` CLI) rather than requiring accounts or cloud services.
- **macOS only.** A focused, native SwiftUI app — not a cross-platform compromise.
- **Full Ghostty compatibility.** All of Ghostty's core macOS features — config, keybindings, themes, splits, tabs, Metal rendering — work as expected.

## Ghostty

GingerTTY is built on top of Ghostty. For documentation on terminal features, configuration, keybindings, themes, and more, see:

- [Ghostty Website](https://ghostty.org)
- [Ghostty Documentation](https://ghostty.org/docs)
- [Ghostty GitHub](https://github.com/ghostty-org/ghostty)

## License

MIT — see [LICENSE](LICENSE).

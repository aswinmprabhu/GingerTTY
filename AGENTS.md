# Agent Development Guide

A file for [guiding coding agents](https://agents.md/).

## Scope

GingerTTY is a fork of [Ghostty](https://ghostty.org). **Do NOT modify Ghostty's core code** — the Zig source in `src/`, the C library, shell integrations, terminfo, and other upstream components should be treated as read-only. Changes should be limited to the macOS SwiftUI app layer and GingerTTY-specific features.

If a task seems to require changes to core Ghostty code, stop and confirm with the user first.

## Commands

- **Build macOS app:** never use `macos/build.nu`; invoke `xcodebuild` directly (do not use `zig build` for the app)
  - Debug build:
    `env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" xcodebuild -project macos/Ghostty.xcodeproj -scheme Ghostty -configuration Debug SYMROOT=macos/build build`
  - Release build:
    `env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" xcodebuild -project macos/Ghostty.xcodeproj -scheme Ghostty -configuration Release SYMROOT=macos/build build`
  - Other supported configuration: `ReleaseLocal`
  - Output: `macos/build/<configuration>/GingerTTY.app`
  - Install built app:
    `rsync -a --delete "macos/build/<configuration>/GingerTTY.app/" "/Applications/GingerTTY.app/"`
- **Run unit tests:**
  `env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" xcodebuild -project macos/Ghostty.xcodeproj -scheme Ghostty -configuration Debug SYMROOT=macos/build -skip-testing GhosttyUITests test`
  - The CLI test path skips `GhosttyUITests`.
- **Build Zig library** (only if you changed Zig code, which you shouldn't): `zig build -Demit-macos-app=false`
- **Formatting (Swift):** `swiftlint lint --fix`

## Directory Structure

- `macos/Sources/` — SwiftUI app source (this is where GingerTTY changes live)
  - `Features/Terminal/` — Terminal views, sidebar, diffs, worktrees, PR reviews
  - `Features/About/` — About view
  - `Features/AppleScript/` — AppleScript support
  - `Ghostty/` — Swift bindings to libghostty (avoid modifying)
- `macos/Tests/` — Unit tests
- `macos/Assets.xcassets/` — App icons and image assets
- `images/` — Icon source files
- `src/` — **Ghostty core (do not modify)**


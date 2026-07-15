<!-- 7f3dceff-da5d-4517-ab59-abbde69739c6 -->
---
todos:
  - id: "tab-state"
    content: "Add Monaco-backed file-viewer state in `TerminalTabState.swift`, including original contents, draft contents, and dirty state."
    status: pending
  - id: "bundle-monaco"
    content: "Add bundled Monaco web assets and a `WKWebView` wrapper for editor messaging and initialization."
    status: pending
  - id: "controller-save-flow"
    content: "Add load/save/revert controller flow and refresh repository state after save in `TerminalController.swift`."
    status: pending
  - id: "viewer-ui"
    content: "Replace the read-only file-view path in `TerminalDiffView.swift` with a Monaco editor and keep Pierre for diff/review surfaces."
    status: pending
  - id: "tests"
    content: "Add unit tests for viewer state transitions and dirty/save behavior in `macos/Tests/Terminal/TerminalTabStateTests.swift`."
    status: pending
isProject: false
---
# Editable File View Plan

## Recommendation
- Keep `@pierre/diffs` for read-only diff/review surfaces.
- Implement the file viewer as a Monaco-backed `WKWebView` editor.
- Treat Markdown like any other source file for now. No Markdown preview/rendering is in scope.

## What The Current Code Already Does
- `macos/Sources/Features/Terminal/TerminalSidebarView.swift` swaps in `TerminalFileViewerView` whenever `tab.viewerFilePath != nil`.
- `macos/Sources/Features/Terminal/TerminalController.swift` loads the file as a plain `String` via `String(contentsOfFile:encoding:)` and stores it in tab state.
- `macos/Sources/Features/Terminal/TerminalDiffView.swift` renders the file through Pierre's `File` component:
  - `const instance = new File(...)`
  - `instance.render({ file: { contents, name, lang }, fileContainer })`
- `TerminalDiffView.swift` already uses a `WKWebView` bridge with script message handlers for diff/review interactions, so the app already has the basic pattern needed for a Monaco web editor.

## Why Monaco
- Monaco is a real code editor with editing, selection, undo/redo, language services, and built-in editor UX.
- The current file viewer is already webview-based, so Monaco fits the existing SwiftUI/AppKit architecture better than trying to force Pierre into an editing role.
- Pierre remains the right choice for diff/review rendering because that is already implemented and matches its strengths.

## Why Pierre Should Not Be The Editor
- Pierre docs and the current integration show support for rendering files/diffs, line selection, annotations, header metadata, and merge-conflict/diff workflows.
- I did not find a text-editing API or mutable document model in Pierre.
- That makes Pierre a good viewer/diff engine, but a poor foundation for primary file editing.

## Proposed Changes
- `macos/Resources/Monaco/` or another app-bundled resource directory
  - Add a small Monaco bootstrap HTML/JS payload and bundle the editor assets with the app so file editing does not depend on a network fetch.
  - Load the editor from app resources instead of `esm.sh`.
- `macos/Ghostty.xcodeproj/project.pbxproj`
  - Add the Monaco resource folder to the macOS app target if it is not picked up automatically by the synchronized Xcode project layout.
- `macos/Sources/Features/Terminal/TerminalTabState.swift`
  - Add editable viewer state: original file contents, draft contents, dirty flag, and editor readiness state.
  - Keep the viewer model simple: one editable source mode only.
- `macos/Sources/Features/Terminal/TerminalController.swift`
  - When opening a file, load the disk contents into both `viewerOriginalContent` and `viewerDraftContent`.
  - Add save/revert actions.
  - Persist edits back to disk with `String.write(...)`.
  - After save, refresh repository/sidebar state so diffs and file badges reflect the new working tree.
- `macos/Sources/Features/Terminal/TerminalDiffView.swift`
  - Replace `PierreFileWebView` in `TerminalFileViewerView` with `MonacoEditorWebView`.
  - Keep `PierreDiffWebView` and `PierreCombinedDiffWebView` unchanged for review and diff flows.
  - Add header actions like `Save` and `Revert`.
  - Wire the Monaco webview to send content-change events back to Swift and accept external updates after save/revert.

## Out Of Scope
- Markdown preview/rendering.
- Replacing Pierre in diff/review views.

## Suggested Testing
- Update `macos/Tests/Terminal/TerminalTabStateTests.swift` with:
  - `openFileViewerClearsDiffStateAndStartsLoading`: opening a file should reset diff/combined-diff state and enter viewer mode.
  - `setViewerDraftContentMarksViewerDirty`: editing draft text should mark the viewer as dirty only when it diverges from original contents.
  - `saveViewerDraftPromotesDraftToOriginal`: after a successful save, original/draft contents should match and dirty state should clear.
  - `closeFileViewerClearsViewerEditingState`: closing the viewer should clear file path, contents, and dirty state.

## Validation
- Run the macOS build command from `AGENTS.md`:
  - `env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" xcodebuild -project macos/Ghostty.xcodeproj -scheme Ghostty -configuration Debug SYMROOT=macos/build build`
- Run the existing macOS unit-test command from `AGENTS.md`:
  - `env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" xcodebuild -project macos/Ghostty.xcodeproj -scheme Ghostty -configuration Debug SYMROOT=macos/build -skip-testing GhosttyUITests test`
- Do a quick manual check for:
  - typing/editing
  - save/revert
  - reopening the same file and seeing saved contents reload
  - reopening the same file and seeing updated repo diff state

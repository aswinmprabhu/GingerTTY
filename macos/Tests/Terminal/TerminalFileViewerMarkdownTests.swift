import Testing
@testable import Ghostty

struct TerminalFileViewerMarkdownTests {
    @Test
    func markdownPreviewIsEnabledForMdFiles() {
        #expect(TerminalFileViewerLayoutMode.forFilePath("README.md") == .markdownSplitPreview)
        #expect(TerminalFileViewerLayoutMode.forFilePath("docs/guide.MD") == .markdownSplitPreview)
    }

    @Test
    func markdownPreviewIsDisabledForNonMdFiles() {
        #expect(TerminalFileViewerLayoutMode.forFilePath("Sources/App.swift") == .editorOnly)
        #expect(TerminalFileViewerLayoutMode.forFilePath(nil) == .editorOnly)
    }
}

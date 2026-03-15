import AppKit
import Foundation
import Testing
@testable import Ghostty

struct TerminalCustomTabBarTests {
    @Test
    func customConfigParsesVertical() throws {
        try withTemporaryDirectorySync { temporaryRoot in
            let configURL = temporaryRoot.appendingPathComponent("config.ghostty")
            try "macos-tab-bar = vertical\n".write(to: configURL, atomically: true, encoding: .utf8)

            let config = Ghostty.Config.CustomConfig(preferredPath: configURL.path)

            #expect(config.macosTabBarMode == .vertical)
        }
    }

    @Test
    func customConfigParsesHorizontal() throws {
        try withTemporaryDirectorySync { temporaryRoot in
            let configURL = temporaryRoot.appendingPathComponent("config.ghostty")
            let includedDirectory = temporaryRoot.appendingPathComponent("nested", isDirectory: true)
            let includedURL = includedDirectory.appendingPathComponent("bar.ghostty")
            try FileManager.default.createDirectory(at: includedDirectory, withIntermediateDirectories: true)

            try """
            macos-tab-bar = vertical
            config-file = nested/bar.ghostty
            """.write(to: configURL, atomically: true, encoding: .utf8)
            try "macos-tab-bar = horizontal\n".write(to: includedURL, atomically: true, encoding: .utf8)

            let config = Ghostty.Config.CustomConfig(preferredPath: configURL.path)

            #expect(config.macosTabBarMode == .horizontal)
        }
    }

    @Test
    func customConfigDefaultsToVertical() throws {
        try withTemporaryDirectorySync { temporaryRoot in
            let configURL = temporaryRoot.appendingPathComponent("config.ghostty")
            try """
            config-file = ?missing.ghostty
            font-size = 14
            """.write(to: configURL, atomically: true, encoding: .utf8)

            let config = Ghostty.Config.CustomConfig(preferredPath: configURL.path)

            #expect(config.macosTabBarMode == .vertical)
        }
    }

    @Test
    func customConfigReadsMacOSAppSupportPath() throws {
        try withTemporaryDirectorySync { temporaryRoot in
            let appSupportDirectory = temporaryRoot
                .appendingPathComponent("Library/Application Support/com.mitchellh.ghostty", isDirectory: true)
            let configURL = appSupportDirectory.appendingPathComponent("config")
            try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
            try "macos-tab-bar = horizontal\n".write(to: configURL, atomically: true, encoding: .utf8)

            let config = Ghostty.Config.CustomConfig(environment: [
                "HOME": temporaryRoot.path,
            ])

            #expect(config.macosTabBarMode == .horizontal)
        }
    }

    @Test
    func customTabBarModeOnlyUsesCustomUIForVertical() {
        #expect(Ghostty.Config.MacOSTabBarMode.vertical.usesCustomTabBar)
        #expect(!Ghostty.Config.MacOSTabBarMode.horizontal.usesCustomTabBar)
        #expect(!Ghostty.Config.MacOSTabBarMode.native.usesCustomTabBar)
    }

    @Test
    func customConfigFiltersUnknownKeyDiagnostic() {
        let errors = Ghostty.Config.filteredErrors([
            "config error: unknown key: macos-tab-bar",
            "config error: unknown key: gingertty-foo",
            "config error: unknown key: font-size",
        ])

        #expect(errors == ["config error: unknown key: font-size"])
    }

    @MainActor
    @Test
    func tabGroupDataSourceReturnsControllers() throws {
        try withTemporaryDirectorySync { temporaryRoot in
            let configURL = temporaryRoot.appendingPathComponent("config.ghostty")
            try "".write(to: configURL, atomically: true, encoding: .utf8)

            let ghostty = Ghostty.App(configPath: configURL.path)
            let firstWindow = makeWindow()
            let secondWindow = makeWindow()
            let thirdWindow = makeWindow()

            let firstController = TerminalController(ghostty)
            firstController.window = firstWindow

            let secondController = TerminalController(ghostty)
            secondController.window = secondWindow

            let otherController = NSWindowController(window: thirdWindow)
            _ = otherController

            let controllers = TabGroupDataSource.controllers(from: [
                firstWindow,
                thirdWindow,
                secondWindow,
            ])

            #expect(controllers.count == 2)
            #expect(controllers[0] === firstController)
            #expect(controllers[1] === secondController)
        }
    }
}

private func withTemporaryDirectorySync<T>(
    _ body: (URL) throws -> T
) throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    return try body(directory)
}

@MainActor
private func makeWindow() -> NSWindow {
    NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
}

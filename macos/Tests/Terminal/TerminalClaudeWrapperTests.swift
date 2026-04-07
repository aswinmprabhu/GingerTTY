import Foundation
import Testing

struct TerminalClaudeWrapperTests {
    @Test
    func wrapperInjectsGenericAndPlanPermissionHooks() throws {
        try withClaudeWrapperTemporaryDirectory { temporaryRoot in
            let wrapperBin = temporaryRoot.appendingPathComponent("wrapper-bin", isDirectory: true)
            let realBin = temporaryRoot.appendingPathComponent("real-bin", isDirectory: true)
            try FileManager.default.createDirectory(at: wrapperBin, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: realBin, withIntermediateDirectories: true)

            let wrapperPath = wrapperBin.appendingPathComponent("claude")
            try FileManager.default.copyItem(at: wrapperScriptPath, to: wrapperPath)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperPath.path)

            let capturePath = temporaryRoot.appendingPathComponent("claude-args.txt")
            let settingsCapturePath = temporaryRoot.appendingPathComponent("claude-settings.txt")
            let realClaudePath = realBin.appendingPathComponent("claude")
            // Stub captures args and reads the --settings file content
            let stub = """
            #!/bin/sh
            printf '%s\n' "$@" > "\(capturePath.path)"
            SETTINGS_FILE=""
            NEXT_IS_SETTINGS=0
            for arg in "$@"; do
                if [ "$NEXT_IS_SETTINGS" = "1" ]; then
                    SETTINGS_FILE="$arg"
                    break
                fi
                if [ "$arg" = "--settings" ]; then
                    NEXT_IS_SETTINGS=1
                fi
            done
            if [ -n "$SETTINGS_FILE" ] && [ -f "$SETTINGS_FILE" ]; then
                cat "$SETTINGS_FILE" > "\(settingsCapturePath.path)"
            fi
            exit 0
            """
            try stub.write(to: realClaudePath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: realClaudePath.path)

            let process = Process()
            process.executableURL = wrapperPath
            process.arguments = ["hello"]
            process.environment = [
                "GINGERTTY": "1",
                "GINGERTTY_BIN_DIR": "/tmp/gingertty-bin",
                "PATH": "\(wrapperBin.path):\(realBin.path):/usr/bin:/bin:/usr/sbin:/sbin",
            ]

            try process.run()
            process.waitUntilExit()

            #expect(process.terminationStatus == 0)

            // Verify --settings was passed (as a file path)
            let captured = try String(contentsOf: capturePath, encoding: .utf8)
            #expect(captured.contains("--settings"))

            // Verify the settings file contents include expected hooks
            let settingsContent = try String(contentsOf: settingsCapturePath, encoding: .utf8)
            #expect(settingsContent.contains("PermissionRequest"))
            #expect(settingsContent.contains("ExitPlanMode"))
            #expect(settingsContent.contains("gingertty-hook.sh ExitPlanMode"))
            #expect(settingsContent.contains("gingertty-hook.sh PermissionRequest"))
        }
    }

    private var wrapperScriptPath: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("claude")
    }
}

private func withClaudeWrapperTemporaryDirectory<T>(
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

import Foundation
import Testing
@testable import Ghostty

struct TerminalPermissionHookTests {
    @Test
    func permissionRequestHookNoOpsForWrongEventPayload() throws {
        let payload = """
        {"hook_event_name":"Notification","tool_name":"Bash","tool_input":{"command":"npm test"}}
        """

        let result = try runPermissionRequestHook(payload: payload)

        #expect(result.status == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(result.createdFiles.isEmpty)
    }

    @Test
    func permissionRequestHookNoOpsForMalformedPayload() throws {
        let result = try runPermissionRequestHook(payload: "{not json")

        #expect(result.status == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(result.createdFiles.isEmpty)
    }

    @Test
    func permissionRequestHookNoOpsWithoutTerminalID() throws {
        let payload = """
        {"hook_event_name":"PermissionRequest","session_id":"session-1","agent_id":"agent-1","tool_name":"Bash","tool_input":{"command":"npm test"}}
        """

        let result = try runPermissionRequestHook(payload: payload, terminalID: nil)

        #expect(result.status == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(result.createdFiles.isEmpty)
    }

    @Test
    func permissionRequestHookEmitsAllowDecision() throws {
        let payload = """
        {"hook_event_name":"PermissionRequest","session_id":"session-1","agent_id":"agent-1","tool_name":"Bash","tool_input":{"command":"npm test","description":"Run tests"}}
        """

        let result = try runPermissionRequestHook(
            payload: payload,
            osascriptStub: """
            #!/bin/sh
            printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}\n' > "$RESPONSE_PATH"
            """
        )

        #expect(result.status == 0)
        #expect(result.stdout.contains("\"behavior\":\"allow\""))
        #expect(result.createdFiles.count == 1)
    }

    @Test
    func permissionRequestHookEmitsDenyDecision() throws {
        let payload = """
        {"hook_event_name":"PermissionRequest","session_id":"session-1","agent_id":"agent-1","tool_name":"Bash","tool_input":{"command":"rm -rf build","description":"Delete build folder"}}
        """

        let result = try runPermissionRequestHook(
            payload: payload,
            osascriptStub: """
            #!/bin/sh
            printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from test"}}}\n' > "$RESPONSE_PATH"
            """
        )

        #expect(result.status == 0)
        #expect(result.stdout.contains("\"behavior\":\"deny\""))
        #expect(result.stdout.contains("Denied from test"))
        #expect(result.createdFiles.count == 1)
    }

    @Test
    func permissionRequestHookFallsBackWhenTimedOut() throws {
        let payload = """
        {"hook_event_name":"PermissionRequest","session_id":"session-1","agent_id":"agent-1","tool_name":"Bash","tool_input":{"command":"npm test"}}
        """

        let result = try runPermissionRequestHook(
            payload: payload,
            osascriptStub: "#!/bin/sh\nexit 0\n",
            timeoutSeconds: 1
        )

        #expect(result.status == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(result.createdFiles.isEmpty)
    }

    private func runPermissionRequestHook(
        payload: String,
        osascriptStub: String = "#!/bin/sh\nexit 0\n",
        terminalID: String? = "terminal-1",
        timeoutSeconds: Int = 2
    ) throws -> PermissionHookExecutionResult {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let binDir = tempRoot.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let stubPath = binDir.appendingPathComponent("osascript")
        try osascriptStub.write(to: stubPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: stubPath.path
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [hookScriptPath.path, "PermissionRequest"]

        var environment = [
            "HOME": tempRoot.path,
            "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "GINGERTTY_PERMISSION_REQUEST_TIMEOUT_SECONDS": String(timeoutSeconds),
        ]
        if let terminalID {
            environment["GINGERTTY_TERMINAL_ID"] = terminalID
        }
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        stdinPipe.fileHandleForWriting.write(Data(payload.utf8))
        stdinPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        _ = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        let permissionRoot = tempRoot
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("GingerTTY", isDirectory: true)
            .appendingPathComponent("PermissionRequests", isDirectory: true)
            .appendingPathComponent("terminal-1", isDirectory: true)

        let createdFiles = (try? FileManager.default.contentsOfDirectory(
            at: permissionRoot,
            includingPropertiesForKeys: nil
        )) ?? []

        return PermissionHookExecutionResult(
            status: process.terminationStatus,
            stdout: stdout,
            createdFiles: createdFiles
        )
    }

    private var hookScriptPath: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("gingertty-hook.sh")
    }
}

private struct PermissionHookExecutionResult {
    let status: Int32
    let stdout: String
    let createdFiles: [URL]
}

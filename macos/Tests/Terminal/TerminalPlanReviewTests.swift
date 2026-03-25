import Foundation
import Testing
@testable import Ghostty

struct TerminalPlanReviewTests {
    @Test
    func extractsFirstProposedPlanBlock() {
        let message = """
        Preamble
        <proposed_plan>
        ## First Plan
        - One
        </proposed_plan>

        <proposed_plan>
        ## Second Plan
        </proposed_plan>
        """

        #expect(
            TerminalPlanReviewParser.extractFirstProposedPlan(from: message) ==
                """
                ## First Plan
                - One
                """
                + "\n"
        )
    }

    @Test
    func returnsNilForMalformedPlanBlock() {
        let message = """
        <proposed_plan>
        ## Missing close tag
        """

        #expect(TerminalPlanReviewParser.extractFirstProposedPlan(from: message) == nil)
    }

    @Test
    func buildsRequestChangesReasonFromResponse() {
        let response = TerminalPlanReviewResponse(
            decision: .requestChanges,
            comments: [
                .init(startLine: 4, endLine: 5, text: "Clarify the approval path."),
                .init(startLine: 2, endLine: 2, text: "Mention timeout behavior."),
            ],
            finalFilePath: "/tmp/review.md",
            edited: true
        )

        let reason = TerminalPlanReviewParser.buildRequestChangesReason(from: response)

        #expect(reason.contains("Plan review requested changes."))
        #expect(reason.contains("- L2: Mention timeout behavior."))
        #expect(reason.contains("- L4-L5: Clarify the approval path."))
        #expect(reason.contains("The reviewer directly edited the plan markdown."))
        #expect(reason.contains("Treat this reviewed markdown file as the source of truth: /tmp/review.md"))
    }

    @Test
    func openingPlanReviewTracksAbsoluteScratchFile() {
        let tab = TerminalTabState()
        let session = TerminalPlanReviewSession(
            terminalID: "terminal-1",
            sessionID: "session-1",
            agentID: "agent-1",
            scratchFilePath: "/tmp/gingertty-plan-review.md",
            responseFilePath: "/tmp/gingertty-plan-review.json",
            originalContent: "## Plan\n"
        )

        tab.openPlanReview(session)

        #expect(tab.isPlanReviewActive == true)
        #expect(tab.viewerFilePath == "/tmp/gingertty-plan-review.md")
        #expect(tab.viewerResolvedFilePath == "/tmp/gingertty-plan-review.md")
        #expect(tab.viewerLayoutMode == .markdownSplitPreview)
        #expect(tab.rightSidebarSelection == .changes)
    }

    @Test
    func requestChangesRequiresCommentOrEdit() {
        let tab = TerminalTabState()
        let session = TerminalPlanReviewSession(
            terminalID: "terminal-1",
            sessionID: "session-1",
            agentID: "agent-1",
            scratchFilePath: "/tmp/gingertty-plan-review.md",
            responseFilePath: "/tmp/gingertty-plan-review.json",
            originalContent: "## Plan\n"
        )

        tab.openPlanReview(session)
        tab.setViewerLoadedContent("## Plan\n")

        #expect(tab.canRequestPlanReviewChanges == false)

        tab.addPlanReviewComment(.init(startLine: 1, endLine: 1, text: "Needs more detail"))
        #expect(tab.canRequestPlanReviewChanges == true)

        tab.clearPlanReviewComments()
        tab.setViewerDraftContent("## Revised Plan\n")
        #expect(tab.canRequestPlanReviewChanges == true)
    }

    @Test
    func completingPlanReviewSubmissionClearsSessionState() {
        let tab = TerminalTabState()
        let session = TerminalPlanReviewSession(
            terminalID: "terminal-1",
            sessionID: "session-1",
            agentID: "agent-1",
            scratchFilePath: "/tmp/gingertty-plan-review.md",
            responseFilePath: "/tmp/gingertty-plan-review.json",
            originalContent: "## Plan\n"
        )

        tab.openPlanReview(session)
        tab.addPlanReviewComment(.init(startLine: 1, endLine: 2, text: "Tighten scope"))
        tab.beginPlanReviewSubmission()
        tab.completePlanReviewSubmission()

        #expect(tab.isPlanReviewActive == false)
        #expect(tab.planReviewComments.isEmpty)
        #expect(tab.isPlanReviewSubmitting == false)
    }

    @Test
    func exitPlanModeHookNoOpsForNonPlanSubagent() throws {
        let payload = """
        {"hook_event_name":"SubagentStop","agent_type":"Explore","session_id":"session-1","agent_id":"agent-1","last_assistant_message":"<proposed_plan>\\n## Plan\\n</proposed_plan>"}
        """

        let result = try runExitPlanModeHook(payload: payload)

        #expect(result.status == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(result.createdFiles.isEmpty)
    }

    @Test
    func exitPlanModeHookNoOpsWithoutPlanBlock() throws {
        let payload = """
        {"hook_event_name":"SubagentStop","agent_type":"Plan","session_id":"session-1","agent_id":"agent-1","last_assistant_message":"No plan here"}
        """

        let result = try runExitPlanModeHook(payload: payload)

        #expect(result.status == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(result.createdFiles.isEmpty)
    }

    @Test
    func exitPlanModeHookBlocksWithRequestChangeReason() throws {
        let payload = """
        {"hook_event_name":"SubagentStop","agent_type":"Plan","session_id":"session-1","agent_id":"agent-1","last_assistant_message":"Before\\n<proposed_plan>\\n## Review Me\\n- Add review buttons\\n</proposed_plan>\\nAfter"}
        """

        let result = try runExitPlanModeHook(
            payload: payload,
            osascriptStub: """
            #!/bin/sh
            printf '{"decision":"request_changes","comments":[{"startLine":2,"endLine":2,"text":"Clarify the request-changes flow."}],"finalFilePath":"%s","edited":true}\n' "$SCRATCH_PATH" > "$RESPONSE_PATH"
            """
        )

        #expect(result.status == 0)
        #expect(result.stdout.contains("\"decision\": \"block\""))
        #expect(result.stdout.contains("Plan review requested changes."))
        #expect(result.stdout.contains("Clarify the request-changes flow."))

        let scratchFiles = result.createdFiles.filter { $0.pathExtension == "md" }
        #expect(scratchFiles.count == 1)
        let scratchContents = try String(contentsOf: scratchFiles[0], encoding: .utf8)
        #expect(scratchContents == "## Review Me\n- Add review buttons\n")
    }

    @Test
    func exitPlanModeHookOpensNativeSavedPlanFlow() throws {
        let payload = """
        {"hook_event_name":"Stop","session_id":"session-1","last_assistant_message":"User approved Claude's plan\\nPlan saved to: ~/.claude/plans/native-plan.md · /plan to edit"}
        """

        let result = try runExitPlanModeHook(
            payload: payload,
            planFiles: [
                ".claude/plans/native-plan.md": """
                ## Native Plan
                - Step one
                """
            ],
            osascriptStub: """
            #!/bin/sh
            printf '{"decision":"request_changes","comments":[{"startLine":1,"endLine":1,"text":"Update the title."}],"finalFilePath":"%s","edited":false}\n' "$SCRATCH_PATH" > "$RESPONSE_PATH"
            """
        )

        #expect(result.status == 0)
        #expect(result.stdout.contains("Update the title."))
        #expect(result.createdFiles.contains { $0.lastPathComponent == "native-plan.md" } == false)
    }

    private func runExitPlanModeHook(
        payload: String,
        planFiles: [String: String] = [:],
        osascriptStub: String = "#!/bin/sh\nexit 0\n"
    ) throws -> HookExecutionResult {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let binDir = tempRoot.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        for (relativePath, contents) in planFiles {
            let fileURL = tempRoot.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        let stubPath = binDir.appendingPathComponent("osascript")
        try osascriptStub.write(to: stubPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: stubPath.path
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [hookScriptPath.path, "ExitPlanMode"]
        process.environment = [
            "HOME": tempRoot.path,
            "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "GINGERTTY_TERMINAL_ID": "terminal-1",
        ]

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

        let planReviewRoot = tempRoot
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("GingerTTY", isDirectory: true)
            .appendingPathComponent("PlanReviews", isDirectory: true)
            .appendingPathComponent("terminal-1", isDirectory: true)

        let createdFiles = (try? FileManager.default.contentsOfDirectory(
            at: planReviewRoot,
            includingPropertiesForKeys: nil
        )) ?? []

        return HookExecutionResult(
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

private struct HookExecutionResult {
    let status: Int32
    let stdout: String
    let createdFiles: [URL]
}

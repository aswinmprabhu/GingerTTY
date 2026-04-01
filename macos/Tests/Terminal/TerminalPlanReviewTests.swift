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
    func exitPlanModeHookNoOpsForNonExitPlanMode() throws {
        let payload = """
        {"tool_name":"SomeOtherTool","session_id":"session-1","agent_id":"agent-1"}
        """

        let result = try runExitPlanModeHook(payload: payload)

        #expect(result.status == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(result.createdFiles.isEmpty)
    }

    @Test
    func exitPlanModeHookNoOpsWithoutPlanFilePath() throws {
        let payload = """
        {"tool_name":"ExitPlanMode","session_id":"session-1","agent_id":"agent-1","tool_input":{}}
        """

        let result = try runExitPlanModeHook(payload: payload)

        #expect(result.status == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(result.createdFiles.isEmpty)
    }

    @Test
    func exitPlanModeHookBlocksWithRequestChangeReason() throws {
        let planContent = "## Review Me\n- Add review buttons\n"

        let result = try runExitPlanModeHook(
            planContent: planContent,
            osascriptStub: """
            #!/bin/sh
            printf '{"decision":"request_changes","comments":[{"startLine":2,"endLine":2,"text":"Clarify the request-changes flow."}],"finalFilePath":"%s","edited":true}\n' "$SCRATCH_PATH" > "$RESPONSE_PATH"
            """
        )

        #expect(result.status == 0)
        #expect(result.stdout.contains("\"behavior\": \"deny\""))
        #expect(result.stdout.contains("Plan review requested changes."))
        #expect(result.stdout.contains("Clarify the request-changes flow."))
    }

    @Test
    func exitPlanModeHookOpensNativeSavedPlanFlow() throws {
        let planContent = "## Native Plan\n- Step one\n"

        let result = try runExitPlanModeHook(
            planContent: planContent,
            osascriptStub: """
            #!/bin/sh
            printf '{"decision":"request_changes","comments":[{"startLine":1,"endLine":1,"text":"Update the title."}],"finalFilePath":"%s","edited":false}\n' "$SCRATCH_PATH" > "$RESPONSE_PATH"
            """
        )

        #expect(result.status == 0)
        #expect(result.stdout.contains("Update the title."))
    }

    private func runExitPlanModeHook(
        payload: String,
        osascriptStub: String = "#!/bin/sh\nexit 0\n"
    ) throws -> HookExecutionResult {
        try runExitPlanModeHook(planContent: nil, payload: payload, osascriptStub: osascriptStub)
    }

    private func runExitPlanModeHook(
        planContent: String?,
        payload: String? = nil,
        osascriptStub: String = "#!/bin/sh\nexit 0\n"
    ) throws -> HookExecutionResult {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let binDir = tempRoot.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let effectivePayload: String
        if let payload {
            effectivePayload = payload
        } else if let planContent {
            let planDir = tempRoot.appendingPathComponent("plans", isDirectory: true)
            try FileManager.default.createDirectory(at: planDir, withIntermediateDirectories: true)
            let planFile = planDir.appendingPathComponent("test-plan.md")
            try planContent.write(to: planFile, atomically: true, encoding: .utf8)
            let escapedPath = planFile.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            effectivePayload = """
            {"tool_name":"ExitPlanMode","session_id":"session-1","agent_id":"agent-1","tool_input":{"planFilePath":"\(escapedPath)"}}
            """
        } else {
            effectivePayload = "{}"
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
        stdinPipe.fileHandleForWriting.write(Data(effectivePayload.utf8))
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

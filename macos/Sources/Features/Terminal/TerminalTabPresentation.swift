import AppKit
import Foundation

enum TerminalTabPresentation {
    static func displayTitle(for window: NSWindow?) -> String {
        let title = window?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Untitled" : title
    }

    static func subtitle(for controller: TerminalController) -> String? {
        if let context = controller.tabState.repositoryContext {
            return "\(context.repositoryName) • \(context.branchName)"
        }

        if let workingDirectory = controller.tabState.workingDirectory, !workingDirectory.isEmpty {
            return URL(fileURLWithPath: workingDirectory).lastPathComponent
        }

        return nil
    }
}

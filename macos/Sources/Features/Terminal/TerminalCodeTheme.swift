import Foundation
import SwiftUI

struct TerminalCodeTheme {
    let isDark: Bool
    let shellBackgroundHex: String
    let shellForegroundHex: String
    let mutedHex: String
    let errorHex: String
    let monacoThemeName: String
    let pierreThemeType: String

    static func forColorScheme(_ colorScheme: ColorScheme) -> TerminalCodeTheme {
        if colorScheme == .dark {
            return TerminalCodeTheme(
                isDark: true,
                shellBackgroundHex: "#0b1220",
                shellForegroundHex: "#e5e7eb",
                mutedHex: "#94a3b8",
                errorHex: "#fca5a5",
                monacoThemeName: "gingertty-dark",
                pierreThemeType: "dark"
            )
        }

        return TerminalCodeTheme(
            isDark: false,
            shellBackgroundHex: "#f8fafc",
            shellForegroundHex: "#0f172a",
            mutedHex: "#64748b",
            errorHex: "#dc2626",
            monacoThemeName: "gingertty-light",
            pierreThemeType: "light"
        )
    }

    var monacoDefinitionJSON: String {
        let definition: [String: Any] = isDark
            ? [
                "base": "vs-dark",
                "inherit": true,
                "rules": [],
                "colors": [
                    "editor.background": shellBackgroundHex,
                    "editor.foreground": shellForegroundHex,
                    "editorLineNumber.foreground": "#64748b",
                    "editorLineNumber.activeForeground": "#e5e7eb",
                    "editor.lineHighlightBackground": "#0f172a",
                    "editor.selectionBackground": "#1d4ed8",
                    "editor.inactiveSelectionBackground": "#1e3a8a",
                    "editorCursor.foreground": "#93c5fd",
                ],
            ]
            : [
                "base": "vs",
                "inherit": true,
                "rules": [],
                "colors": [
                    "editor.background": shellBackgroundHex,
                    "editor.foreground": shellForegroundHex,
                    "editorLineNumber.foreground": "#94a3b8",
                    "editorLineNumber.activeForeground": "#0f172a",
                    "editor.lineHighlightBackground": "#e2e8f0",
                    "editor.selectionBackground": "#bfdbfe",
                    "editor.inactiveSelectionBackground": "#dbeafe",
                    "editorCursor.foreground": "#2563eb",
                ],
            ]

        let data = try? JSONSerialization.data(withJSONObject: definition, options: [.sortedKeys])
        return (data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
            .replacingOccurrences(of: "</", with: "<\\/")
    }
}

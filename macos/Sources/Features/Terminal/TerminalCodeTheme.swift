import Foundation
import SwiftUI

struct TerminalCodeTheme {
    let isDark: Bool
    let shellBackgroundHex: String
    let shellForegroundHex: String
    let mutedHex: String
    let errorHex: String
    let monacoThemeName: String

    var pierreThemeType: String {
        isDark ? "dark" : "light"
    }

    static func forColorScheme(_ colorScheme: ColorScheme) -> TerminalCodeTheme {
        colorScheme == .light ? vscodeLight : vscodeDark
    }

    private static let vscodeDark = TerminalCodeTheme(
        isDark: true,
        shellBackgroundHex: "#1E1E1E",
        shellForegroundHex: "#D4D4D4",
        mutedHex: "#858585",
        errorHex: "#F14C4C",
        monacoThemeName: "vs-dark"
    )

    private static let vscodeLight = TerminalCodeTheme(
        isDark: false,
        shellBackgroundHex: "#FFFFFF",
        shellForegroundHex: "#000000",
        mutedHex: "#6E6E6E",
        errorHex: "#A1260D",
        monacoThemeName: "vs"
    )
}

import Foundation
import Testing
@testable import Ghostty

struct TerminalWebSessionTests {
    @Test
    func prependsHTTPSForBareHost() {
        #expect(
            TerminalWebSession.normalizedURL(from: "example.com")?.absoluteString
                == "https://example.com"
        )
    }

    @Test
    func preservesExplicitScheme() {
        #expect(
            TerminalWebSession.normalizedURL(from: "http://example.com/path")?.absoluteString
                == "http://example.com/path"
        )
    }

    @Test
    func trimsWhitespace() {
        #expect(
            TerminalWebSession.normalizedURL(from: "  example.com  ")?.absoluteString
                == "https://example.com"
        )
    }

    @Test
    func returnsNilForBlankInput() {
        #expect(TerminalWebSession.normalizedURL(from: "") == nil)
        #expect(TerminalWebSession.normalizedURL(from: "   ") == nil)
    }
}

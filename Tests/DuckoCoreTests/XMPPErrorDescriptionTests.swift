import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCore

struct XMPPErrorDescriptionTests {
    @Test func `XMPPClientError.unexpectedStreamState renders a readable message`() {
        let error: any Error = XMPPClientError.unexpectedStreamState("Expected stream opened")
        #expect(error.localizedDescription == "Unexpected response from the server: Expected stream opened")
    }

    @Test func `XMPPClientError.timeout renders a readable message`() {
        let error: any Error = XMPPClientError.timeout
        #expect(error.localizedDescription == "The server did not respond in time")
    }

    @Test func `XMPPStanzaError prefers the server text`() {
        let error: any Error = XMPPStanzaError(errorType: .cancel, condition: .itemNotFound, text: "No such node")
        #expect(error.localizedDescription == "Server error: No such node")
    }

    @Test func `XMPPStanzaError falls back to the condition`() {
        let error: any Error = XMPPStanzaError(errorType: .cancel, condition: .itemNotFound)
        #expect(error.localizedDescription == "Server error: item-not-found")
    }
}

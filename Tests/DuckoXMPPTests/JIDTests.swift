import Foundation
import Testing

@testable import DuckoXMPP

struct JIDTests {
    struct BareJIDParsing {
        @Test("Valid bare JIDs", arguments: [
            ("user@example.com", "user", "example.com"),
            ("example.com", nil as String?, "example.com"),
            ("user@chat.example.com", "user", "chat.example.com"),
            ("user@192.168.1.1", "user", "192.168.1.1"),
        ])
        func validBareJID(input: String, expectedLocal: String?, expectedDomain: String) throws {
            let jid = try #require(BareJID.parse(input))
            #expect(jid.localPart == expectedLocal)
            #expect(jid.domainPart == expectedDomain)
        }

        @Test("Invalid bare JIDs", arguments: ["", "@example.com", "user@", "user@domain/res"])
        func invalidBareJID(input: String) {
            #expect(BareJID.parse(input) == nil)
        }
    }

    struct FullJIDParsing {
        @Test("Valid full JIDs", arguments: [
            ("user@example.com/resource", "user", "example.com", "resource"),
            ("example.com/resource", nil as String?, "example.com", "resource"),
        ])
        func validFullJID(
            input: String, expectedLocal: String?, expectedDomain: String, expectedResource: String
        ) throws {
            let jid = try #require(FullJID.parse(input))
            #expect(jid.bareJID.localPart == expectedLocal)
            #expect(jid.bareJID.domainPart == expectedDomain)
            #expect(jid.resourcePart == expectedResource)
        }

        @Test("Resource may contain slashes")
        func resourceWithSlashes() throws {
            let jid = try #require(FullJID.parse("user@example.com/res/with/slashes"))
            #expect(jid.bareJID.localPart == "user")
            #expect(jid.bareJID.domainPart == "example.com")
            #expect(jid.resourcePart == "res/with/slashes")
        }

        @Test("Invalid full JIDs", arguments: ["", "user@example.com", "user@example.com/", "@domain/res"])
        func invalidFullJID(input: String) {
            #expect(FullJID.parse(input) == nil)
        }
    }

    struct JIDParsing {
        @Test("Bare JID parsed as .bare")
        func parseBare() throws {
            let jid = try #require(JID.parse("user@example.com"))
            guard case .bare(let bareJID) = jid else {
                Issue.record("Expected .bare, got \(jid)")
                return
            }
            #expect(bareJID.localPart == "user")
            #expect(bareJID.domainPart == "example.com")
        }

        @Test("Full JID parsed as .full")
        func parseFull() throws {
            let jid = try #require(JID.parse("user@example.com/resource"))
            guard case .full(let fullJID) = jid else {
                Issue.record("Expected .full, got \(jid)")
                return
            }
            #expect(fullJID.bareJID.localPart == "user")
            #expect(fullJID.resourcePart == "resource")
        }

        @Test("bareJID property extracts bare from full")
        func bareJIDFromFull() throws {
            let jid = try #require(JID.parse("user@example.com/resource"))
            #expect(jid.bareJID == BareJID.parse("user@example.com"))
        }
    }

    struct Equality {
        @Test("BareJIDs with same parts are equal")
        func bareJIDEquality() throws {
            let a = try #require(BareJID.parse("user@example.com"))
            let b = try #require(BareJID.parse("user@example.com"))
            #expect(a == b)
        }

        @Test("BareJIDs with different parts are not equal")
        func bareJIDInequality() throws {
            let a = try #require(BareJID.parse("user@example.com"))
            let b = try #require(BareJID.parse("other@example.com"))
            #expect(a != b)
        }

        @Test("FullJIDs with same parts are equal")
        func fullJIDEquality() throws {
            let a = try #require(FullJID.parse("user@example.com/res"))
            let b = try #require(FullJID.parse("user@example.com/res"))
            #expect(a == b)
        }
    }

    struct CodableRoundTrip {
        @Test("BareJID encodes as string and round-trips")
        func bareJIDCodable() throws {
            let jid = try #require(BareJID.parse("user@example.com"))
            let data = try JSONEncoder().encode(jid)
            let decoded = try JSONDecoder().decode(BareJID.self, from: data)
            #expect(jid == decoded)
        }

        @Test("FullJID encodes as string and round-trips")
        func fullJIDCodable() throws {
            let jid = try #require(FullJID.parse("user@example.com/resource"))
            let data = try JSONEncoder().encode(jid)
            let decoded = try JSONDecoder().decode(FullJID.self, from: data)
            #expect(jid == decoded)
        }

        @Test("JID encodes as string and round-trips")
        func jidCodable() throws {
            let jid = try #require(JID.parse("user@example.com/resource"))
            let data = try JSONEncoder().encode(jid)
            let decoded = try JSONDecoder().decode(JID.self, from: data)
            #expect(jid == decoded)
        }
    }

    struct Description {
        @Test("BareJID description formats correctly", arguments: [
            ("user@example.com", "user@example.com"),
            ("example.com", "example.com"),
        ])
        func bareJIDDescription(input: String, expected: String) throws {
            let jid = try #require(BareJID.parse(input))
            #expect(jid.description == expected)
        }

        @Test("FullJID description formats correctly")
        func fullJIDDescription() throws {
            let jid = try #require(FullJID.parse("user@example.com/resource"))
            #expect(jid.description == "user@example.com/resource")
        }

        @Test("JID description matches variant")
        func jidDescription() throws {
            let bare = try #require(JID.parse("example.com"))
            #expect(bare.description == "example.com")

            let full = try #require(JID.parse("user@example.com/res"))
            #expect(full.description == "user@example.com/res")
        }
    }
}

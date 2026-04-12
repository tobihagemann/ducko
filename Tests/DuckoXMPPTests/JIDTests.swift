import Foundation
import Testing
@testable import DuckoXMPP

enum JIDTests {
    struct BareJIDParsing {
        @Test(arguments: [
            ("user@example.com", "user", "example.com"),
            ("example.com", nil as String?, "example.com"),
            ("user@chat.example.com", "user", "chat.example.com"),
            ("user@192.168.1.1", "user", "192.168.1.1")
        ])
        func `Valid bare JIDs`(input: String, expectedLocal: String?, expectedDomain: String) throws {
            let jid = try #require(BareJID.parse(input))
            #expect(jid.localPart == expectedLocal)
            #expect(jid.domainPart == expectedDomain)
        }

        @Test(arguments: ["", "@example.com", "user@", "user@domain/res"])
        func `Invalid bare JIDs`(input: String) {
            #expect(BareJID.parse(input) == nil)
        }
    }

    struct FullJIDParsing {
        @Test(arguments: [
            ("user@example.com/resource", "user", "example.com", "resource"),
            ("example.com/resource", nil as String?, "example.com", "resource")
        ])
        func `Valid full JIDs`(
            input: String, expectedLocal: String?, expectedDomain: String, expectedResource: String
        ) throws {
            let jid = try #require(FullJID.parse(input))
            #expect(jid.bareJID.localPart == expectedLocal)
            #expect(jid.bareJID.domainPart == expectedDomain)
            #expect(jid.resourcePart == expectedResource)
        }

        @Test
        func `Resource may contain slashes`() throws {
            let jid = try #require(FullJID.parse("user@example.com/res/with/slashes"))
            #expect(jid.bareJID.localPart == "user")
            #expect(jid.bareJID.domainPart == "example.com")
            #expect(jid.resourcePart == "res/with/slashes")
        }

        @Test(arguments: ["", "user@example.com", "user@example.com/", "@domain/res"])
        func `Invalid full JIDs`(input: String) {
            #expect(FullJID.parse(input) == nil)
        }
    }

    struct JIDParsing {
        @Test
        func `Bare JID parsed as .bare`() throws {
            let jid = try #require(JID.parse("user@example.com"))
            guard case let .bare(bareJID) = jid else {
                Issue.record("Expected .bare, got \(jid)")
                return
            }
            #expect(bareJID.localPart == "user")
            #expect(bareJID.domainPart == "example.com")
        }

        @Test
        func `Full JID parsed as .full`() throws {
            let jid = try #require(JID.parse("user@example.com/resource"))
            guard case let .full(fullJID) = jid else {
                Issue.record("Expected .full, got \(jid)")
                return
            }
            #expect(fullJID.bareJID.localPart == "user")
            #expect(fullJID.resourcePart == "resource")
        }

        @Test
        func `bareJID property extracts bare from full`() throws {
            let jid = try #require(JID.parse("user@example.com/resource"))
            #expect(jid.bareJID == BareJID.parse("user@example.com"))
        }
    }

    struct Equality {
        @Test
        func `BareJIDs with same parts are equal`() throws {
            let a = try #require(BareJID.parse("user@example.com"))
            let b = try #require(BareJID.parse("user@example.com"))
            #expect(a == b)
        }

        @Test
        func `BareJIDs with different parts are not equal`() throws {
            let a = try #require(BareJID.parse("user@example.com"))
            let b = try #require(BareJID.parse("other@example.com"))
            #expect(a != b)
        }

        @Test
        func `FullJIDs with same parts are equal`() throws {
            let a = try #require(FullJID.parse("user@example.com/res"))
            let b = try #require(FullJID.parse("user@example.com/res"))
            #expect(a == b)
        }
    }

    struct CodableRoundTrip {
        @Test
        func `BareJID encodes as string and round-trips`() throws {
            let jid = try #require(BareJID.parse("user@example.com"))
            let data = try JSONEncoder().encode(jid)
            let decoded = try JSONDecoder().decode(BareJID.self, from: data)
            #expect(jid == decoded)
        }

        @Test
        func `FullJID encodes as string and round-trips`() throws {
            let jid = try #require(FullJID.parse("user@example.com/resource"))
            let data = try JSONEncoder().encode(jid)
            let decoded = try JSONDecoder().decode(FullJID.self, from: data)
            #expect(jid == decoded)
        }

        @Test
        func `JID encodes as string and round-trips`() throws {
            let jid = try #require(JID.parse("user@example.com/resource"))
            let data = try JSONEncoder().encode(jid)
            let decoded = try JSONDecoder().decode(JID.self, from: data)
            #expect(jid == decoded)
        }
    }

    struct CaseNormalization {
        @Test(arguments: [
            ("User@Example.COM", "user", "example.com"),
            ("USER@EXAMPLE.COM", "user", "example.com"),
            ("uSeR@eXaMpLe.CoM", "user", "example.com")
        ])
        func `Bare JID localpart and domain are lowercased`(
            input: String, expectedLocal: String, expectedDomain: String
        ) throws {
            let jid = try #require(BareJID.parse(input))
            #expect(jid.localPart == expectedLocal)
            #expect(jid.domainPart == expectedDomain)
        }

        @Test
        func `Domain-only bare JID is lowercased`() throws {
            let jid = try #require(BareJID.parse("Example.COM"))
            #expect(jid.domainPart == "example.com")
        }

        @Test
        func `BareJIDs differing only in case are equal`() throws {
            let a = try #require(BareJID.parse("User@Example.COM"))
            let b = try #require(BareJID.parse("user@example.com"))
            #expect(a == b)
        }

        @Test
        func `FullJID resource part preserves case`() throws {
            let jid = try #require(FullJID.parse("User@Example.COM/MyResource"))
            #expect(jid.bareJID.localPart == "user")
            #expect(jid.bareJID.domainPart == "example.com")
            #expect(jid.resourcePart == "MyResource")
        }

        @Test
        func `Mixed-case description is lowercased`() throws {
            let jid = try #require(BareJID.parse("User@Example.COM"))
            #expect(jid.description == "user@example.com")
        }

        @Test
        func `Codable round-trip normalizes case`() throws {
            let jid = try #require(BareJID.parse("User@Example.COM"))
            let data = try JSONEncoder().encode(jid)
            let json = try #require(String(data: data, encoding: .utf8))
            #expect(json.contains("user@example.com"))
            let decoded = try JSONDecoder().decode(BareJID.self, from: data)
            #expect(jid == decoded)
        }
    }

    struct Description {
        @Test(arguments: [
            ("user@example.com", "user@example.com"),
            ("example.com", "example.com")
        ])
        func `BareJID description formats correctly`(input: String, expected: String) throws {
            let jid = try #require(BareJID.parse(input))
            #expect(jid.description == expected)
        }

        @Test
        func `FullJID description formats correctly`() throws {
            let jid = try #require(FullJID.parse("user@example.com/resource"))
            #expect(jid.description == "user@example.com/resource")
        }

        @Test
        func `JID description matches variant`() throws {
            let bare = try #require(JID.parse("example.com"))
            #expect(bare.description == "example.com")

            let full = try #require(JID.parse("user@example.com/res"))
            #expect(full.description == "user@example.com/res")
        }
    }
}

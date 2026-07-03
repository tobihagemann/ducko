import Testing
@testable import DuckoCLI

struct TopicArgsParsingTests {
    @Test func `leading room JID targets that room`() {
        let result = parseTopicArgs("room@conference.example.com New topic", currentRoom: "other@conference.example.com")
        #expect(result?.roomJID == "room@conference.example.com")
        #expect(result?.subject == "New topic")
    }

    @Test func `bare leading word is subject for current room`() {
        let result = parseTopicArgs("Live status", currentRoom: "room@conference.example.com")
        #expect(result?.roomJID == "room@conference.example.com")
        #expect(result?.subject == "Live status")
    }

    @Test func `domain-only leading token is subject for current room`() {
        let result = parseTopicArgs("example.com is down", currentRoom: "room@conference.example.com")
        #expect(result?.roomJID == "room@conference.example.com")
        #expect(result?.subject == "example.com is down")
    }

    @Test func `single word is subject for current room`() {
        let result = parseTopicArgs("Announcements", currentRoom: "room@conference.example.com")
        #expect(result?.roomJID == "room@conference.example.com")
        #expect(result?.subject == "Announcements")
    }

    @Test func `lone JID token is subject text, not a room selector`() {
        let result = parseTopicArgs("room@conference.example.com", currentRoom: "other@conference.example.com")
        #expect(result?.roomJID == "other@conference.example.com")
        #expect(result?.subject == "room@conference.example.com")
    }

    @Test func `bare word with no current room returns nil`() {
        let result = parseTopicArgs("Live status", currentRoom: nil)
        #expect(result == nil)
    }

    @Test func `leading room JID works with no current room`() {
        let result = parseTopicArgs("room@conference.example.com Hello", currentRoom: nil)
        #expect(result?.roomJID == "room@conference.example.com")
        #expect(result?.subject == "Hello")
    }
}

import Testing
@testable import DuckoCore

struct JIDValidationTests {
    @Test(arguments: [
        "bob@example.com",
        "room@conference.example.com",
        "Bob@Example.COM"
    ])
    func `isValidUserOrRoomJID accepts a well-formed bare JID`(_ jidString: String) {
        #expect(JIDValidation.isValidUserOrRoomJID(jidString))
    }

    @Test(arguments: [
        "",
        "@",
        "a@",
        "@b",
        "a@b@c",
        "bob@",
        "example.com",
        "bob@example.com/resource",
        "a:b@example.com",
        "bob@-bad-.com"
    ])
    func `isValidUserOrRoomJID rejects garbage, a missing localpart, an excluded character, a bad domain, a domain-only JID, and a resource part`(_ jidString: String) {
        #expect(!JIDValidation.isValidUserOrRoomJID(jidString))
    }
}

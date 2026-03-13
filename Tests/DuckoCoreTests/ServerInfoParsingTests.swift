import Foundation
import Testing
@testable import DuckoCore

struct ServerInfoParsingTests {
    @Test
    func `ContactAddressType raw values`() {
        #expect(ContactAddressType.admin.rawValue == "admin-addresses")
        #expect(ContactAddressType.abuse.rawValue == "abuse-addresses")
        #expect(ContactAddressType.feedback.rawValue == "feedback-addresses")
        #expect(ContactAddressType.support.rawValue == "support-addresses")
        #expect(ContactAddressType.security.rawValue == "security-addresses")
        #expect(ContactAddressType.sales.rawValue == "sales-addresses")
    }

    @Test
    func `ContactAddressType display names`() {
        #expect(ContactAddressType.admin.displayName == "Admin")
        #expect(ContactAddressType.support.displayName == "Support")
    }

    @Test
    func `ServerInfo with addresses`() {
        let info = ServerInfo(contactAddresses: [
            ContactAddress(type: .admin, address: "xmpp:admin@example.com"),
            ContactAddress(type: .abuse, address: "mailto:abuse@example.com")
        ])
        #expect(info.contactAddresses.count == 2)
        #expect(info.contactAddresses[0].type == .admin)
        #expect(info.contactAddresses[1].address == "mailto:abuse@example.com")
    }

    @Test
    func `ServerInfo empty`() {
        let info = ServerInfo(contactAddresses: [])
        #expect(info.contactAddresses.isEmpty)
    }

    @Test
    func `ContactAddress identifiable`() {
        let a = ContactAddress(type: .admin, address: "a@example.com")
        let b = ContactAddress(type: .admin, address: "b@example.com")
        #expect(a.id != b.id)
    }
}

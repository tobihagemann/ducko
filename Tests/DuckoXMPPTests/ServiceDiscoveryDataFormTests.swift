import Testing
@testable import DuckoXMPP

struct ServiceDiscoveryDataFormTests {
    @Test
    func `InfoResult includes parsed forms`() {
        let result = ServiceDiscoveryModule.InfoResult(
            identities: [],
            features: ["http://jabber.org/protocol/disco#info"],
            forms: [
                [DataFormField(variable: "FORM_TYPE", type: "hidden", values: ["http://jabber.org/network/serverinfo"])]
            ]
        )
        #expect(result.forms.count == 1)
        #expect(result.forms[0][0].variable == "FORM_TYPE")
    }

    @Test
    func `InfoResult default forms is empty`() {
        let result = ServiceDiscoveryModule.InfoResult(
            identities: [],
            features: []
        )
        #expect(result.forms.isEmpty)
    }

    @Test
    func `Identity equality`() {
        let a = ServiceDiscoveryModule.Identity(category: "client", type: "pc", name: "Ducko")
        let b = ServiceDiscoveryModule.Identity(category: "client", type: "pc", name: "Ducko")
        #expect(a == b)
    }
}

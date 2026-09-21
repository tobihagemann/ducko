import DuckoCore
import Foundation
import Testing
@testable import DuckoCLI

struct OMEMOFormatterTests {
    private let device = OMEMODeviceInfo(peerJID: "bob@example.com", deviceID: 42, fingerprint: "0123456789abcdef", trustLevel: .trusted)

    private func jsonObject(_ output: String) throws -> [String: String] {
        try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String])
    }

    @Test func `plain device line shows id, grouped fingerprint and trust`() {
        #expect(PlainFormatter().formatOMEMODevice(device) == "  42  01234567 89abcdef  [trusted]")
    }

    @Test func `plain device line marks a missing fingerprint`() {
        let bare = OMEMODeviceInfo(peerJID: "bob@example.com", deviceID: 7, fingerprint: "", trustLevel: .undecided)
        #expect(PlainFormatter().formatOMEMODevice(bare) == "  7  (no fingerprint)  [undecided]")
    }

    @Test func `json device is structured`() throws {
        let object = try jsonObject(JSONFormatter().formatOMEMODevice(device))
        #expect(object == ["type": "omemo_device", "jid": "bob@example.com", "deviceID": "42", "fingerprint": "0123456789abcdef", "trust": "trusted"])
    }

    @Test func `json fingerprint keeps the raw hex`() throws {
        let object = try jsonObject(JSONFormatter().formatOMEMOFingerprint("0123456789abcdef"))
        #expect(object == ["type": "omemo_fingerprint", "fingerprint": "0123456789abcdef"])
    }

    @Test(arguments: [(OMEMOTrustLevel.trusted, "Trusted"), (.untrusted, "Untrusted")])
    func `trust change reads in every format`(trustLevel: OMEMOTrustLevel, verb: String) throws {
        #expect(PlainFormatter().formatOMEMOTrustChange(jid: "bob@example.com", deviceID: 42, trustLevel: trustLevel) == "\(verb) device 42 for bob@example.com.")
        #expect(ANSIFormatter().formatOMEMOTrustChange(jid: "bob@example.com", deviceID: 42, trustLevel: trustLevel).contains("\(verb) device 42 for bob@example.com."))
        let object = try jsonObject(JSONFormatter().formatOMEMOTrustChange(jid: "bob@example.com", deviceID: 42, trustLevel: trustLevel))
        #expect(object == ["type": "omemo_trust", "jid": "bob@example.com", "deviceID": "42", "trust": trustLevel.rawValue])
    }
}

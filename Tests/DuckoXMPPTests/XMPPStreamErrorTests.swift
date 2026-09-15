import Testing
@testable import DuckoXMPP

struct XMPPStreamErrorTests {
    @Test(arguments: [
        (XMPPStreamError.badFormat, "The server rejected the XML data (bad-format)"),
        (XMPPStreamError.badNamespacePrefix, "The server rejected the XML data (bad-namespace-prefix)"),
        (XMPPStreamError.conflict, "The connection conflicts with another connection"),
        (XMPPStreamError.connectionTimeout, "The connection timed out"),
        (XMPPStreamError.hostGone, "The server no longer serves this domain"),
        (XMPPStreamError.hostUnknown, "The server does not recognize this domain"),
        (XMPPStreamError.improperAddressing, "The server rejected the addressing (improper-addressing)"),
        (XMPPStreamError.internalServerError, "The server encountered an internal problem"),
        (XMPPStreamError.invalidFrom, "The server rejected the addressing (invalid-from)"),
        (XMPPStreamError.invalidNamespace, "The server rejected the XML data (invalid-namespace)"),
        (XMPPStreamError.invalidXML, "The server rejected the XML data (invalid-xml)"),
        (XMPPStreamError.notAuthorized, "The server did not authorize the connection"),
        (XMPPStreamError.notWellFormed, "The server rejected the XML data (not-well-formed)"),
        (XMPPStreamError.policyViolation, "The connection violates a server policy"),
        (XMPPStreamError.remoteConnectionFailed, "The server could not reach a required remote service"),
        (XMPPStreamError.reset, "The server requires a new connection"),
        (XMPPStreamError.resourceConstraint, "The server lacks resources for this connection"),
        (XMPPStreamError.restrictedXML, "The server rejected the XML data (restricted-xml)"),
        (XMPPStreamError.seeOtherHost, "The server requested a redirect"),
        (XMPPStreamError.systemShutdown, "The server is shutting down"),
        (XMPPStreamError.undefinedCondition, "The server closed the connection"),
        (XMPPStreamError.unsupportedEncoding, "The server rejected the XML data (unsupported-encoding)"),
        (XMPPStreamError.unsupportedFeature, "The connection uses unsupported protocol features (unsupported-feature)"),
        (XMPPStreamError.unsupportedStanzaType, "The connection uses unsupported protocol features (unsupported-stanza-type)"),
        (XMPPStreamError.unsupportedVersion, "The connection uses unsupported protocol features (unsupported-version)")
    ])
    func `Display text is readable`(condition: XMPPStreamError, expected: String) {
        #expect(condition.displayText == expected)
    }
}

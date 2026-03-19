import Testing
@testable import DuckoXMPP

// MARK: - Helpers

/// Builds a `<stream:features>` element with SASL2 authentication.
private func sasl2Features(
    mechanisms: [String],
    supportsBind2: Bool = false,
    supportsSM: Bool = false,
    supportsISR: Bool = false,
    channelBindingTypes: [String] = []
) -> XMLElement {
    var auth = XMLElement(name: "authentication", namespace: XMPPNamespaces.sasl2)
    for name in mechanisms {
        var mechanism = XMLElement(name: "mechanism")
        mechanism.addText(name)
        auth.addChild(mechanism)
    }

    if supportsBind2 || supportsSM || supportsISR {
        var inline = XMLElement(name: "inline")
        if supportsBind2 {
            inline.addChild(XMLElement(name: "bind", namespace: XMPPNamespaces.bind2))
        }
        if supportsSM {
            inline.addChild(XMLElement(name: "sm", namespace: XMPPNamespaces.sm))
        }
        if supportsISR {
            inline.addChild(XMLElement(name: "isr", namespace: XMPPNamespaces.isr))
        }
        auth.addChild(inline)
    }

    if !channelBindingTypes.isEmpty {
        var cbElement = XMLElement(name: "sasl-channel-binding", namespace: XMPPNamespaces.saslChannelBinding)
        for cbType in channelBindingTypes {
            cbElement.addChild(XMLElement(name: "channel-binding", attributes: ["type": cbType]))
        }
        auth.addChild(cbElement)
    }

    var features = XMLElement(name: "stream:features")
    features.addChild(auth)
    return features
}

/// Builds a SASL2 `<success>` element.
private func sasl2Success(
    jid: String,
    additionalData: String? = nil,
    bound: XMLElement? = nil
) -> XMLElement {
    var success = XMLElement(name: "success", namespace: XMPPNamespaces.sasl2)
    var authID = XMLElement(name: "authorization-identifier")
    authID.addText(jid)
    success.addChild(authID)
    if let additionalData {
        var ad = XMLElement(name: "additional-data")
        ad.addText(additionalData)
        success.addChild(ad)
    }
    if let bound {
        success.addChild(bound)
    }
    return success
}

// MARK: - Tests

enum SASL2AuthenticatorTests {
    struct FeatureParsing {
        @Test
        func `Parses SASL2 features with mechanisms`() {
            let features = sasl2Features(mechanisms: ["SCRAM-SHA-256", "PLAIN"])
            let parsed = SASL2Authenticator.parseFeatures(features)
            #expect(parsed != nil)
            #expect(parsed?.mechanisms.contains("SCRAM-SHA-256") == true)
            #expect(parsed?.mechanisms.contains("PLAIN") == true)
        }

        @Test
        func `Parses inline feature support`() {
            let features = sasl2Features(
                mechanisms: ["PLAIN"],
                supportsBind2: true,
                supportsSM: true,
                supportsISR: true
            )
            let parsed = SASL2Authenticator.parseFeatures(features)
            #expect(parsed?.supportsBind2 == true)
            #expect(parsed?.supportsSM == true)
            #expect(parsed?.supportsISR == true)
        }

        @Test
        func `Returns nil when no SASL2 authentication element`() {
            let features = XMLElement(name: "stream:features")
            let parsed = SASL2Authenticator.parseFeatures(features)
            #expect(parsed == nil)
        }

        @Test
        func `Returns nil when no mechanisms listed`() {
            var auth = XMLElement(name: "authentication", namespace: XMPPNamespaces.sasl2)
            auth.addChild(XMLElement(name: "inline"))
            var features = XMLElement(name: "stream:features")
            features.addChild(auth)
            let parsed = SASL2Authenticator.parseFeatures(features)
            #expect(parsed == nil)
        }

        @Test
        func `Parses channel binding types from XEP-0440`() {
            var auth = XMLElement(name: "authentication", namespace: XMPPNamespaces.sasl2)
            var mech = XMLElement(name: "mechanism")
            mech.addText("SCRAM-SHA-256")
            auth.addChild(mech)

            var cbElement = XMLElement(
                name: "sasl-channel-binding",
                namespace: XMPPNamespaces.saslChannelBinding
            )
            cbElement.addChild(XMLElement(
                name: "channel-binding",
                attributes: ["type": "tls-server-end-point"]
            ))
            cbElement.addChild(XMLElement(
                name: "channel-binding",
                attributes: ["type": "tls-exporter"]
            ))
            auth.addChild(cbElement)

            var features = XMLElement(name: "stream:features")
            features.addChild(auth)

            let parsed = SASL2Authenticator.parseFeatures(features)
            #expect(parsed?.channelBindingTypes.contains("tls-server-end-point") == true)
            #expect(parsed?.channelBindingTypes.contains("tls-exporter") == true)
            let cbCount = parsed?.channelBindingTypes.count ?? 0
            #expect(cbCount == 2)
        }

        @Test
        func `Channel binding types empty when element absent`() {
            let features = sasl2Features(mechanisms: ["SCRAM-SHA-256"])
            let parsed = SASL2Authenticator.parseFeatures(features)
            let isEmpty = parsed?.channelBindingTypes.isEmpty ?? true
            #expect(isEmpty)
        }
    }

    struct MechanismSelection {
        @Test
        func `Selects SCRAM-SHA-256 when all offered`() throws {
            var auth = SASL2Authenticator()
            let element = try auth.begin(
                features: sasl2Features(mechanisms: ["PLAIN", "SCRAM-SHA-1", "SCRAM-SHA-256"]),
                authcid: "user",
                password: "pencil",
                inlinePayloads: []
            )
            #expect(element.attribute("mechanism") == "SCRAM-SHA-256")
        }

        @Test
        func `Falls back to PLAIN when no SCRAM available`() throws {
            var auth = SASL2Authenticator()
            let element = try auth.begin(
                features: sasl2Features(mechanisms: ["PLAIN"]),
                authcid: "user",
                password: "pencil",
                inlinePayloads: []
            )
            #expect(element.attribute("mechanism") == "PLAIN")
        }

        @Test
        func `Throws when no supported mechanism`() {
            var auth = SASL2Authenticator()
            #expect(throws: SASLAuthError.self) {
                try auth.begin(
                    features: sasl2Features(mechanisms: ["EXTERNAL"]),
                    authcid: "user",
                    password: "pencil",
                    inlinePayloads: []
                )
            }
        }
    }

    struct PLUSMechanismSelection {
        private static let mockCBData: [UInt8] = Array(repeating: 0xAB, count: 32)

        @Test
        func `Selects SCRAM-SHA-256-PLUS when CB data available and server advertises type`() throws {
            var auth = SASL2Authenticator()
            let element = try auth.begin(
                features: sasl2Features(
                    mechanisms: ["SCRAM-SHA-256-PLUS", "SCRAM-SHA-256", "PLAIN"],
                    channelBindingTypes: ["tls-server-end-point"]
                ),
                authcid: "user",
                password: "pencil",
                inlinePayloads: [],
                channelBindingData: Self.mockCBData
            )
            #expect(element.attribute("mechanism") == "SCRAM-SHA-256-PLUS")
        }

        @Test
        func `Falls back to non-PLUS when server does not advertise CB types`() throws {
            var auth = SASL2Authenticator()
            let element = try auth.begin(
                features: sasl2Features(mechanisms: ["SCRAM-SHA-256-PLUS", "SCRAM-SHA-256", "PLAIN"]),
                authcid: "user",
                password: "pencil",
                inlinePayloads: [],
                channelBindingData: Self.mockCBData
            )
            #expect(element.attribute("mechanism") == "SCRAM-SHA-256")
        }

        @Test
        func `Falls back to SCRAM-SHA-256 when no PLUS offered`() throws {
            var auth = SASL2Authenticator()
            let element = try auth.begin(
                features: sasl2Features(mechanisms: ["SCRAM-SHA-256", "PLAIN"]),
                authcid: "user",
                password: "pencil",
                inlinePayloads: [],
                channelBindingData: Self.mockCBData
            )
            #expect(element.attribute("mechanism") == "SCRAM-SHA-256")
        }

        @Test
        func `Does not offer PLUS when no CB data`() throws {
            var auth = SASL2Authenticator()
            let element = try auth.begin(
                features: sasl2Features(mechanisms: ["SCRAM-SHA-256-PLUS", "PLAIN"]),
                authcid: "user",
                password: "pencil",
                inlinePayloads: []
            )
            #expect(element.attribute("mechanism") == "PLAIN")
        }

        @Test
        func `Selects EXTERNAL when client certificate available`() throws {
            var auth = SASL2Authenticator()
            let element = try auth.begin(
                features: sasl2Features(mechanisms: ["EXTERNAL", "SCRAM-SHA-256"]),
                authcid: "user",
                password: "pencil",
                inlinePayloads: [],
                hasClientCertificate: true
            )
            #expect(element.attribute("mechanism") == "EXTERNAL")
        }

        @Test
        func `Skips EXTERNAL when no client certificate`() throws {
            var auth = SASL2Authenticator()
            let element = try auth.begin(
                features: sasl2Features(mechanisms: ["EXTERNAL", "SCRAM-SHA-256"]),
                authcid: "user",
                password: "pencil",
                inlinePayloads: []
            )
            #expect(element.attribute("mechanism") == "SCRAM-SHA-256")
        }

        @Test
        func `Falls back to non-PLUS when server CB types exclude tls-server-end-point`() throws {
            var auth = SASL2Authenticator()
            let element = try auth.begin(
                features: sasl2Features(
                    mechanisms: ["SCRAM-SHA-256-PLUS", "SCRAM-SHA-256"],
                    channelBindingTypes: ["tls-exporter"]
                ),
                authcid: "user",
                password: "pencil",
                inlinePayloads: [],
                channelBindingData: Self.mockCBData
            )
            #expect(element.attribute("mechanism") == "SCRAM-SHA-256")
        }
    }

    struct PLAINFlow {
        @Test
        func `Full PLAIN flow with SASL2 framing`() throws {
            var auth = SASL2Authenticator()
            let authElement = try auth.begin(
                features: sasl2Features(mechanisms: ["PLAIN"]),
                authcid: "user",
                password: "pencil",
                inlinePayloads: []
            )

            #expect(authElement.name == "authenticate")
            #expect(authElement.namespace == XMPPNamespaces.sasl2)
            #expect(authElement.child(named: "initial-response") != nil)

            let success = sasl2Success(jid: "user@example.com/res1")
            let response = auth.receive(success)
            guard case let .success(result) = response else {
                Issue.record("Expected success, got \(response)")
                return
            }
            #expect(result.fullJID.description == "user@example.com/res1")
        }
    }

    struct SuccessParsing {
        @Test
        func `Parses authorization-identifier as bound JID`() throws {
            var auth = SASL2Authenticator()
            _ = try auth.begin(
                features: sasl2Features(mechanisms: ["PLAIN"]),
                authcid: "user",
                password: "pencil",
                inlinePayloads: []
            )

            let success = sasl2Success(jid: "user@example.com/ducko-abc")
            let response = auth.receive(success)
            guard case let .success(result) = response else {
                Issue.record("Expected success, got \(response)")
                return
            }
            #expect(result.fullJID.bareJID.localPart == "user")
            #expect(result.fullJID.bareJID.domainPart == "example.com")
            #expect(result.fullJID.resourcePart == "ducko-abc")
        }

        @Test
        func `Parses bound element from Bind 2`() throws {
            var auth = SASL2Authenticator()
            _ = try auth.begin(
                features: sasl2Features(mechanisms: ["PLAIN"]),
                authcid: "user",
                password: "pencil",
                inlinePayloads: []
            )

            let bound = XMLElement(name: "bound", namespace: XMPPNamespaces.bind2)
            let success = sasl2Success(jid: "user@example.com/res", bound: bound)
            let response = auth.receive(success)
            guard case let .success(result) = response else {
                Issue.record("Expected success, got \(response)")
                return
            }
            #expect(result.bound != nil)
            #expect(result.bound?.name == "bound")
        }

        @Test
        func `Bound is nil when not using Bind 2`() throws {
            var auth = SASL2Authenticator()
            _ = try auth.begin(
                features: sasl2Features(mechanisms: ["PLAIN"]),
                authcid: "user",
                password: "pencil",
                inlinePayloads: []
            )

            let success = sasl2Success(jid: "user@example.com/res")
            let response = auth.receive(success)
            guard case let .success(result) = response else {
                Issue.record("Expected success, got \(response)")
                return
            }
            #expect(result.bound == nil)
        }
    }

    struct FailureHandling {
        @Test
        func `Server failure with condition`() throws {
            var auth = SASL2Authenticator()
            _ = try auth.begin(
                features: sasl2Features(mechanisms: ["PLAIN"]),
                authcid: "user",
                password: "pencil",
                inlinePayloads: []
            )

            var failure = XMLElement(name: "failure", namespace: XMPPNamespaces.sasl2)
            failure.addChild(XMLElement(name: "not-authorized"))

            let response = auth.receive(failure)
            guard case let .failure(.serverFailure(condition, _)) = response else {
                Issue.record("Expected serverFailure, got \(response)")
                return
            }
            #expect(condition == "not-authorized")
        }

        @Test
        func `Receive without begin returns invalidState`() {
            var auth = SASL2Authenticator()
            let response = auth.receive(XMLElement(name: "success", namespace: XMPPNamespaces.sasl2))
            guard case .failure(.invalidState) = response else {
                Issue.record("Expected invalidState, got \(response)")
                return
            }
        }
    }

    struct InlinePayloads {
        @Test
        func `Authenticate element includes inline payloads`() throws {
            var auth = SASL2Authenticator()

            let bind = buildBind2Request(enableSM: true, enableCarbons: true)
            let element = try auth.begin(
                features: sasl2Features(mechanisms: ["PLAIN"], supportsBind2: true, supportsSM: true),
                authcid: "user",
                password: "pencil",
                inlinePayloads: [bind]
            )

            let bindChild = element.child(named: "bind", namespace: XMPPNamespaces.bind2)
            #expect(bindChild != nil)
            #expect(bindChild?.childText(named: "tag") == "Ducko")
            #expect(bindChild?.child(named: "enable", namespace: XMPPNamespaces.sm) != nil)
            #expect(bindChild?.child(named: "enable", namespace: XMPPNamespaces.carbons) != nil)
        }
    }

    struct Bind2Request {
        @Test
        func `Builds correct Bind 2 request`() {
            let bind = buildBind2Request(enableSM: true, enableCarbons: true)
            #expect(bind.name == "bind")
            #expect(bind.namespace == XMPPNamespaces.bind2)
            #expect(bind.childText(named: "tag") == "Ducko")

            let smEnable = bind.child(named: "enable", namespace: XMPPNamespaces.sm)
            #expect(smEnable?.attribute("resume") == "true")

            let carbonsEnable = bind.child(named: "enable", namespace: XMPPNamespaces.carbons)
            #expect(carbonsEnable != nil)
        }

        @Test
        func `Uses custom tag when provided`() {
            let bind = buildBind2Request(tag: "laptop")
            #expect(bind.childText(named: "tag") == "laptop")
        }

        @Test
        func `Omits SM and carbons when not requested`() {
            let bind = buildBind2Request(enableSM: false, enableCarbons: false)
            #expect(bind.child(named: "enable", namespace: XMPPNamespaces.sm) == nil)
            #expect(bind.child(named: "enable", namespace: XMPPNamespaces.carbons) == nil)
        }
    }

    struct ISRAuthenticate {
        @Test
        func `Builds correct ISR authenticate element`() {
            let smResume = XMLElement(
                name: "resume",
                namespace: XMPPNamespaces.sm,
                attributes: ["previd": "sm-id-1", "h": "42"]
            )
            let auth = buildISRAuthenticate(token: "secret-token", smResumeElement: smResume)

            #expect(auth.name == "authenticate")
            #expect(auth.namespace == XMPPNamespaces.sasl2)
            #expect(auth.attribute("mechanism") == "HT-SHA-256-ENDP")

            let instResume = auth.child(named: "inst-resume", namespace: XMPPNamespaces.isr)
            #expect(instResume != nil)

            let resume = instResume?.child(named: "resume", namespace: XMPPNamespaces.sm)
            #expect(resume?.attribute("previd") == "sm-id-1")
            #expect(resume?.attribute("h") == "42")
        }
    }
}

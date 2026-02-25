import Testing

@testable import DuckoXMPP

// MARK: - Helpers

/// Builds a `<stream:features>` element with the given SASL mechanism names.
private func features(mechanisms: [String]) -> XMLElement {
    var mechanismsElement = XMLElement(name: "mechanisms", namespace: saslNamespace)
    for name in mechanisms {
        var mechanism = XMLElement(name: "mechanism")
        mechanism.addText(name)
        mechanismsElement.addChild(mechanism)
    }
    var features = XMLElement(name: "stream:features")
    features.addChild(mechanismsElement)
    return features
}

// MARK: - Tests

struct SASLAuthenticatorTests {
    struct MechanismSelection {
        @Test("Selects SCRAM-SHA-256 when all offered")
        func selectsSCRAMSHA256() throws {
            var auth = SASLAuthenticator()
            let element = try auth.begin(
                features: features(mechanisms: ["PLAIN", "SCRAM-SHA-1", "SCRAM-SHA-256"]),
                authcid: "user",
                password: "pencil"
            )
            #expect(element.attribute("mechanism") == "SCRAM-SHA-256")
        }

        @Test("Selects SCRAM-SHA-1 when SHA-256 unavailable")
        func selectsSCRAMSHA1() throws {
            var auth = SASLAuthenticator()
            let element = try auth.begin(
                features: features(mechanisms: ["PLAIN", "SCRAM-SHA-1"]),
                authcid: "user",
                password: "pencil"
            )
            #expect(element.attribute("mechanism") == "SCRAM-SHA-1")
        }

        @Test("Falls back to PLAIN when no SCRAM available")
        func fallsBackToPlain() throws {
            var auth = SASLAuthenticator()
            let element = try auth.begin(
                features: features(mechanisms: ["PLAIN"]),
                authcid: "user",
                password: "pencil"
            )
            #expect(element.attribute("mechanism") == "PLAIN")
        }

        @Test("Matches mechanism names case-insensitively")
        func caseInsensitiveMatch() throws {
            var auth = SASLAuthenticator()
            let element = try auth.begin(
                features: features(mechanisms: ["plain", "scram-sha-1"]),
                authcid: "user",
                password: "pencil"
            )
            #expect(element.attribute("mechanism") == "SCRAM-SHA-1")
        }

        @Test("Throws when no supported mechanism")
        func throwsNoSupportedMechanism() {
            var auth = SASLAuthenticator()
            #expect(throws: SASLAuthError.self) {
                try auth.begin(
                    features: features(mechanisms: ["EXTERNAL", "GSSAPI"]),
                    authcid: "user",
                    password: "pencil"
                )
            }
        }

        @Test("Throws when no mechanisms element")
        func throwsNoMechanisms() {
            var auth = SASLAuthenticator()
            let emptyFeatures = XMLElement(name: "stream:features")
            #expect(throws: SASLAuthError.self) {
                try auth.begin(features: emptyFeatures, authcid: "user", password: "pencil")
            }
        }
    }

    struct PLAINFlow {
        @Test("Full PLAIN flow: begin → success")
        func fullPlainFlow() throws {
            var auth = SASLAuthenticator()
            let authElement = try auth.begin(
                features: features(mechanisms: ["PLAIN"]),
                authcid: "user",
                password: "pencil"
            )

            #expect(authElement.name == "auth")
            #expect(authElement.namespace == saslNamespace)

            let success = XMLElement(name: "success", namespace: saslNamespace)
            let response = auth.receive(success)
            guard case .success = response else {
                Issue.record("Expected success, got \(response)")
                return
            }
        }
    }

    struct FailureHandling {
        @Test("Server failure with condition and text")
        func serverFailureWithConditionAndText() throws {
            var auth = SASLAuthenticator()
            _ = try auth.begin(
                features: features(mechanisms: ["PLAIN"]),
                authcid: "user",
                password: "pencil"
            )

            var failure = XMLElement(name: "failure", namespace: saslNamespace)
            failure.addChild(XMLElement(name: "not-authorized"))
            var text = XMLElement(name: "text")
            text.addText("Invalid credentials")
            failure.addChild(text)

            let response = auth.receive(failure)
            guard case .failure(.serverFailure(let condition, let errorText)) = response else {
                Issue.record("Expected serverFailure, got \(response)")
                return
            }
            #expect(condition == "not-authorized")
            #expect(errorText == "Invalid credentials")
        }

        @Test("Server failure with condition only")
        func serverFailureConditionOnly() throws {
            var auth = SASLAuthenticator()
            _ = try auth.begin(
                features: features(mechanisms: ["PLAIN"]),
                authcid: "user",
                password: "pencil"
            )

            var failure = XMLElement(name: "failure", namespace: saslNamespace)
            failure.addChild(XMLElement(name: "temporary-auth-failure"))

            let response = auth.receive(failure)
            guard case .failure(.serverFailure(let condition, let errorText)) = response else {
                Issue.record("Expected serverFailure, got \(response)")
                return
            }
            #expect(condition == "temporary-auth-failure")
            #expect(errorText == nil)
        }

        @Test("Receive without begin returns invalidState")
        func receiveWithoutBegin() {
            var auth = SASLAuthenticator()
            let response = auth.receive(XMLElement(name: "success", namespace: saslNamespace))
            guard case .failure(.invalidState) = response else {
                Issue.record("Expected invalidState, got \(response)")
                return
            }
        }

        @Test("Unexpected element name returns invalidState")
        func unexpectedElement() throws {
            var auth = SASLAuthenticator()
            _ = try auth.begin(
                features: features(mechanisms: ["PLAIN"]),
                authcid: "user",
                password: "pencil"
            )

            let response = auth.receive(XMLElement(name: "unknown"))
            guard case .failure(.invalidState) = response else {
                Issue.record("Expected invalidState, got \(response)")
                return
            }
        }
    }

    struct SCRAMFlow {
        @Test("Full SCRAM-SHA-256 flow through authenticator")
        func fullSCRAMSHA256Flow() throws {
            let clientNonce = "rOprNGfwEbeRWgbNEkqO"
            var mech = SCRAMSHA256(nonceGenerator: { clientNonce })
            let authElement = mech.start(authcid: "user", password: "pencil")
            var auth = SASLAuthenticator(mechanism: .scramSHA256(mech))

            #expect(authElement.name == "auth")

            // Server challenge
            let serverFirst =
                "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
            var challenge = XMLElement(name: "challenge", namespace: saslNamespace)
            challenge.addText(Base64.encode(serverFirst))

            let challengeResult = auth.receive(challenge)
            guard case .continueWith(let responseElement) = challengeResult else {
                Issue.record("Expected continueWith, got \(challengeResult)")
                return
            }
            #expect(responseElement.name == "response")
            #expect(responseElement.namespace == saslNamespace)

            // Server success
            let serverSignature = "6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="
            var success = XMLElement(name: "success", namespace: saslNamespace)
            success.addText(Base64.encode("v=\(serverSignature)"))

            let successResult = auth.receive(success)
            guard case .success = successResult else {
                Issue.record("Expected success, got \(successResult)")
                return
            }
        }
    }
}

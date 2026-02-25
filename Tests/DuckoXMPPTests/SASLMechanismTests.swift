import CryptoKit
import Testing

@testable import DuckoXMPP

// MARK: - Base64 Tests

struct Base64Tests {
    @Test("Encode empty")
    func encodeEmpty() {
        #expect(Base64.encode([]) == "")
    }

    @Test("Decode empty")
    func decodeEmpty() {
        #expect(Base64.decode("") == [])
    }

    @Test("Encode/decode round-trip", arguments: [
        "Hello, World!",
        "user",
        "pencil",
        "\0user\0pencil",
        "n,,n=user,r=fyko+d2lbbFgONRv9qkxdawL",
    ])
    func roundTrip(input: String) {
        let encoded = Base64.encode(input)
        let decoded = Base64.decodeString(encoded)
        #expect(decoded == input)
    }

    @Test("Encode known vectors", arguments: [
        ("", ""),
        ("f", "Zg=="),
        ("fo", "Zm8="),
        ("foo", "Zm9v"),
        ("foob", "Zm9vYg=="),
        ("fooba", "Zm9vYmE="),
        ("foobar", "Zm9vYmFy"),
    ])
    func encodeKnownVectors(input: String, expected: String) {
        #expect(Base64.encode(input) == expected)
    }

    @Test("Decode rejects invalid input")
    func decodeRejectsInvalid() {
        #expect(Base64.decode("!!!") == nil)
        #expect(Base64.decode("A") == nil) // not multiple of 4
    }

    @Test("Decode rejects non-final padding")
    func decodeRejectsNonFinalPadding() {
        #expect(Base64.decode("AB==CD==") == nil) // padding in non-final quartet
    }

    @Test("Decode rejects mismatched padding")
    func decodeRejectsMismatchedPadding() {
        #expect(Base64.decode("AB=A") == nil) // 3rd is = but 4th is not
    }
}

// MARK: - SASL PLAIN Tests

struct SASLPlainTests {
    @Test("Start produces correct auth element")
    func startProducesCorrectAuth() throws {
        var mechanism = SASLPlain()
        let auth = mechanism.start(authcid: "user", password: "pencil")

        #expect(auth.name == "auth")
        #expect(auth.namespace == saslNamespace)
        #expect(auth.attribute("mechanism") == "PLAIN")

        let payload = try #require(auth.textContent)
        let decoded = try #require(Base64.decode(payload))
        let expected: [UInt8] = [0] + Array("user".utf8) + [0] + Array("pencil".utf8)
        #expect(decoded == expected)
    }

    @Test("Handle challenge returns failure")
    func handleChallengeReturnsFails() {
        var mechanism = SASLPlain()
        _ = mechanism.start(authcid: "user", password: "pencil")
        let response = mechanism.handleChallenge(XMLElement(name: "challenge", namespace: saslNamespace))
        guard case .failure(.invalidState) = response else {
            Issue.record("Expected invalidState failure, got \(response)")
            return
        }
    }

    @Test("Handle success returns success")
    func handleSuccessReturnsSuccess() {
        var mechanism = SASLPlain()
        _ = mechanism.start(authcid: "user", password: "pencil")
        let response = mechanism.handleSuccess(XMLElement(name: "success", namespace: saslNamespace))
        guard case .success = response else {
            Issue.record("Expected success, got \(response)")
            return
        }
    }
}

// MARK: - SCRAM-SHA-1 Tests (RFC 5802 §5 test vector)

struct SCRAMSHA1Tests {
    // RFC 5802 §5 test vector
    private static let clientNonce = "fyko+d2lbbFgONRv9qkxdawL"
    private static let serverFirstMessage = "r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,s=QSXCR+Q6sek8bf92,i=4096"
    private static let expectedServerSignature = "rmF9pqV8S7suAoZWja4dJRkFsKQ="

    @Test("Full SCRAM-SHA-1 exchange with RFC 5802 test vector")
    func fullExchange() throws {
        var mechanism = SCRAMSHA1(nonceGenerator: { Self.clientNonce })
        let auth = mechanism.start(authcid: "user", password: "pencil")

        // Verify client-first-message
        let authPayload = try #require(auth.textContent)
        let clientFirst = try #require(Base64.decodeString(authPayload))
        #expect(clientFirst == "n,,n=user,r=fyko+d2lbbFgONRv9qkxdawL")

        // Server sends challenge with server-first-message
        var challenge = XMLElement(name: "challenge", namespace: saslNamespace)
        challenge.addText(Base64.encode(Self.serverFirstMessage))

        let challengeResponse = mechanism.handleChallenge(challenge)
        guard case .continueWith(let responseElement) = challengeResponse else {
            Issue.record("Expected continueWith, got \(challengeResponse)")
            return
        }

        // Verify client-final-message
        let responsePayload = try #require(responseElement.textContent)
        let clientFinal = try #require(Base64.decodeString(responsePayload))
        #expect(clientFinal.hasPrefix("c=biws,r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,p="))

        // Server sends success with server signature
        var success = XMLElement(name: "success", namespace: saslNamespace)
        success.addText(Base64.encode("v=\(Self.expectedServerSignature)"))

        let successResponse = mechanism.handleSuccess(success)
        guard case .success = successResponse else {
            Issue.record("Expected success, got \(successResponse)")
            return
        }
    }

    @Test("Client-first-message bare matches RFC 5802 §5")
    func clientFirstMessageBare() throws {
        var state = SCRAMState<Insecure.SHA1>(nonceGenerator: { Self.clientNonce })
        let message = state.clientFirstMessage(authcid: "user", password: "pencil")
        #expect(message == "n,,n=user,r=fyko+d2lbbFgONRv9qkxdawL")
    }

    @Test("Client-final-message proof matches RFC 5802 §5")
    func clientFinalMessageProof() throws {
        var state = SCRAMState<Insecure.SHA1>(nonceGenerator: { Self.clientNonce })
        _ = state.clientFirstMessage(authcid: "user", password: "pencil")
        let result = state.clientFinalMessage(serverFirstMessage: Self.serverFirstMessage)
        let clientFinal = try result.get()
        #expect(clientFinal == "c=biws,r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,p=v0X8v3Bz2T0CJGbJQyF0X+HI4Ts=")
    }

    @Test("Server signature verification matches RFC 5802 §5")
    func serverSignatureVerification() throws {
        var state = SCRAMState<Insecure.SHA1>(nonceGenerator: { Self.clientNonce })
        _ = state.clientFirstMessage(authcid: "user", password: "pencil")
        _ = state.clientFinalMessage(serverFirstMessage: Self.serverFirstMessage)
        let result = state.verifyServerFinal(serverFinalMessage: "v=\(Self.expectedServerSignature)")
        try result.get()
    }

    @Test("Invalid server nonce rejected")
    func invalidServerNonce() {
        var state = SCRAMState<Insecure.SHA1>(nonceGenerator: { Self.clientNonce })
        _ = state.clientFirstMessage(authcid: "user", password: "pencil")
        let result = state.clientFinalMessage(serverFirstMessage: "r=WRONG_NONCE,s=QSXCR+Q6sek8bf92,i=4096")
        guard case .failure(.invalidServerNonce) = result else {
            Issue.record("Expected invalidServerNonce, got \(result)")
            return
        }
    }

    @Test("Iteration count below minimum rejected")
    func iterationCountTooLow() {
        var state = SCRAMState<Insecure.SHA1>(nonceGenerator: { Self.clientNonce })
        _ = state.clientFirstMessage(authcid: "user", password: "pencil")
        let result = state.clientFinalMessage(
            serverFirstMessage: "r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,s=QSXCR+Q6sek8bf92,i=100")
        guard case .failure(.iterationCountTooLow(100)) = result else {
            Issue.record("Expected iterationCountTooLow(100), got \(result)")
            return
        }
    }

    @Test("Wrong server signature rejected")
    func wrongServerSignature() {
        var state = SCRAMState<Insecure.SHA1>(nonceGenerator: { Self.clientNonce })
        _ = state.clientFirstMessage(authcid: "user", password: "pencil")
        _ = state.clientFinalMessage(serverFirstMessage: Self.serverFirstMessage)
        let result = state.verifyServerFinal(serverFinalMessage: "v=AAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        guard case .failure(.serverSignatureMismatch) = result else {
            Issue.record("Expected serverSignatureMismatch, got \(result)")
            return
        }
    }

    @Test("Username escaping: = becomes =3D, comma becomes =2C")
    func usernameEscaping() throws {
        var state = SCRAMState<Insecure.SHA1>(nonceGenerator: { "testnonce" })
        let message = state.clientFirstMessage(authcid: "user=name,test", password: "pass")
        #expect(message.contains("n=user=3Dname=2Ctest"))
    }
}

// MARK: - SCRAM-SHA-256 Tests (RFC 7677 §3 test vector)

struct SCRAMSHA256Tests {
    // RFC 7677 §3 test vector
    private static let clientNonce = "rOprNGfwEbeRWgbNEkqO"
    private static let serverFirstMessage =
        "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
    private static let expectedServerSignature = "6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="

    @Test("Full SCRAM-SHA-256 exchange with RFC 7677 test vector")
    func fullExchange() throws {
        var mechanism = SCRAMSHA256(nonceGenerator: { Self.clientNonce })
        let auth = mechanism.start(authcid: "user", password: "pencil")

        // Verify client-first-message
        let authPayload = try #require(auth.textContent)
        let clientFirst = try #require(Base64.decodeString(authPayload))
        #expect(clientFirst == "n,,n=user,r=rOprNGfwEbeRWgbNEkqO")

        // Server sends challenge
        var challenge = XMLElement(name: "challenge", namespace: saslNamespace)
        challenge.addText(Base64.encode(Self.serverFirstMessage))

        let challengeResponse = mechanism.handleChallenge(challenge)
        guard case .continueWith(let responseElement) = challengeResponse else {
            Issue.record("Expected continueWith, got \(challengeResponse)")
            return
        }

        // Verify client-final-message
        let responsePayload = try #require(responseElement.textContent)
        let clientFinal = try #require(Base64.decodeString(responsePayload))
        #expect(clientFinal.hasPrefix("c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p="))

        // Server sends success
        var success = XMLElement(name: "success", namespace: saslNamespace)
        success.addText(Base64.encode("v=\(Self.expectedServerSignature)"))

        let successResponse = mechanism.handleSuccess(success)
        guard case .success = successResponse else {
            Issue.record("Expected success, got \(successResponse)")
            return
        }
    }

    @Test("Client-final-message proof matches RFC 7677 §3")
    func clientFinalMessageProof() throws {
        var state = SCRAMState<SHA256>(nonceGenerator: { Self.clientNonce })
        _ = state.clientFirstMessage(authcid: "user", password: "pencil")
        let result = state.clientFinalMessage(serverFirstMessage: Self.serverFirstMessage)
        let clientFinal = try result.get()
        #expect(
            clientFinal
                == "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ="
        )
    }

    @Test("Invalid base64 in challenge rejected")
    func invalidBase64InChallenge() {
        var mechanism = SCRAMSHA256(nonceGenerator: { Self.clientNonce })
        _ = mechanism.start(authcid: "user", password: "pencil")

        var challenge = XMLElement(name: "challenge", namespace: saslNamespace)
        challenge.addText("!!!invalid!!!")

        let response = mechanism.handleChallenge(challenge)
        guard case .failure(.invalidBase64) = response else {
            Issue.record("Expected invalidBase64, got \(response)")
            return
        }
    }

    @Test("Malformed challenge rejected")
    func malformedChallenge() throws {
        var state = SCRAMState<SHA256>(nonceGenerator: { Self.clientNonce })
        _ = state.clientFirstMessage(authcid: "user", password: "pencil")
        let result = state.clientFinalMessage(serverFirstMessage: "garbage")
        guard case .failure(.malformedChallenge) = result else {
            Issue.record("Expected malformedChallenge, got \(result)")
            return
        }
    }
}

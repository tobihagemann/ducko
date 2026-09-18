import Dispatch
import Foundation
import NIOCore
import NIOSSL
@preconcurrency import Security

/// NIOSSL couples its IP identity check to the dialed address; XMPP host overrides must retain the account identity.
func verifyIPCertificateChain(_ chain: [NIOSSLCertificate], ipAddress: String, trustRoots: [[UInt8]], promise: EventLoopPromise<NIOSSLVerificationResult>) {
    do {
        let certificates = try chain.map { try securityCertificate($0.toDERBytes()) }
        let policy = SecPolicyCreateSSL(true, ipAddress as CFString)
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificates as CFArray, policy, &trust) == errSecSuccess, let trust else {
            throw verificationError
        }
        if !trustRoots.isEmpty {
            let anchors = try trustRoots.map(securityCertificate)
            guard SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust, false) == errSecSuccess else {
                throw verificationError
            }
        }
        let queue = DispatchQueue(label: "im.ducko.xmpp.iptrust")
        // Security requires invocation on the same queue that receives its asynchronous completion.
        queue.async {
            let status = SecTrustEvaluateAsyncWithError(trust, queue) { _, verified, _ in
                promise.succeed(verified ? .certificateVerified : .failed)
            }
            if status != errSecSuccess { promise.fail(verificationError) }
        }
    } catch {
        promise.fail(error)
    }
}

private let verificationError = XMPPClientError.tlsNegotiationFailed("The server certificate could not be verified")

private func securityCertificate(_ bytes: [UInt8]) throws -> SecCertificate {
    guard let certificate = SecCertificateCreateWithData(nil, Data(bytes) as CFData) else { throw verificationError }
    return certificate
}

import Foundation
import Logging
import NIOCore
import NIOSSL
import NIOTLS
@preconcurrency import Security

private let log = Logger(label: "im.ducko.xmpp.transport")

struct NIOHandshakeResult: Sendable {
    let info: TLSInfo
    let binding: [UInt8]
}

final class NIOReceiveHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private var continuation: AsyncStream<[UInt8]>.Continuation?
    private var handshake: (result: EventLoopPromise<NIOHandshakeResult>, continuation: AsyncStream<[UInt8]>.Continuation)?

    func stop() {
        continuation?.finish()
        continuation = nil
    }

    func begin(_ continuation: AsyncStream<[UInt8]>.Continuation) {
        self.continuation = continuation
    }

    func prepareHandshake(_ result: EventLoopPromise<NIOHandshakeResult>, continuation: AsyncStream<[UInt8]>.Continuation, timeout: Duration) {
        handshake = (result, continuation)
        let owner = NIOLoopBound(self, eventLoop: result.futureResult.eventLoop)
        let deadline = result.futureResult.eventLoop.scheduleTask(in: TimeAmount(timeout)) {
            owner.value.failHandshake(XMPPClientError.timeout)
        }
        result.futureResult.whenComplete { _ in deadline.cancel() }
    }

    func failHandshake(_ error: any Error) {
        handshake?.result.fail(error)
        handshake = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard let continuation else {
            context.close(promise: nil)
            return
        }
        let buffer = unwrapInboundIn(data)
        continuation.yield(Array(buffer.readableBytesView))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case let TLSUserEvent.handshakeCompleted(negotiatedProtocol) = event {
            log.debug("TLS handshake completed", metadata: ["alpn": .string(negotiatedProtocol ?? "none")])
            do {
                let ssl = try context.pipeline.syncOperations.handler(type: NIOSSLClientHandler.self)
                guard let peer = ssl.peerCertificate,
                      let cert = try SecCertificateCreateWithData(nil, Data(peer.toDERBytes()) as CFData),
                      let version = ssl.tlsVersion else {
                    throw XMPPClientError.tlsNegotiationFailed("The server sent no certificate")
                }
                guard let details = extractCertificateInfo(cert) else {
                    throw XMPPClientError.tlsNegotiationFailed("The server certificate could not be read")
                }
                let result = NIOHandshakeResult(info: TLSInfo(
                    protocolVersion: version == .tlsv13 ? "TLS 1.3" : "TLS 1.2",
                    cipherSuite: nil,
                    certificateSubject: details.subject, certificateIssuer: details.issuer,
                    certificateExpiry: details.expiry, certificateSHA256: details.sha256
                ), binding: certificateChannelBinding(cert))
                let pending = handshake
                handshake = nil
                if let pending {
                    begin(pending.continuation)
                    pending.result.succeed(result)
                }
            } catch {
                failHandshake(error)
                context.close(promise: nil)
            }
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        failHandshake(error)
        stop()
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        failHandshake(XMPPClientError.notConnected)
        stop()
        context.fireChannelInactive()
    }
}

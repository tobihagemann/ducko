import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS
import Testing
@testable import DuckoXMPP

struct NIOHandshakeDeadlineTests {
    @Test(arguments: [false, true])
    func `late TLS completion cannot take ownership of a timed out receive stream`(expiresFirst: Bool) async throws {
        try await withNIOTestGroup { group in
            let peer = try TransportTestPeer(mode: "abandonedhandshake")
            let ready = group.next().makePromise(of: NIOHandshakeResult.self)
            let completed = ready.futureResult.eventLoop.makePromise(of: Void.self)
            let (stream, continuation) = AsyncStream<[UInt8]>.makeStream()
            var configuration = TLSConfiguration.makeClientConfiguration()
            configuration.additionalTrustRoots = try [.certificates([NIOSSLCertificate(bytes: Array(peer.anchor), format: .der)])]
            let context = try NIOSSLContext(configuration: configuration)
            var opened: (any Channel)?
            do {
                let channel = try await ClientBootstrap(group: group)
                    .channelOption(ChannelOptions.autoRead, value: false)
                    .channelInitializer { channel in
                        channel.eventLoop.makeCompletedFuture {
                            let receiver = NIOReceiveHandler()
                            receiver.prepareHandshake(ready, continuation: continuation, timeout: expiresFirst ? .milliseconds(50) : .seconds(5))
                            try channel.pipeline.syncOperations.addHandler(receiver)
                            try channel.pipeline.syncOperations.addHandler(HandshakeCompletionObserver(completed: completed))
                        }
                    }.connect(host: "127.0.0.1", port: Int(peer.port)).get()
                opened = channel
                if expiresFirst {
                    let error = await #expect(throws: XMPPClientError.self) {
                        try await ready.futureResult.get(timeout: .seconds(2))
                    }
                    guard case .timeout = error else {
                        throw XMPPClientError.unexpectedStreamState("The handshake deadline did not expire")
                    }
                }
                try await channel.eventLoop.submit {
                    try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: context, serverHostname: "localhost"), position: .first)
                }.get()
                try await channel.setOption(ChannelOptions.autoRead, value: true).get()
                try await completed.futureResult.get(timeout: .seconds(3))
                if !expiresFirst { _ = try await ready.futureResult.get(timeout: .seconds(1)) }
                try? await channel.close()
                try await channel.closeFuture.get(timeout: .seconds(1))
                continuation.yield([42])
                continuation.finish()
                var iterator = stream.makeAsyncIterator()
                #expect(await iterator.next() == (expiresFirst ? [42] : nil))
                try await peer.expectSuccess()
            } catch {
                continuation.finish()
                try? await opened?.close()
                await peer.stop()
                throw error
            }
            await peer.stop()
        }
    }
}

private final class HandshakeCompletionObserver: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let completed: EventLoopPromise<Void>

    init(completed: EventLoopPromise<Void>) {
        self.completed = completed
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event { completed.succeed(()) }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        completed.fail(error)
        context.close(promise: nil)
    }
}

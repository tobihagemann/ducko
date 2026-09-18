import NIOCore
import Synchronization

/// Happy Eyeballs can initialize several channels before returning one winner.
final class NIOConnectionAttempt: Sendable {
    private struct State {
        var cancelled = false
        var channels: [any Channel] = []
    }

    private let state = Mutex(State())
    let connected: EventLoopPromise<any Channel>

    init(eventLoop: any EventLoop) {
        self.connected = eventLoop.makePromise(of: (any Channel).self)
    }

    var isCancelled: Bool {
        state.withLock { $0.cancelled }
    }

    func register(_ channel: any Channel) throws {
        let accepted = state.withLock { state in
            guard !state.cancelled else { return false }
            state.channels.append(channel)
            return true
        }
        guard accepted else {
            channel.close(promise: nil)
            throw XMPPClientError.notConnected
        }
    }

    @discardableResult
    func cancel() -> [any Channel] {
        let channels = state.withLock { state in
            state.cancelled = true
            return state.channels
        }
        connected.fail(XMPPClientError.notConnected)
        for channel in channels {
            channel.close(promise: nil)
        }
        return channels
    }
}

import NIOCore
import NIOPosix

func withNIOTestGroup(_ operation: (any EventLoopGroup) async throws -> Void) async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let outcome: Result<Void, any Error>
    do {
        try await operation(group)
        outcome = .success(())
    } catch {
        outcome = .failure(error)
    }
    try await group.shutdownGracefully()
    try outcome.get()
}

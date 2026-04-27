import Foundation
import Testing

extension DuckoIntegrationTests.CLILayer {
    struct CLIProcessTests {
        /// Pinning the failure path of `withProcessPair`: a thrown sentinel
        /// from `body` must rethrow untouched, and registered cleanups on
        /// both processes must still run. The pair's outer ordering is bob
        /// then alice (matching the helper's inlined teardown), and within
        /// each CLI cleanups run LIFO.
        @Test
        func `withProcessPair runs cleanups on both CLIs and rethrows on body failure`() async throws {
            struct Sentinel: Error, Equatable {}
            let recorder = TeardownRecorder()

            await #expect(throws: Sentinel.self) {
                try await CLIProcess.withProcessPair { aliceCLI, bobCLI in
                    await aliceCLI.addCleanup { await recorder.record("alice") }
                    await bobCLI.addCleanup { await recorder.record("bob") }
                    throw Sentinel()
                }
            }

            let order = await recorder.order
            #expect(order == ["bob", "alice"])
        }
    }
}

private actor TeardownRecorder {
    private(set) var order: [String] = []

    func record(_ tag: String) {
        order.append(tag)
    }
}

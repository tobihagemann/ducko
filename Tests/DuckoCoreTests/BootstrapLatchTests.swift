import Foundation
import Synchronization
import Testing
@testable import DuckoCore

struct BootstrapLatchTests {
    /// A `Sendable` reference so concurrent `runOnce` closures can share one counter without
    /// tripping the `sending`-closure analysis a captured local `Mutex` value would.
    private final class Counter: Sendable {
        private let value = Mutex(0)
        func increment() {
            value.withLock { $0 += 1 }
        }

        var count: Int {
            value.withLock { $0 }
        }

        var isEmpty: Bool {
            value.withLock { $0 == 0 }
        }
    }

    @Test func `first call wins, repeats skip`() {
        let latch = BootstrapLatch()
        let ran = Counter()
        #expect(latch.runOnce { ran.increment() } == .ran)
        #expect(latch.runOnce { ran.increment() } == .skipped)
        #expect(latch.runOnce { ran.increment() } == .skipped)
        #expect(ran.count == 1)
    }

    @Test func `winner runs work, losers do not`() {
        let latch = BootstrapLatch()
        let loserRan = Counter()
        #expect(latch.runOnce {} == .ran)
        #expect(latch.runOnce { loserRan.increment() } == .skipped)
        #expect(loserRan.isEmpty)
    }

    @Test func `concurrent runOnce elects exactly one winner`() async {
        let latch = BootstrapLatch()
        let invocations = Counter()
        let attempts = 1000
        let results = await withTaskGroup(of: BootstrapRunResult.self) { group in
            for _ in 0 ..< attempts {
                group.addTask {
                    latch.runOnce { invocations.increment() }
                }
            }
            var collected: [BootstrapRunResult] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }
        #expect(results.count == attempts)
        #expect(results.count(where: { $0 == .ran }) == 1)
        #expect(results.count(where: { $0 == .skipped }) == attempts - 1)
        #expect(invocations.count == 1)
    }

    @Test func `losers do not block on a still-running winner`() {
        let latch = BootstrapLatch()
        let winnerEntered = DispatchSemaphore(value: 0)
        let releaseWinner = DispatchSemaphore(value: 0)
        let winnerFinished = DispatchSemaphore(value: 0)
        let loserReturned = DispatchSemaphore(value: 0)
        let loserResult = Mutex<BootstrapRunResult?>(nil)

        DispatchQueue.global().async {
            latch.runOnce {
                winnerEntered.signal()
                releaseWinner.wait()
            }
            winnerFinished.signal()
        }

        // Park the winner inside `work()`, then attempt a loser on a separate queue: it must
        // return `.skipped` without waiting for the winner. The bounded wait turns a regression
        // (a loser that blocks on the still-running winner) into a clean failure instead of a
        // hang, since Swift Testing imposes no default per-test time limit.
        winnerEntered.wait()
        DispatchQueue.global().async {
            loserResult.withLock { $0 = latch.runOnce {} }
            loserReturned.signal()
        }
        let loserBlocked = loserReturned.wait(timeout: .now() + .seconds(5)) == .timedOut
        releaseWinner.signal()
        winnerFinished.wait()

        #expect(loserBlocked == false)
        #expect(loserResult.withLock { $0 } == .skipped)
    }
}

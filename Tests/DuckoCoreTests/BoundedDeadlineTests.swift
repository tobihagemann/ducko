import Foundation
import Testing
@testable import DuckoCore

enum BoundedDeadlineTests {
    struct RunBounded {
        @Test
        func `returns at the deadline when work outlasts it`() async {
            let clock = ContinuousClock()
            let deadline = Duration.milliseconds(200)
            let elapsed = await clock.measure {
                await runBounded(within: deadline) {
                    try? await Task.sleep(for: .seconds(10))
                }
            }
            #expect(elapsed >= deadline)
            #expect(elapsed < deadline + .seconds(1))
        }

        @Test
        func `returns as soon as work finishes, well before the deadline`() async {
            let clock = ContinuousClock()
            let elapsed = await clock.measure {
                await runBounded(within: .seconds(5)) {}
            }
            #expect(elapsed < .seconds(1))
        }
    }
}

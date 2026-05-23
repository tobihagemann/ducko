import Foundation
import Testing

extension DuckoIntegrationTests.CLILayer {
    struct OutputBufferTests {
        @Test
        func `appends below the cap leave the buffer intact`() async {
            let buffer = OutputBuffer()
            await buffer.append("hello world")
            #expect(await buffer.snapshot() == "hello world")
            #expect(await buffer.cursor() == "hello world".count)
        }

        @Test
        func `appending past the cap drops the oldest characters`() async {
            let buffer = OutputBuffer()
            // Recognisable head marker so we can prove it was dropped.
            let headMarker = "HEAD-MARKER"
            let filler = String(repeating: "x", count: OutputBuffer.maxRetained - headMarker.count)
            let overflow = "TAIL-MARKER"

            await buffer.append(headMarker + filler)
            await buffer.append(overflow)

            let snapshot = await buffer.snapshot()
            #expect(snapshot.count == OutputBuffer.maxRetained)
            #expect(snapshot.hasSuffix(overflow))
            #expect(!snapshot.contains(headMarker))
        }

        @Test
        func `cursor stays monotonic across a trim`() async {
            let buffer = OutputBuffer()
            await buffer.append("first ")
            let earlyCursor = await buffer.cursor()
            #expect(earlyCursor == "first ".count)

            // Push past the cap so the prefix containing the early cursor
            // gets trimmed.
            await buffer.append(String(repeating: "x", count: OutputBuffer.maxRetained))
            let lateCursor = await buffer.cursor()
            #expect(lateCursor > earlyCursor)
            #expect(lateCursor == "first ".count + OutputBuffer.maxRetained)
        }

        @Test
        func `snapshotIfContainsAny after cursor finds substrings written after the cursor`() async {
            let buffer = OutputBuffer()
            await buffer.append("prelude ")
            let cursor = await buffer.cursor()
            await buffer.append("MARKER tail")

            let match = await buffer.snapshotIfContainsAny(["MARKER"], after: cursor)
            #expect(match?.contains("MARKER") == true)

            // A substring that only appears before the cursor is not a match.
            let missingMatch = await buffer.snapshotIfContainsAny(["prelude"], after: cursor)
            #expect(missingMatch == nil)
        }

        @Test
        func `snapshotIfContainsAny after a stale cursor clamps to the retained tail`() async {
            let buffer = OutputBuffer()
            await buffer.append("OLD-PREFIX ")
            let staleCursor = await buffer.cursor()

            // Overflow the buffer so the "OLD-PREFIX " region is dropped and
            // `staleCursor` now points before the start of retained content.
            await buffer.append(String(repeating: "y", count: OutputBuffer.maxRetained))
            await buffer.append("LATE-MARKER")

            // Clamping must keep the substring scan over the entire retained
            // tail (no crash, no negative offset).
            let match = await buffer.snapshotIfContainsAny(["LATE-MARKER"], after: staleCursor)
            #expect(match?.contains("LATE-MARKER") == true)
        }
    }
}

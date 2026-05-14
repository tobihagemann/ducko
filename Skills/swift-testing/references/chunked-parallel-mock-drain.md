# Draining Mock Outboxes for Chunked Parallel Fan-Out

When the code under test fans out parallel work in **chunks** — e.g. `stride(from:to:by:chunkSize)` + per-chunk `withTaskGroup` — the obvious "wait for N stanzas then respond" pattern deadlocks. Chunk K+1 doesn't send its stanzas until chunk K's tasks complete, and those tasks complete only after the mock delivers responses. Waiting for all N upfront blocks both sides.

## The Deadlock

```swift
// Code under test: encrypt-cap chunks 100 recipients into windows of 64
let recipientIDs: [UInt32] = (1 ... 100).map(UInt32.init)
let task = Task {
    try await module.encryptMessage(recipientDeviceIDs: recipientIDs)
}

// Test drains all-at-once → deadlocks:
await mock.waitForSent(count: recipientIDs.count) // ← blocks forever
let sent = await mock.sentBytes
for bytes in sent { await mock.simulateReceive(...) }
```

`waitForSent(count: 100)` never returns because only the first 64 stanzas are sent before the chunk's `withTaskGroup` waits for responses. The 36 stanzas in chunk 2 never queue.

## The Fix — Drain One Stanza at a Time

```swift
var drained = 0
while drained < recipientIDs.count {
    await mock.waitForSent(count: drained + 1)
    let bytes = await mock.sentBytes[drained]
    let iqID = try #require(extractIQID(from: bytes))
    let deviceID = try #require(extractBundleDeviceID(from: bytes))
    await mock.simulateReceive(makeResponseIQ(iqID: iqID, deviceID: deviceID))
    drained += 1
}
```

Each iteration unblocks one chunk-internal task. When the last task in a chunk completes, the next chunk fires its stanzas. The mock keeps making forward progress.

## Why Not Sleep / Yield?

`Task.yield()` and `try await Task.sleep(...)` look tempting but rely on scheduler behavior that varies across platforms and Swift versions. The drain-one-at-a-time loop is **structural**: it directly models the data dependency the chunk boundary introduces. It works regardless of the scheduler.

## Why Not `waitForSent(count: chunkSize)` Then Move On?

Tempting because the loop body becomes `for chunkStart in stride(from:0,to:N,by:chunkSize) { … }`, but it duplicates the system-under-test's chunk size in the test. If the production code changes the cap from 64 to 32, every test that hardcodes `64` breaks for the wrong reason. The one-at-a-time drain is cap-agnostic.

## Coverage Checklist for Chunked Fan-Out

- Recipient count > chunk size (forces at least one chunk boundary in the test)
- Recipient count = chunk size (boundary case)
- Recipient count = chunk size + 1 (smallest "needs second chunk" case)
- All recipients return error / drop (encrypt should still complete with an empty result, exercising every chunk)
- One recipient delays its response while others arrive (verifies the chunk's `withTaskGroup` actually waits for the slow task before starting the next chunk)

## Reference

See `Tests/DuckoXMPPTests/OMEMOModuleTests.swift` — the `Encrypt fan-out across many devices completes every recipient` test exercises the drain-one-at-a-time pattern against the OMEMO encrypt path's `encryptConcurrencyCap = 64` chunking.

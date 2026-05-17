import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let accountA = UUID()
private let accountB = UUID()
private let roomR1 = BareJID(localPart: "r1", domainPart: "conference.example.com")!
private let roomR2 = BareJID(localPart: "r2", domainPart: "conference.example.com")!

private func makeStore() -> MockPersistenceStore {
    MockPersistenceStore()
}

private func makeTranscripts() -> MockTranscriptStore {
    MockTranscriptStore()
}

@MainActor
private func makeChatService(store: MockPersistenceStore, transcripts: MockTranscriptStore) -> ChatService {
    ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
}

private func makeOccupancy(nickname: String = "me") -> RoomOccupancy {
    RoomOccupancy(
        nickname: nickname,
        occupants: [RoomOccupant(nickname: nickname, affiliation: .member, role: .participant)],
        subject: nil
    )
}

// MARK: - Tests

enum ChatServiceAwaitRoomJoinedTests {
    struct AwaitRoomJoined {
        @Test
        @MainActor
        func `Yielded join echo resolves the waiter`() async {
            let service = makeChatService(store: makeStore(), transcripts: makeTranscripts())
            let (id, stream) = service.registerRoomJoinNotifier(jid: roomR1, accountID: accountA)

            await service.handleEvent(
                .roomJoined(room: roomR1, occupancy: makeOccupancy(), isNewlyCreated: false),
                accountID: accountA
            )
            let yielded = await service.awaitRoomJoinedEcho(stream: stream, timeout: .seconds(1))
            service.clearRoomJoinNotifier(jid: roomR1, accountID: accountA, id: id)

            #expect(yielded)
            #expect(service.roomJoinNotifiers.isEmpty)
        }

        @Test
        @MainActor
        func `Wait without a matching event reports timeout`() async {
            let service = makeChatService(store: makeStore(), transcripts: makeTranscripts())
            let (id, stream) = service.registerRoomJoinNotifier(jid: roomR1, accountID: accountA)

            let yielded = await service.awaitRoomJoinedEcho(stream: stream, timeout: .milliseconds(100))
            service.clearRoomJoinNotifier(jid: roomR1, accountID: accountA, id: id)

            #expect(!yielded)
            #expect(service.roomJoinNotifiers.isEmpty)
        }

        @Test
        @MainActor
        func `Different room with same account does not resolve the waiter`() async {
            let service = makeChatService(store: makeStore(), transcripts: makeTranscripts())
            let (id, stream) = service.registerRoomJoinNotifier(jid: roomR1, accountID: accountA)

            await service.handleEvent(
                .roomJoined(room: roomR2, occupancy: makeOccupancy(), isNewlyCreated: false),
                accountID: accountA
            )
            let yielded = await service.awaitRoomJoinedEcho(stream: stream, timeout: .milliseconds(100))
            service.clearRoomJoinNotifier(jid: roomR1, accountID: accountA, id: id)

            #expect(!yielded)
            #expect(service.roomJoinNotifiers.isEmpty)
        }

        @Test
        @MainActor
        func `Same room with different account does not resolve the waiter`() async {
            let service = makeChatService(store: makeStore(), transcripts: makeTranscripts())
            let (id, stream) = service.registerRoomJoinNotifier(jid: roomR1, accountID: accountA)

            await service.handleEvent(
                .roomJoined(room: roomR1, occupancy: makeOccupancy(), isNewlyCreated: false),
                accountID: accountB
            )
            let yielded = await service.awaitRoomJoinedEcho(stream: stream, timeout: .milliseconds(100))
            service.clearRoomJoinNotifier(jid: roomR1, accountID: accountA, id: id)

            #expect(!yielded)
            #expect(service.roomJoinNotifiers.isEmpty)
        }

        @Test
        @MainActor
        func `Re-registration replaces the prior notifier and routes the next echo to the new one`() async {
            let service = makeChatService(store: makeStore(), transcripts: makeTranscripts())
            let (id1, stream1) = service.registerRoomJoinNotifier(jid: roomR1, accountID: accountA)
            let (id2, stream2) = service.registerRoomJoinNotifier(jid: roomR1, accountID: accountA)

            // First waiter must observe natural completion (no yield).
            let yielded1 = await service.awaitRoomJoinedEcho(stream: stream1, timeout: .milliseconds(100))
            #expect(!yielded1)

            // Echo arrives — only the second waiter wins.
            await service.handleEvent(
                .roomJoined(room: roomR1, occupancy: makeOccupancy(), isNewlyCreated: false),
                accountID: accountA
            )
            let yielded2 = await service.awaitRoomJoinedEcho(stream: stream2, timeout: .seconds(1))
            #expect(yielded2)

            // Stale cleanup from the first waiter MUST NOT drop the slot the
            // second waiter already vacated via the echo.
            service.clearRoomJoinNotifier(jid: roomR1, accountID: accountA, id: id1)
            service.clearRoomJoinNotifier(jid: roomR1, accountID: accountA, id: id2)
            #expect(service.roomJoinNotifiers.isEmpty)
        }

        @Test
        @MainActor
        func `Stale cleanup does not drop a newer registration's slot`() async {
            let service = makeChatService(store: makeStore(), transcripts: makeTranscripts())
            let (id1, _) = service.registerRoomJoinNotifier(jid: roomR1, accountID: accountA)
            let (id2, stream2) = service.registerRoomJoinNotifier(jid: roomR1, accountID: accountA)

            // The first waiter's stale cleanup runs AFTER the second has taken
            // over the slot. With identity-aware cleanup it's a no-op; the
            // second waiter must still receive the echo.
            service.clearRoomJoinNotifier(jid: roomR1, accountID: accountA, id: id1)
            #expect(service.roomJoinNotifiers[RoomJoinKey(accountID: accountA, room: roomR1)]?.id == id2)

            await service.handleEvent(
                .roomJoined(room: roomR1, occupancy: makeOccupancy(), isNewlyCreated: false),
                accountID: accountA
            )
            let yielded = await service.awaitRoomJoinedEcho(stream: stream2, timeout: .seconds(1))
            #expect(yielded)
            #expect(service.roomJoinNotifiers.isEmpty)
        }

        @Test
        @MainActor
        func `clearRoomJoinNotifier is idempotent`() {
            let service = makeChatService(store: makeStore(), transcripts: makeTranscripts())
            let (id, _) = service.registerRoomJoinNotifier(jid: roomR1, accountID: accountA)
            service.clearRoomJoinNotifier(jid: roomR1, accountID: accountA, id: id)
            service.clearRoomJoinNotifier(jid: roomR1, accountID: accountA, id: id)
            service.clearRoomJoinNotifier(jid: roomR2, accountID: accountA, id: UUID())
            #expect(service.roomJoinNotifiers.isEmpty)
        }
    }

    /// Coverage for the public wrapper's error-cleanup contract: when the
    /// underlying `joinRoom` throws, the notifier must be cleaned up before
    /// the error is rethrown so the registry doesn't leak entries on every
    /// failed join attempt.
    struct PublicErrorPath {
        @Test
        @MainActor
        func `joinRoomAwaitingEcho cleans up notifier when joinRoom throws`() async throws {
            let service = makeChatService(store: makeStore(), transcripts: makeTranscripts())
            // No `accountService` wired — `joinRoom` throws `.notConnected`
            // immediately, before any notifier-yield path can fire.
            await #expect(throws: ChatService.ChatServiceError.self) {
                try await service.joinRoomAwaitingEcho(
                    jid: roomR1, nickname: "me", accountID: accountA, timeout: .milliseconds(100)
                )
            }
            #expect(service.roomJoinNotifiers.isEmpty)
        }

        @Test
        @MainActor
        func `joinRoomAwaitingEcho jidString overload throws invalidJID on parse failure`() async {
            let service = makeChatService(store: makeStore(), transcripts: makeTranscripts())
            await #expect(throws: ChatService.ChatServiceError.self) {
                try await service.joinRoomAwaitingEcho(
                    jidString: "@@bogus", nickname: "me", accountID: accountA
                )
            }
            #expect(service.roomJoinNotifiers.isEmpty)
        }
    }
}

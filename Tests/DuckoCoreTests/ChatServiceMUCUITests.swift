import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

// MARK: - Helpers

private let testAccountID = UUID()
private let testAccountJID = BareJID(localPart: "user", domainPart: "example.com")!
private let testRoomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!

private func makeStore() -> MockPersistenceStore {
    MockPersistenceStore()
}

@MainActor
private func makeChatService(store: MockPersistenceStore) -> ChatService {
    ChatService(store: store, filterPipeline: MessageFilterPipeline())
}

// MARK: - Tests

enum ChatServiceMUCUITests {
    struct RoomParticipantsSeeding {
        @Test("roomJoined seeds roomParticipants")
        @MainActor
        func seedsParticipants() async {
            let store = makeStore()
            let service = makeChatService(store: store)

            let occupancy = RoomOccupancy(
                room: testRoomJID,
                nickname: "me",
                occupants: [
                    RoomOccupant(nickname: "me", affiliation: .member, role: .participant),
                    RoomOccupant(nickname: "admin", affiliation: .admin, role: .moderator)
                ],
                subject: nil
            )
            await service.handleEvent(.roomJoined(room: testRoomJID, occupancy: occupancy), accountID: testAccountID)

            let participants = service.roomParticipants[testRoomJID.description]
            #expect(participants?.count == 2)
            #expect(participants?.contains { $0.nickname == "me" } == true)
            #expect(participants?.contains { $0.nickname == "admin" } == true)
        }
    }

    struct OccupantJoined {
        @Test("roomOccupantJoined adds to roomParticipants")
        @MainActor
        func addsParticipant() async {
            let store = makeStore()
            let service = makeChatService(store: store)

            // Seed with initial occupancy
            let occupancy = RoomOccupancy(
                room: testRoomJID,
                nickname: "me",
                occupants: [RoomOccupant(nickname: "me", affiliation: .member, role: .participant)],
                subject: nil
            )
            await service.handleEvent(.roomJoined(room: testRoomJID, occupancy: occupancy), accountID: testAccountID)

            // New occupant joins
            let newOccupant = RoomOccupant(nickname: "newcomer", affiliation: .none, role: .participant)
            await service.handleEvent(.roomOccupantJoined(room: testRoomJID, occupant: newOccupant), accountID: testAccountID)

            let participants = service.roomParticipants[testRoomJID.description]
            #expect(participants?.count == 2)
            #expect(participants?.contains { $0.nickname == "newcomer" } == true)

            // Verify mapped affiliation and role
            let newcomer = participants?.first { $0.nickname == "newcomer" }
            #expect(newcomer?.affiliation == RoomAffiliation.none)
            #expect(newcomer?.role == RoomRole.participant)
        }
    }

    struct OccupantLeft {
        @Test("roomOccupantLeft removes from roomParticipants")
        @MainActor
        func removesParticipant() async {
            let store = makeStore()
            let service = makeChatService(store: store)

            // Seed with two occupants
            let occupancy = RoomOccupancy(
                room: testRoomJID,
                nickname: "me",
                occupants: [
                    RoomOccupant(nickname: "me", affiliation: .member, role: .participant),
                    RoomOccupant(nickname: "other", affiliation: .member, role: .participant)
                ],
                subject: nil
            )
            await service.handleEvent(.roomJoined(room: testRoomJID, occupancy: occupancy), accountID: testAccountID)

            // Other leaves
            let leftOccupant = RoomOccupant(nickname: "other", affiliation: .member, role: .participant)
            await service.handleEvent(.roomOccupantLeft(room: testRoomJID, occupant: leftOccupant), accountID: testAccountID)

            let participants = service.roomParticipants[testRoomJID.description]
            #expect(participants?.count == 1)
            #expect(participants?.contains { $0.nickname == "other" } == false)
        }
    }

    struct ParticipantGrouping {
        @Test("participantGroups groups and sorts by affiliation")
        @MainActor
        func groupsAndSorts() async {
            let store = makeStore()
            let service = makeChatService(store: store)

            let occupancy = RoomOccupancy(
                room: testRoomJID,
                nickname: "me",
                occupants: [
                    RoomOccupant(nickname: "user1", affiliation: .none, role: .participant),
                    RoomOccupant(nickname: "owner1", affiliation: .owner, role: .moderator),
                    RoomOccupant(nickname: "admin1", affiliation: .admin, role: .moderator),
                    RoomOccupant(nickname: "member1", affiliation: .member, role: .participant)
                ],
                subject: nil
            )
            await service.handleEvent(.roomJoined(room: testRoomJID, occupancy: occupancy), accountID: testAccountID)

            let groups = service.participantGroups(forRoomJIDString: testRoomJID.description)
            #expect(groups.count == 4)
            #expect(groups[0].affiliation == .owner)
            #expect(groups[1].affiliation == .admin)
            #expect(groups[2].affiliation == .member)
            #expect(groups[3].affiliation == .none)
        }
    }

    struct InviteReceived {
        @Test("roomInviteReceived appends to pendingInvites")
        @MainActor
        func appendsInvite() async {
            let store = makeStore()
            let service = makeChatService(store: store)

            let invite = RoomInvite(
                room: testRoomJID,
                from: .bare(testAccountJID),
                reason: "Join us!",
                password: nil
            )
            await service.handleEvent(.roomInviteReceived(invite), accountID: testAccountID)

            #expect(service.pendingInvites.count == 1)
            #expect(service.pendingInvites[0].roomJIDString == testRoomJID.description)
            #expect(service.pendingInvites[0].reason == "Join us!")
        }

        @Test("Duplicate invites are deduplicated")
        @MainActor
        func deduplicatesInvites() async {
            let store = makeStore()
            let service = makeChatService(store: store)

            let invite = RoomInvite(room: testRoomJID, from: .bare(testAccountJID))
            await service.handleEvent(.roomInviteReceived(invite), accountID: testAccountID)
            await service.handleEvent(.roomInviteReceived(invite), accountID: testAccountID)

            #expect(service.pendingInvites.count == 1)
        }
    }

    struct DeclineInvite {
        @Test("declineInvite removes from pendingInvites")
        @MainActor
        func removesInvite() async {
            let store = makeStore()
            let service = makeChatService(store: store)

            let invite = RoomInvite(room: testRoomJID, from: .bare(testAccountJID))
            await service.handleEvent(.roomInviteReceived(invite), accountID: testAccountID)
            #expect(service.pendingInvites.count == 1)

            service.declineInvite(service.pendingInvites[0])
            #expect(service.pendingInvites.isEmpty)
        }
    }

    struct MapOccupantValues {
        @Test("mapOccupant correctly maps all affiliation/role values")
        @MainActor
        func mapsAllValues() async {
            let store = makeStore()
            let service = makeChatService(store: store)

            let occupants = [
                RoomOccupant(nickname: "o", jid: testAccountJID, affiliation: .owner, role: .moderator),
                RoomOccupant(nickname: "a", affiliation: .admin, role: .participant),
                RoomOccupant(nickname: "m", affiliation: .member, role: .visitor),
                RoomOccupant(nickname: "x", affiliation: .outcast, role: .none),
                RoomOccupant(nickname: "n", affiliation: .none, role: .none)
            ]
            let occupancy = RoomOccupancy(room: testRoomJID, nickname: "o", occupants: occupants, subject: nil)
            await service.handleEvent(.roomJoined(room: testRoomJID, occupancy: occupancy), accountID: testAccountID)

            let participants = service.roomParticipants[testRoomJID.description] ?? []

            let owner = participants.first { $0.nickname == "o" }
            #expect(owner?.affiliation == .owner)
            #expect(owner?.role == .moderator)
            #expect(owner?.jidString == testAccountJID.description)

            let admin = participants.first { $0.nickname == "a" }
            #expect(admin?.affiliation == .admin)
            #expect(admin?.role == .participant)

            let member = participants.first { $0.nickname == "m" }
            #expect(member?.affiliation == .member)
            #expect(member?.role == .visitor)

            let outcast = participants.first { $0.nickname == "x" }
            #expect(outcast?.affiliation == RoomAffiliation.outcast)
            #expect(outcast?.role == RoomRole.none)

            let noneParticipant = participants.first { $0.nickname == "n" }
            #expect(noneParticipant?.affiliation == RoomAffiliation.none)
            #expect(noneParticipant?.role == RoomRole.none)
        }
    }
}

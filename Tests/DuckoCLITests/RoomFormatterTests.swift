import DuckoCore
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCLI

// MARK: - PlainFormatter Room Tests

struct PlainRoomFormatterTests {
    let formatter = PlainFormatter()

    // MARK: - formatRoom

    @Test func formatRoomWithName() {
        let room = DiscoveredRoom(jidString: "chat@conference.example.com", name: "Chat Room")
        let output = formatter.formatRoom(room)
        #expect(output.contains("Chat Room"))
        #expect(output.contains("chat@conference.example.com"))
    }

    @Test func formatRoomWithoutName() {
        let room = DiscoveredRoom(jidString: "chat@conference.example.com", name: nil)
        let output = formatter.formatRoom(room)
        #expect(output == "chat@conference.example.com")
    }

    // MARK: - formatRoomParticipant

    @Test func formatRoomParticipantWithJID() {
        let participant = RoomParticipant(nickname: "alice", jidString: "alice@example.com", affiliation: .member, role: .participant)
        let output = formatter.formatRoomParticipant(participant)
        #expect(output.contains("alice"))
        #expect(output.contains("alice@example.com"))
        #expect(output.contains("[participant]"))
    }

    @Test func formatRoomParticipantWithoutJID() {
        let participant = RoomParticipant(nickname: "bob", affiliation: .none, role: .visitor)
        let output = formatter.formatRoomParticipant(participant)
        #expect(output.contains("bob"))
        #expect(output.contains("[visitor]"))
        #expect(!output.contains("@"))
    }

    // MARK: - formatRoomParticipantGroupHeader

    @Test func formatRoomParticipantGroupHeader() {
        let group = RoomParticipantGroup(affiliation: .owner, participants: [
            RoomParticipant(nickname: "admin", affiliation: .owner, role: .moderator)
        ])
        let output = formatter.formatRoomParticipantGroupHeader(group)
        #expect(output.contains("Owner"))
        #expect(output.contains("1"))
    }

    // MARK: - formatRoomJoinedConfirmation

    @Test func formatRoomJoinedConfirmationWithSubject() {
        let output = formatter.formatRoomJoinedConfirmation(room: "chat@conference.example.com", nickname: "alice", participantCount: 5, subject: "Welcome!")
        #expect(output.contains("Joined"))
        #expect(output.contains("chat@conference.example.com"))
        #expect(output.contains("alice"))
        #expect(output.contains("5 participants"))
        #expect(output.contains("Welcome!"))
    }

    @Test func formatRoomJoinedConfirmationWithoutSubject() {
        let output = formatter.formatRoomJoinedConfirmation(room: "chat@conference.example.com", nickname: "alice", participantCount: 3, subject: nil)
        #expect(output.contains("Joined"))
        #expect(output.contains("3 participants"))
        #expect(!output.contains("Topic"))
    }

    // MARK: - MUC Events

    @Test func formatEventRoomJoined() throws {
        let room = try #require(BareJID.parse("chat@conference.example.com"))
        let occupancy = RoomOccupancy(room: room, nickname: "alice", occupants: [
            RoomOccupant(nickname: "alice", affiliation: .member, role: .participant),
            RoomOccupant(nickname: "bob", affiliation: .member, role: .participant)
        ], subject: "Hello")
        let output = try #require(formatter.formatEvent(.roomJoined(room: room, occupancy: occupancy), accountID: UUID()))
        #expect(output.contains("Joined"))
        #expect(output.contains("alice"))
        #expect(output.contains("2 participants"))
        #expect(output.contains("Hello"))
    }

    @Test func formatEventRoomOccupantJoined() throws {
        let room = try #require(BareJID.parse("chat@conference.example.com"))
        let occupant = RoomOccupant(nickname: "charlie", affiliation: .member, role: .participant)
        let output = try #require(formatter.formatEvent(.roomOccupantJoined(room: room, occupant: occupant), accountID: UUID()))
        #expect(output.contains("charlie"))
        #expect(output.contains("joined"))
    }

    @Test func formatEventRoomOccupantLeft() throws {
        let room = try #require(BareJID.parse("chat@conference.example.com"))
        let occupant = RoomOccupant(nickname: "charlie", affiliation: .member, role: .participant)
        let output = try #require(formatter.formatEvent(.roomOccupantLeft(room: room, occupant: occupant), accountID: UUID()))
        #expect(output.contains("charlie"))
        #expect(output.contains("left"))
    }

    @Test func formatEventRoomSubjectChanged() throws {
        let room = try #require(BareJID.parse("chat@conference.example.com"))
        let setter = JID.parse("alice@example.com")
        let output = try #require(formatter.formatEvent(.roomSubjectChanged(room: room, subject: "New topic", setter: setter), accountID: UUID()))
        #expect(output.contains("topic changed"))
        #expect(output.contains("New topic"))
        #expect(output.contains("alice@example.com"))
    }

    @Test func formatEventRoomInviteReceived() throws {
        let room = try #require(BareJID.parse("chat@conference.example.com"))
        let from = try #require(JID.parse("bob@example.com"))
        let invite = RoomInvite(room: room, from: from, reason: "Come join us!")
        let output = try #require(formatter.formatEvent(.roomInviteReceived(invite), accountID: UUID()))
        #expect(output.contains("Room invite"))
        #expect(output.contains("bob@example.com"))
        #expect(output.contains("chat@conference.example.com"))
        #expect(output.contains("Come join us!"))
    }

    @Test func formatEventRoomMessageReceived() throws {
        var message = XMPPMessage(type: .groupchat)
        message.from = JID.parse("chat@conference.example.com/alice")
        message.body = "Hello everyone!"
        let output = try #require(formatter.formatEvent(.roomMessageReceived(message), accountID: UUID()))
        #expect(output.contains("<-"))
        #expect(output.contains("alice"))
        #expect(output.contains("Hello everyone!"))
    }
}

// MARK: - ANSIFormatter Room Tests

struct ANSIRoomFormatterTests {
    let formatter = ANSIFormatter()

    @Test func formatRoomWithNameUsesBold() {
        let room = DiscoveredRoom(jidString: "chat@conference.example.com", name: "Chat Room")
        let output = formatter.formatRoom(room)
        #expect(output.contains("\u{001B}[1m")) // bold
        #expect(output.contains("Chat Room"))
    }

    @Test func formatRoomParticipantUsesGreen() {
        let participant = RoomParticipant(nickname: "alice", jidString: "alice@example.com", affiliation: .member, role: .participant)
        let output = formatter.formatRoomParticipant(participant)
        #expect(output.contains("\u{001B}[32m")) // green
        #expect(output.contains("alice"))
    }

    @Test func formatRoomParticipantGroupHeaderUsesBold() {
        let group = RoomParticipantGroup(affiliation: .admin, participants: [
            RoomParticipant(nickname: "mod", affiliation: .admin, role: .moderator)
        ])
        let output = formatter.formatRoomParticipantGroupHeader(group)
        #expect(output.contains("\u{001B}[1m")) // bold
        #expect(output.contains("Admin"))
    }

    @Test func formatEventRoomOccupantJoinedUsesYellow() throws {
        let room = try #require(BareJID.parse("chat@conference.example.com"))
        let occupant = RoomOccupant(nickname: "charlie", affiliation: .member, role: .participant)
        let output = try #require(formatter.formatEvent(.roomOccupantJoined(room: room, occupant: occupant), accountID: UUID()))
        #expect(output.contains("\u{001B}[33m")) // yellow
    }

    @Test func formatEventRoomInviteUsesYellowWithBoldRoom() throws {
        let room = try #require(BareJID.parse("chat@conference.example.com"))
        let from = try #require(JID.parse("bob@example.com"))
        let invite = RoomInvite(room: room, from: from)
        let output = try #require(formatter.formatEvent(.roomInviteReceived(invite), accountID: UUID()))
        #expect(output.contains("\u{001B}[33m")) // yellow
        #expect(output.contains("\u{001B}[1m")) // bold
    }

    @Test func formatEventRoomMessageUsesGreen() throws {
        var message = XMPPMessage(type: .groupchat)
        message.from = JID.parse("chat@conference.example.com/alice")
        message.body = "Hi"
        let output = try #require(formatter.formatEvent(.roomMessageReceived(message), accountID: UUID()))
        #expect(output.contains("\u{001B}[32m")) // green
    }
}

// MARK: - JSONFormatter Room Tests

struct JSONRoomFormatterTests {
    let formatter = JSONFormatter()

    // MARK: - formatRoom

    @Test func formatRoomIsValidJSON() throws {
        let room = DiscoveredRoom(jidString: "chat@conference.example.com", name: "Chat Room")
        let output = formatter.formatRoom(room)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "room")
        #expect(json["jid"] == "chat@conference.example.com")
        #expect(json["name"] == "Chat Room")
    }

    @Test func formatRoomWithoutNameOmitsName() throws {
        let room = DiscoveredRoom(jidString: "chat@conference.example.com", name: nil)
        let output = formatter.formatRoom(room)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "room")
        #expect(json["name"] == nil)
    }

    // MARK: - formatRoomParticipant

    @Test func formatRoomParticipantIsValidJSON() throws {
        let participant = RoomParticipant(nickname: "alice", jidString: "alice@example.com", affiliation: .member, role: .participant)
        let output = formatter.formatRoomParticipant(participant)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "room_participant")
        #expect(json["nickname"] == "alice")
        #expect(json["jid"] == "alice@example.com")
        #expect(json["role"] == "participant")
        #expect(json["affiliation"] == "member")
    }

    // MARK: - formatRoomParticipantGroupHeader

    @Test func formatRoomParticipantGroupHeaderIsValidJSON() throws {
        let group = RoomParticipantGroup(affiliation: .owner, participants: [
            RoomParticipant(nickname: "admin", affiliation: .owner, role: .moderator),
            RoomParticipant(nickname: "admin2", affiliation: .owner, role: .moderator)
        ])
        let output = formatter.formatRoomParticipantGroupHeader(group)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "room_participant_group")
        #expect(json["affiliation"] == "Owner")
        #expect(json["count"] == "2")
    }

    // MARK: - formatRoomJoinedConfirmation

    @Test func formatRoomJoinedConfirmationIsValidJSON() throws {
        let output = formatter.formatRoomJoinedConfirmation(room: "chat@conference.example.com", nickname: "alice", participantCount: 5, subject: "Hello")
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "room_joined")
        #expect(json["room"] == "chat@conference.example.com")
        #expect(json["nickname"] == "alice")
        #expect(json["participants"] == "5")
        #expect(json["subject"] == "Hello")
    }

    // MARK: - MUC Events

    @Test func formatEventRoomJoinedIsValidJSON() throws {
        let room = try #require(BareJID.parse("chat@conference.example.com"))
        let occupancy = RoomOccupancy(room: room, nickname: "alice", occupants: [
            RoomOccupant(nickname: "alice", affiliation: .member, role: .participant)
        ], subject: "Topic")
        let output = try #require(formatter.formatEvent(.roomJoined(room: room, occupancy: occupancy), accountID: UUID()))
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "room_joined")
        #expect(json["room"] == "chat@conference.example.com")
        #expect(json["nickname"] == "alice")
        #expect(json["subject"] == "Topic")
    }

    @Test func formatEventRoomOccupantJoinedIsValidJSON() throws {
        let room = try #require(BareJID.parse("chat@conference.example.com"))
        let occupant = RoomOccupant(nickname: "charlie", affiliation: .member, role: .participant)
        let output = try #require(formatter.formatEvent(.roomOccupantJoined(room: room, occupant: occupant), accountID: UUID()))
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "room_occupant_joined")
        #expect(json["nickname"] == "charlie")
    }

    @Test func formatEventRoomOccupantLeftIsValidJSON() throws {
        let room = try #require(BareJID.parse("chat@conference.example.com"))
        let occupant = RoomOccupant(nickname: "charlie", affiliation: .member, role: .participant)
        let output = try #require(formatter.formatEvent(.roomOccupantLeft(room: room, occupant: occupant), accountID: UUID()))
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "room_occupant_left")
        #expect(json["nickname"] == "charlie")
    }

    @Test func formatEventRoomSubjectChangedIsValidJSON() throws {
        let room = try #require(BareJID.parse("chat@conference.example.com"))
        let setter = JID.parse("alice@example.com")
        let output = try #require(formatter.formatEvent(.roomSubjectChanged(room: room, subject: "New topic", setter: setter), accountID: UUID()))
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "room_subject_changed")
        #expect(json["subject"] == "New topic")
        #expect(json["setter"] == "alice@example.com")
    }

    @Test func formatEventRoomInviteIsValidJSON() throws {
        let room = try #require(BareJID.parse("chat@conference.example.com"))
        let from = try #require(JID.parse("bob@example.com"))
        let invite = RoomInvite(room: room, from: from, reason: "Join us")
        let output = try #require(formatter.formatEvent(.roomInviteReceived(invite), accountID: UUID()))
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "room_invite")
        #expect(json["room"] == "chat@conference.example.com")
        #expect(json["from"] == "bob@example.com")
        #expect(json["reason"] == "Join us")
    }

    @Test func formatEventRoomMessageIsValidJSON() throws {
        var message = XMPPMessage(type: .groupchat)
        message.from = JID.parse("chat@conference.example.com/alice")
        message.body = "Hello everyone!"
        let output = try #require(formatter.formatEvent(.roomMessageReceived(message), accountID: UUID()))
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "room_message")
        #expect(json["direction"] == "incoming")
        #expect(json["room"] == "chat@conference.example.com")
        #expect(json["nickname"] == "alice")
        #expect(json["body"] == "Hello everyone!")
    }
}

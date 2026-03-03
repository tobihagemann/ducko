import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func makeConnectedClient(mock: MockTransport) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock
    )
    await client.register(MUCModule())

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return client
}

private let testRoomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!

// MARK: - Tests

enum MUCModuleTests {
    struct JoinFlow {
        @Test
        func `Self-presence with status 110 emits roomJoined`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .roomJoined = event { return true }
                    return false
                }
            }

            // Other occupant arrives first
            await mock.simulateReceive("""
            <presence from='room@conference.example.com/other'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant'/>\
            </x>\
            </presence>
            """)

            // Self-presence with status 110
            await mock.simulateReceive("""
            <presence from='room@conference.example.com/me'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant'/>\
            <status code='110'/>\
            </x>\
            </presence>
            """)

            let events = try await eventsTask.value
            guard case let .roomJoined(room, occupancy) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected roomJoined event")
            }
            #expect(room == testRoomJID)
            #expect(occupancy.nickname == "me")
            #expect(occupancy.occupants.count == 2)

            await client.disconnect()
        }
    }

    struct OccupantJoin {
        @Test
        func `Available presence emits roomOccupantJoined`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .roomOccupantJoined = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <presence from='room@conference.example.com/newcomer'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='none' role='participant'/>\
            </x>\
            </presence>
            """)

            let events = try await eventsTask.value
            guard case let .roomOccupantJoined(room, occupant) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected roomOccupantJoined event")
            }
            #expect(room == testRoomJID)
            #expect(occupant.nickname == "newcomer")
            #expect(occupant.role == .participant)

            await client.disconnect()
        }
    }

    struct OccupantLeave {
        @Test
        func `Unavailable presence emits roomOccupantLeft`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            // First make occupant join
            await mock.simulateReceive("""
            <presence from='room@conference.example.com/leaver'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='none' role='participant'/>\
            </x>\
            </presence>
            """)
            try? await Task.sleep(for: .milliseconds(100))

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .roomOccupantLeft = event { return true }
                    return false
                }
            }

            // Occupant leaves
            await mock.simulateReceive("""
            <presence type='unavailable' from='room@conference.example.com/leaver'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='none' role='none'/>\
            </x>\
            </presence>
            """)

            let events = try await eventsTask.value
            guard case let .roomOccupantLeft(room, occupant) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected roomOccupantLeft event")
            }
            #expect(room == testRoomJID)
            #expect(occupant.nickname == "leaver")

            await client.disconnect()
        }
    }

    struct GroupMessage {
        @Test
        func `Groupchat message emits roomMessageReceived`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .roomMessageReceived = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message type='groupchat' from='room@conference.example.com/other'>\
            <body>Hello group!</body>\
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .roomMessageReceived(message) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected roomMessageReceived event")
            }
            #expect(message.body == "Hello group!")
            #expect(message.from?.bareJID == testRoomJID)

            await client.disconnect()
        }
    }

    struct SubjectChange {
        @Test
        func `Subject message emits roomSubjectChanged`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .roomSubjectChanged = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message type='groupchat' from='room@conference.example.com/admin'>\
            <subject>New topic</subject>\
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .roomSubjectChanged(room, subject, _) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected roomSubjectChanged event")
            }
            #expect(room == testRoomJID)
            #expect(subject == "New topic")

            await client.disconnect()
        }
    }

    struct MediatedInvite {
        @Test
        func `Mediated invite emits roomInviteReceived`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .roomInviteReceived = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message from='room@conference.example.com'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <invite from='admin@example.com'>\
            <reason>Join us!</reason>\
            </invite>\
            </x>\
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .roomInviteReceived(invite) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected roomInviteReceived event")
            }
            #expect(invite.room == testRoomJID)
            #expect(invite.reason == "Join us!")

            await client.disconnect()
        }
    }

    struct DirectInvite {
        @Test
        func `Direct invite (XEP-0249) emits roomInviteReceived`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .roomInviteReceived = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message from='admin@example.com'>\
            <x xmlns='jabber:x:conference' jid='room@conference.example.com' reason='Come join'/>\
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .roomInviteReceived(invite) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected roomInviteReceived event")
            }
            #expect(invite.room == testRoomJID)
            #expect(invite.reason == "Come join")

            await client.disconnect()
        }
    }

    struct KickBan {
        @Test
        func `Kick status code 307 emits occupant left`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            // Add occupant first
            await mock.simulateReceive("""
            <presence from='room@conference.example.com/troublemaker'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='none' role='participant'/>\
            </x>\
            </presence>
            """)
            try? await Task.sleep(for: .milliseconds(100))

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .roomOccupantLeft = event { return true }
                    return false
                }
            }

            // Kick presence
            await mock.simulateReceive("""
            <presence type='unavailable' from='room@conference.example.com/troublemaker'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='none' role='none'/>\
            <status code='307'/>\
            </x>\
            </presence>
            """)

            let events = try await eventsTask.value
            guard case let .roomOccupantLeft(room, occupant) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected roomOccupantLeft event")
            }
            #expect(room == testRoomJID)
            #expect(occupant.nickname == "troublemaker")

            await client.disconnect()
        }
    }

    struct OwnMessageHandling {
        @Test
        func `Messages from own nickname still emit roomMessageReceived`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .roomMessageReceived = event { return true }
                    return false
                }
            }

            // Server echoes back our own message
            await mock.simulateReceive("""
            <message type='groupchat' from='room@conference.example.com/me'>\
            <body>My message</body>\
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .roomMessageReceived(message) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected roomMessageReceived event")
            }
            #expect(message.body == "My message")

            await client.disconnect()
        }
    }

    struct OccupantSnapshot {
        @Test
        func `occupants returns current list`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            await mock.simulateReceive("""
            <presence from='room@conference.example.com/alice'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant'/>\
            </x>\
            </presence>
            """)
            await mock.simulateReceive("""
            <presence from='room@conference.example.com/me'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant'/>\
            <status code='110'/>\
            </x>\
            </presence>
            """)
            try? await Task.sleep(for: .milliseconds(200))

            let occupants = module.occupants(in: testRoomJID)
            #expect(occupants.count == 2)

            let nicknames = Set(occupants.map(\.nickname))
            #expect(nicknames.contains("alice"))
            #expect(nicknames.contains("me"))

            await client.disconnect()
        }

        @Test
        func `joinedRooms returns rooms where join was confirmed`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            // Before self-presence, not yet joined
            let beforeJoin = module.joinedRooms()
            #expect(beforeJoin.isEmpty)

            // Self-presence confirms join
            await mock.simulateReceive("""
            <presence from='room@conference.example.com/me'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant'/>\
            <status code='110'/>\
            </x>\
            </presence>
            """)
            try? await Task.sleep(for: .milliseconds(100))

            let afterJoin = module.joinedRooms()
            #expect(afterJoin.count == 1)
            #expect(afterJoin.first == testRoomJID)

            await client.disconnect()
        }
    }

    struct RoomDiscovery {
        @Test
        func `discoverRooms parses disco#items response`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            let discoverTask = Task {
                try await module.discoverRooms(on: "conference.example.com")
            }

            // Wait for IQ to be sent, then respond
            try? await Task.sleep(for: .milliseconds(200))
            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let discoIQ = sentStrings.last(where: { $0.contains("disco#items") })
            let iqID = try #require(discoIQ.flatMap { extractIQID(from: $0) })

            await mock.simulateReceive("""
            <iq type='result' id='\(iqID)' from='conference.example.com'>\
            <query xmlns='http://jabber.org/protocol/disco#items'>\
            <item jid='room@conference.example.com' name='General Chat'/>\
            <item jid='dev@conference.example.com' name='Development'/>\
            </query>\
            </iq>
            """)

            let rooms = try await discoverTask.value
            #expect(rooms.count == 2)
            #expect(rooms[0].jid == testRoomJID)
            #expect(rooms[0].name == "General Chat")

            await client.disconnect()
        }
    }
}

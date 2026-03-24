import Foundation
import Testing
@testable import DuckoCore

private let testConversationID = UUID()

private func makeTempStore() throws -> (FileTranscriptStore, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcript-test-\(UUID().uuidString)")
    return (FileTranscriptStore(baseDirectory: dir), dir)
}

private func makeMessage(
    conversationID: UUID = testConversationID,
    stanzaID: String? = nil,
    serverID: String? = nil,
    fromJID: String = "alice@example.com",
    body: String = "hello",
    timestamp: Date = Date(),
    isOutgoing: Bool = false
) -> ChatMessage {
    ChatMessage(
        id: UUID(),
        conversationID: conversationID,
        stanzaID: stanzaID,
        serverID: serverID,
        fromJID: fromJID,
        body: body,
        timestamp: timestamp,
        isOutgoing: isOutgoing,
        isDelivered: false,
        isEdited: false,
        type: "chat"
    )
}

enum FileTranscriptStoreTests {
    struct WriteAndRead {
        @Test
        func `Appended message is retrievable`() async throws {
            let (store, dir) = try makeTempStore()
            defer { try? FileManager.default.removeItem(at: dir) }

            let msg = makeMessage(stanzaID: "s1", body: "hello world")
            try await store.appendMessage(msg)

            let fetched = try await store.fetchMessages(for: testConversationID, before: nil, limit: 50)
            #expect(fetched.count == 1)
            #expect(fetched[0].body == "hello world")
            #expect(fetched[0].stanzaID == "s1")
            #expect(fetched[0].conversationID == testConversationID)
        }

        @Test
        func `Batch append writes multiple messages`() async throws {
            let (store, dir) = try makeTempStore()
            defer { try? FileManager.default.removeItem(at: dir) }

            let now = Date()
            let messages = (0 ..< 5).map { i in
                makeMessage(stanzaID: "s\(i)", body: "msg \(i)", timestamp: now.addingTimeInterval(Double(i)))
            }
            try await store.appendMessages(messages)

            let fetched = try await store.fetchMessages(for: testConversationID, before: nil, limit: 50)
            #expect(fetched.count == 5)
        }

        @Test
        func `Concurrent appends from separate store instances produce valid JSONL`() async throws {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("transcript-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }

            let store1 = FileTranscriptStore(baseDirectory: dir)
            let store2 = FileTranscriptStore(baseDirectory: dir)
            let convID = UUID()
            let base = Date()

            try await withThrowingTaskGroup(of: Void.self) { group in
                for i in 0 ..< 10 {
                    let store = i.isMultiple(of: 2) ? store1 : store2
                    group.addTask {
                        try await store.appendMessage(makeMessage(
                            conversationID: convID,
                            stanzaID: "s\(i)",
                            body: "msg-\(i)",
                            timestamp: base.addingTimeInterval(Double(i))
                        ))
                    }
                }
                try await group.waitForAll()
            }

            let fetched = try await store1.fetchMessages(for: convID, before: nil, limit: 50)
            #expect(fetched.count == 10)
        }
    }

    struct Pagination {
        @Test
        func `Fetch respects limit`() async throws {
            let (store, dir) = try makeTempStore()
            defer { try? FileManager.default.removeItem(at: dir) }

            let now = Date()
            let messages = (0 ..< 10).map { i in
                makeMessage(stanzaID: "s\(i)", body: "msg \(i)", timestamp: now.addingTimeInterval(Double(i)))
            }
            try await store.appendMessages(messages)

            let fetched = try await store.fetchMessages(for: testConversationID, before: nil, limit: 3)
            #expect(fetched.count == 3)
            // Should return newest first
            #expect(fetched[0].body == "msg 9")
        }

        @Test
        func `Fetch before date filters correctly`() async throws {
            let (store, dir) = try makeTempStore()
            defer { try? FileManager.default.removeItem(at: dir) }

            let base = Date()
            let old = makeMessage(stanzaID: "old", body: "old", timestamp: base)
            let new = makeMessage(stanzaID: "new", body: "new", timestamp: base.addingTimeInterval(100))
            try await store.appendMessages([old, new])

            let fetched = try await store.fetchMessages(for: testConversationID, before: base.addingTimeInterval(50), limit: 50)
            #expect(fetched.count == 1)
            #expect(fetched[0].body == "old")
        }
    }

    struct Amendments {
        @Test
        func `Edit amendment updates body`() async throws {
            let (store, dir) = try makeTempStore()
            defer { try? FileManager.default.removeItem(at: dir) }

            let msg = makeMessage(stanzaID: "s1", body: "original")
            try await store.appendMessage(msg)

            try await store.appendAmendment(TranscriptAmendment(
                action: .edit, targetStanzaID: "s1", timestamp: Date(), body: "corrected"
            ))

            let fetched = try await store.fetchMessages(for: testConversationID, before: nil, limit: 50)
            #expect(fetched[0].body == "corrected")
            #expect(fetched[0].isEdited == true)
            #expect(fetched[0].editedAt != nil)
        }

        @Test
        func `Retraction clears body`() async throws {
            let (store, dir) = try makeTempStore()
            defer { try? FileManager.default.removeItem(at: dir) }

            let msg = makeMessage(stanzaID: "s1", body: "secret")
            try await store.appendMessage(msg)

            try await store.appendAmendment(TranscriptAmendment(
                action: .retract, targetStanzaID: "s1", timestamp: Date()
            ))

            let fetched = try await store.fetchMessages(for: testConversationID, before: nil, limit: 50)
            #expect(fetched[0].isRetracted == true)
            #expect(fetched[0].body == "")
        }

        @Test
        func `Delivery amendment sets isDelivered`() async throws {
            let (store, dir) = try makeTempStore()
            defer { try? FileManager.default.removeItem(at: dir) }

            let msg = makeMessage(stanzaID: "s1", body: "hello", isOutgoing: true)
            try await store.appendMessage(msg)

            try await store.appendAmendment(TranscriptAmendment(
                action: .delivery, targetStanzaID: "s1"
            ))

            let fetched = try await store.fetchMessages(for: testConversationID, before: nil, limit: 50)
            #expect(fetched[0].isDelivered == true)
        }

        @Test
        func `Error amendment sets errorText`() async throws {
            let (store, dir) = try makeTempStore()
            defer { try? FileManager.default.removeItem(at: dir) }

            let msg = makeMessage(stanzaID: "s1", body: "hello")
            try await store.appendMessage(msg)

            try await store.appendAmendment(TranscriptAmendment(
                action: .error, targetStanzaID: "s1", errorText: "Service unavailable"
            ))

            let fetched = try await store.fetchMessages(for: testConversationID, before: nil, limit: 50)
            #expect(fetched[0].errorText == "Service unavailable")
        }

        @Test
        func `ServerID-only retraction resolves without stanzaID`() async throws {
            let (store, dir) = try makeTempStore()
            defer { try? FileManager.default.removeItem(at: dir) }

            let msg = makeMessage(serverID: "mam-123", body: "moderated")
            try await store.appendMessage(msg)

            // Amendment targets serverID only (moderation path)
            try await store.appendAmendment(TranscriptAmendment(
                action: .retract, targetServerID: "mam-123", timestamp: Date()
            ))

            let fetched = try await store.fetchMessages(for: testConversationID, before: nil, limit: 50)
            #expect(fetched[0].isRetracted == true)
            #expect(fetched[0].body == "")
        }

        @Test
        func `ServerID amendment uses server index fast path`() async throws {
            let (store, dir) = try makeTempStore()
            defer { try? FileManager.default.removeItem(at: dir) }

            // Append with both stanzaID and serverID
            let msg = makeMessage(stanzaID: "s1", serverID: "mam-456", body: "indexed")
            try await store.appendMessage(msg)

            // Amendment targets serverID only — should resolve via serverIndex
            try await store.appendAmendment(TranscriptAmendment(
                action: .retract, targetServerID: "mam-456", timestamp: Date()
            ))

            let fetched = try await store.fetchMessages(for: testConversationID, before: nil, limit: 50)
            #expect(fetched[0].isRetracted == true)
            #expect(fetched[0].body == "")
        }

        @Test
        func `Amendment for cold serverID resolves via file scan`() async throws {
            // Use two separate store instances to simulate app restart (empty server index)
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("transcript-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }

            let store1 = FileTranscriptStore(baseDirectory: dir)
            let msg = makeMessage(serverID: "cold-srvid", body: "original")
            try await store1.appendMessage(msg)

            // New store instance = empty server index
            let store2 = FileTranscriptStore(baseDirectory: dir)
            try await store2.appendAmendment(TranscriptAmendment(
                action: .retract, targetServerID: "cold-srvid", timestamp: Date()
            ))

            let fetched = try await store2.fetchMessages(for: testConversationID, before: nil, limit: 50)
            #expect(fetched[0].isRetracted == true)
            #expect(fetched[0].body == "")
        }

        @Test
        func `Amendment for cold stanzaID resolves via file scan`() async throws {
            // Use two separate store instances to simulate app restart (empty stanza index)
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("transcript-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }

            let store1 = FileTranscriptStore(baseDirectory: dir)
            let msg = makeMessage(stanzaID: "cold-sid", body: "original")
            try await store1.appendMessage(msg)

            // New store instance = empty stanza index
            let store2 = FileTranscriptStore(baseDirectory: dir)
            try await store2.appendAmendment(TranscriptAmendment(
                action: .edit, targetStanzaID: "cold-sid", timestamp: Date(), body: "edited after restart"
            ))

            let fetched = try await store2.fetchMessages(for: testConversationID, before: nil, limit: 50)
            #expect(fetched[0].body == "edited after restart")
            #expect(fetched[0].isEdited == true)
        }
    }

    struct Lookup {
        @Test
        func `Find message by stanzaID`() async throws {
            let (store, dir) = try makeTempStore()
            defer { try? FileManager.default.removeItem(at: dir) }

            let msg = makeMessage(stanzaID: "find-me", body: "target")
            try await store.appendMessage(msg)

            let found = try await store.findMessage(stanzaID: "find-me", conversationID: testConversationID)
            #expect(found != nil)
            #expect(found?.body == "target")

            let notFound = try await store.findMessage(stanzaID: "nonexistent", conversationID: testConversationID)
            #expect(notFound == nil)
        }

        @Test
        func `Find message by serverID`() async throws {
            let (store, dir) = try makeTempStore()
            defer { try? FileManager.default.removeItem(at: dir) }

            let msg = makeMessage(serverID: "srv-lookup", body: "server indexed")
            try await store.appendMessage(msg)

            let found = try await store.findMessage(serverID: "srv-lookup", conversationID: testConversationID)
            #expect(found != nil)
            #expect(found?.body == "server indexed")

            let notFound = try await store.findMessage(serverID: "nonexistent", conversationID: testConversationID)
            #expect(notFound == nil)
        }

        @Test
        func `Message exists check`() async throws {
            let (store, dir) = try makeTempStore()
            defer { try? FileManager.default.removeItem(at: dir) }

            let msg = makeMessage(stanzaID: "exists", body: "hi")
            try await store.appendMessage(msg)

            let exists = try await store.messageExists(stanzaID: "exists", conversationID: testConversationID)
            #expect(exists == true)

            let notExists = try await store.messageExists(stanzaID: "nope", conversationID: testConversationID)
            #expect(notExists == false)
        }
    }

    struct Search {
        @Test
        func `Search finds matching messages`() async throws {
            let (store, dir) = try makeTempStore()
            defer { try? FileManager.default.removeItem(at: dir) }

            try await store.appendMessages([
                makeMessage(body: "hello world"),
                makeMessage(body: "goodbye world"),
                makeMessage(body: "hello there")
            ])

            let results = try await store.searchMessages(query: "hello", conversationID: testConversationID, before: nil, after: nil, limit: 50)
            #expect(results.count == 2)
        }
    }

    struct Lifecycle {
        @Test
        func `Delete transcripts removes conversation directory`() async throws {
            let (store, dir) = try makeTempStore()
            defer { try? FileManager.default.removeItem(at: dir) }

            let msg = makeMessage(body: "to be deleted")
            try await store.appendMessage(msg)

            let convDir = dir.appendingPathComponent(testConversationID.uuidString)
            #expect(FileManager.default.fileExists(atPath: convDir.path))

            try await store.deleteTranscripts(for: testConversationID)
            #expect(!FileManager.default.fileExists(atPath: convDir.path))
        }

        @Test
        func `Write and read metadata`() async throws {
            let (store, dir) = try makeTempStore()
            defer { try? FileManager.default.removeItem(at: dir) }

            let metadata = TranscriptMetadata(
                conversationID: testConversationID,
                accountJID: "user@example.com",
                contactJID: "alice@example.com",
                type: "chat",
                displayName: "Alice"
            )
            try await store.writeMetadata(metadata, for: testConversationID)

            let metaURL = dir.appendingPathComponent(testConversationID.uuidString).appendingPathComponent("meta.json")
            #expect(FileManager.default.fileExists(atPath: metaURL.path))

            let data = try Data(contentsOf: metaURL)
            let decoded = try JSONDecoder().decode(TranscriptMetadata.self, from: data)
            #expect(decoded.conversationID == testConversationID)
            #expect(decoded.accountJID == "user@example.com")
            #expect(decoded.contactJID == "alice@example.com")
            #expect(decoded.type == "chat")
            #expect(decoded.displayName == "Alice")
            #expect(decoded.occupantNickname == nil)
        }
    }

    struct Stats {
        @Test
        func `Message count returns correct total`() async throws {
            let (store, dir) = try makeTempStore()
            defer { try? FileManager.default.removeItem(at: dir) }

            try await store.appendMessages([
                makeMessage(body: "one"),
                makeMessage(body: "two"),
                makeMessage(body: "three")
            ])

            let count = try await store.messageCount(for: testConversationID)
            #expect(count == 3)
        }

        @Test
        func `Message date counts returns per-day counts sorted newest first`() async throws {
            let (store, dir) = try makeTempStore()
            defer { try? FileManager.default.removeItem(at: dir) }

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .gmt
            let day1 = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12)))
            let day2a = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 12, hour: 9)))
            let day2b = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 12, hour: 15)))
            let day3 = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 8)))

            try await store.appendMessages([
                makeMessage(body: "a", timestamp: day1),
                makeMessage(body: "b", timestamp: day2a),
                makeMessage(body: "c", timestamp: day2b),
                makeMessage(body: "d", timestamp: day3)
            ])

            let dateCounts = try await store.messageDateCounts(for: testConversationID)
            #expect(dateCounts.count == 3)
            // Newest first
            #expect(dateCounts[0].date == calendar.date(from: DateComponents(year: 2026, month: 3, day: 15))!)
            #expect(dateCounts[0].count == 1)
            #expect(dateCounts[1].date == calendar.date(from: DateComponents(year: 2026, month: 3, day: 12))!)
            #expect(dateCounts[1].count == 2)
            #expect(dateCounts[2].date == calendar.date(from: DateComponents(year: 2026, month: 3, day: 10))!)
            #expect(dateCounts[2].count == 1)
        }

        @Test
        func `Message date counts returns empty for nonexistent conversation`() async throws {
            let (store, dir) = try makeTempStore()
            defer { try? FileManager.default.removeItem(at: dir) }

            let dateCounts = try await store.messageDateCounts(for: UUID())
            #expect(dateCounts.isEmpty)
        }
    }

    struct DateFetch {
        @Test
        func `Fetch messages on date returns all messages for that day`() async throws {
            let (store, dir) = try makeTempStore()
            defer { try? FileManager.default.removeItem(at: dir) }

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .gmt
            let day1Morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 9)))
            let day1Evening = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 21)))
            let day2Morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 11, hour: 10)))

            try await store.appendMessages([
                makeMessage(body: "morning", timestamp: day1Morning),
                makeMessage(body: "evening", timestamp: day1Evening),
                makeMessage(body: "next day", timestamp: day2Morning)
            ])

            let day1Start = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10)))
            let fetched = try await store.fetchMessages(for: testConversationID, on: day1Start)
            #expect(fetched.count == 2)
            // Chronological order
            #expect(fetched[0].body == "morning")
            #expect(fetched[1].body == "evening")
        }

        @Test
        func `Fetch messages on date with no messages returns empty`() async throws {
            let (store, dir) = try makeTempStore()
            defer { try? FileManager.default.removeItem(at: dir) }

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .gmt
            let msg = try makeMessage(body: "hello", timestamp: #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12))))
            try await store.appendMessage(msg)

            let otherDay = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 11)))
            let fetched = try await store.fetchMessages(for: testConversationID, on: otherDay)
            #expect(fetched.isEmpty)
        }
    }
}

// MARK: - TranscriptRecord Round-Trip Tests

enum TranscriptRecordTests {
    struct RoundTrip {
        @Test
        func `Message record round trips through JSON`() throws {
            let msg = makeMessage(stanzaID: "rt1", body: "round trip test")
            let record = TranscriptRecord.from(msg)

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(record)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(TranscriptRecord.self, from: data)

            let restored = decoded.toChatMessage(conversationID: testConversationID)
            #expect(restored != nil)
            #expect(restored?.body == "round trip test")
            #expect(restored?.stanzaID == "rt1")
        }

        @Test
        func `Amendment record round trips through JSON`() throws {
            let amendment = TranscriptAmendment(action: .edit, targetStanzaID: "s1", timestamp: Date(), body: "edited")
            let record = TranscriptRecord.from(amendment)

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(record)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(TranscriptRecord.self, from: data)

            let restored = decoded.toAmendment()
            #expect(restored != nil)
            #expect(restored?.action == .edit)
            #expect(restored?.body == "edited")
        }
    }
}

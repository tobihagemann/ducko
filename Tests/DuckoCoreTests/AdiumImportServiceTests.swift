import DuckoXMPP
import Foundation
import os
import Testing
@testable import DuckoCore

enum AdiumImportServiceTests {
    struct SyntheticJIDs {
        @Test
        func `Jabber accounts use identifier directly`() async {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let service = AdiumImportService(store: store, transcripts: transcripts)
            let jid = await service.syntheticJID(identifier: "saibot@exnet.me", service: "Jabber")
            #expect(jid == "saibot@exnet.me")
        }

        @Test
        func `GTalk accounts use identifier directly`() async {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let service = AdiumImportService(store: store, transcripts: transcripts)
            let jid = await service.syntheticJID(identifier: "user@gmail.com", service: "GTalk")
            #expect(jid == "user@gmail.com")
        }

        @Test
        func `Non-XMPP services get synthetic JIDs`() async {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let service = AdiumImportService(store: store, transcripts: transcripts)

            let aim = await service.syntheticJID(identifier: "musclerumble", service: "AIM")
            #expect(aim == "musclerumble@aim.adium-import")

            let icq = await service.syntheticJID(identifier: "101494097", service: "ICQ")
            #expect(icq == "101494097@icq.adium-import")

            let msn = await service.syntheticJID(identifier: "user@example.org", service: "MSN")
            #expect(msn == "user@example.org@msn.adium-import")
        }
    }

    struct Idempotency {
        @Test
        func `Importing same file twice produces no duplicates`() async throws {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let service = AdiumImportService(store: store, transcripts: transcripts)

            let xml = """
            <?xml version="1.0" encoding="UTF-8" ?>
            <chat xmlns="http://purl.org/net/ulf/ns/0.4-02" account="saibot@exnet.me" service="Jabber">
            <message sender="saibot@exnet.me" time="2016-01-12T00:31:17+0100" alias="saibot"><div>hello</div></message>
            <message sender="buddy@exnet.me" time="2016-01-12T00:31:34+0100" alias="buddy"><div>hi</div></message>
            </chat>
            """

            // Create a temporary file to import
            let tmpDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("adium-test-\(UUID().uuidString)")
            let serviceDir = tmpDir.appendingPathComponent("Jabber.saibot@exnet.me")
            let contactDir = serviceDir.appendingPathComponent("buddy@exnet.me")
            let chatlogDir = contactDir.appendingPathComponent("buddy@exnet.me (2016-01-12T00.31.17+0100).chatlog")
            try FileManager.default.createDirectory(at: chatlogDir, withIntermediateDirectories: true)
            let xmlFile = chatlogDir.appendingPathComponent("buddy@exnet.me (2016-01-12T00.31.17+0100).xml")
            try xml.write(to: xmlFile, atomically: true, encoding: .utf8)

            defer { try? FileManager.default.removeItem(at: tmpDir) }

            let sources = try AdiumLogDiscovery.discoverSources(at: tmpDir)
            #expect(sources.count == 1)

            // First import
            let result1 = try await service.importLogs(from: sources) { _ in }
            #expect(result1.importedMessages == 2)
            #expect(result1.skippedDuplicates == 0)

            // Second import (idempotent)
            let result2 = try await service.importLogs(from: sources) { _ in }
            #expect(result2.importedMessages == 0)
            #expect(result2.skippedDuplicates == 2)

            // Verify total messages in transcript store
            let allMessages = await transcripts.messages
            #expect(allMessages.count == 2)
        }
    }

    struct NoAccountCreation {
        @Test
        func `Does not create accounts during import`() async throws {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let service = AdiumImportService(store: store, transcripts: transcripts)

            let xml = """
            <?xml version="1.0" encoding="UTF-8" ?>
            <chat xmlns="http://purl.org/net/ulf/ns/0.4-02" account="saibot@exnet.me" service="Jabber">
            <message sender="saibot@exnet.me" time="2016-01-12T00:31:17+0100"><div>hello</div></message>
            </chat>
            """

            let tmpDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("adium-test-\(UUID().uuidString)")
            let serviceDir = tmpDir.appendingPathComponent("Jabber.saibot@exnet.me")
            let contactDir = serviceDir.appendingPathComponent("buddy@exnet.me")
            let chatlogDir = contactDir.appendingPathComponent("test.chatlog")
            try FileManager.default.createDirectory(at: chatlogDir, withIntermediateDirectories: true)
            try xml.write(to: chatlogDir.appendingPathComponent("test.xml"), atomically: true, encoding: .utf8)

            defer { try? FileManager.default.removeItem(at: tmpDir) }

            let sources = try AdiumLogDiscovery.discoverSources(at: tmpDir)
            _ = try await service.importLogs(from: sources) { _ in }

            let accounts = await store.accounts
            #expect(accounts.isEmpty)

            let conversations = await store.conversations
            #expect(conversations.count == 1)

            let conversation = try #require(conversations.first)
            #expect(conversation.accountID == nil)
            #expect(conversation.jid.description == "buddy@exnet.me")
        }
    }

    struct ProgressReporting {
        @Test
        func `Reports progress during import`() async throws {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let service = AdiumImportService(store: store, transcripts: transcripts)

            let xml = """
            <?xml version="1.0" encoding="UTF-8" ?>
            <chat xmlns="http://purl.org/net/ulf/ns/0.4-02" account="user@example.com" service="Jabber">
            <message sender="user@example.com" time="2016-01-12T00:31:17+0100"><div>hello</div></message>
            </chat>
            """

            let tmpDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("adium-test-\(UUID().uuidString)")
            let serviceDir = tmpDir.appendingPathComponent("Jabber.user@example.com")
            let contactDir = serviceDir.appendingPathComponent("buddy@example.com")
            let chatlogDir = contactDir.appendingPathComponent("test.chatlog")
            try FileManager.default.createDirectory(at: chatlogDir, withIntermediateDirectories: true)
            try xml.write(to: chatlogDir.appendingPathComponent("test.xml"), atomically: true, encoding: .utf8)

            defer { try? FileManager.default.removeItem(at: tmpDir) }

            let sources = try AdiumLogDiscovery.discoverSources(at: tmpDir)
            let progressCount = OSAllocatedUnfairLock(initialState: 0)
            let result = try await service.importLogs(from: sources) { _ in
                progressCount.withLock { $0 += 1 }
            }

            // Final progress callback always fires
            let count = progressCount.withLock { $0 }
            #expect(count > 0)
            #expect(result.totalFiles == 1)
            #expect(result.completedFiles == 1)
        }
    }
}

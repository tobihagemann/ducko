import Dispatch
import DuckoCore
import DuckoData
import Foundation
import Network
import SwiftData
import Testing
@testable import DuckoXMPP

@MainActor
struct RosterProcessTests {
    @Test(arguments: ["add", "remove", "interactive"])
    func `real CLI reports confirmed partial result and tears down`(operation: String) async throws {
        let server = RosterLoopbackServer()
        let port = try await server.start()
        let profile = "roster-local-\(UUID().uuidString)"
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Ducko-Dev-\(profile)")
        defer { try? FileManager.default.removeItem(at: directory); UserDefaults.standard.removePersistentDomain(forName: "im.ducko.dev.\(profile)") }
        try await seed(directory: directory, port: port)
        let binary = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: ".build/debug/DuckoCLI")
        let process = Process()
        process.executableURL = binary
        process.arguments = operation == "interactive" ? ["interactive", "--output", "plain"] : ["roster", operation, "bob@example.com", "--output", "json"]
        let parent = ProcessInfo.processInfo.environment
        process.environment = ["HOME": parent["HOME"] ?? "", "PATH": parent["PATH"] ?? "", "DUCKO_PROFILE": profile]
        let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        try process.run()
        if operation == "interactive" { try stdin.fileHandleForWriting.write(contentsOf: Data("/add bob@example.com\nhelp\nquit\n".utf8)) }
        try stdin.fileHandleForWriting.close()
        let output = Task.detached { try stdout.fileHandleForReading.readToEnd() ?? Data() }
        let errors = Task.detached { try stderr.fileHandleForReading.readToEnd() ?? Data() }
        do {
            let deadline = ContinuousClock.now + .seconds(15)
            while process.isRunning, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            let text = try await String(decoding: output.value, as: UTF8.self)
            let errorText = try await String(decoding: errors.value, as: UTF8.self)
            #expect(process.terminationReason == .exit, Comment(rawValue: errorText))
            #expect(await server.sawStreamClose)
            try assertOutput(operation: operation, text: text, errorText: errorText, exitCode: process.terminationStatus)
            await server.stop()
        } catch {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            _ = await output.result
            _ = await errors.result
            await server.stop()
            throw error
        }
    }

    private func assertOutput(operation: String, text: String, errorText: String, exitCode: Int32) throws {
        if operation == "interactive" {
            #expect(exitCode == 0, Comment(rawValue: text + errorText))
            #expect(text.contains("sync"), Comment(rawValue: text))
            #expect(text.contains("Commands:"), Comment(rawValue: text))
        } else {
            #expect(exitCode == 3, Comment(rawValue: text + errorText))
            let objects = try text.split(separator: "\n").map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
            let outcomes = objects.filter { $0["type"] as? String == "roster_command" }
            #expect(outcomes.count == 1)
            #expect(outcomes.first?["operation"] as? String == operation)
            #expect(outcomes.first?["remote_status"] as? String == "confirmed")
            #expect(outcomes.first?["local_status"] as? String == "incomplete")
            #expect(outcomes.first?["result"] as? String == "partial")
            #expect(!errorText.contains("Error:"))
        }
    }

    private func seed(directory: URL, port: UInt16) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let container = try ModelContainer(for: ModelContainerFactory.schema, configurations: [ModelConfiguration(url: directory.appending(path: "default.store"))])
        let store = SwiftDataPersistenceStore(modelContainer: container)
        let account = try Account(id: UUID(), jid: #require(BareJID.parse("alice@example.com")), isEnabled: true, connectOnLaunch: false, host: "127.0.0.1", port: Int(port), requireTLS: false, createdAt: Date())
        try await store.saveAccount(account)
        FileCredentialStore(fileURL: directory.appending(path: "credentials.json")).savePassword("local-fixture", for: account.jid.description)
    }
}

private actor RosterLoopbackServer {
    private let queue = DispatchQueue(label: "ducko.roster-loopback")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var parser = XMPPStreamParser()
    private var authenticated = false
    private var mutated = false
    private(set) var sawStreamClose = false

    func start() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { connection in Task { await self.accept(connection) } }
        let states = AsyncThrowingStream<UInt16, Error>.makeStream()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = listener.port { states.continuation.yield(port.rawValue); states.continuation.finish() }
            case let .failed(error): states.continuation.finish(throwing: error)
            case .cancelled: states.continuation.finish(throwing: CancellationError())
            case .setup, .waiting: break
            @unknown default: break
            }
        }
        listener.start(queue: queue)
        for try await port in states.stream {
            return port
        }
        throw CancellationError()
    }

    private func accept(_ connection: NWConnection) {
        self.connection = connection
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            Task { await self.received(data, ended: complete || error != nil) }
        }
    }

    private func received(_ data: Data?, ended: Bool) {
        if let data {
            for event in parser.parse(Array(data)) {
                switch event {
                case .streamOpened:
                    send("<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' from='example.com' version='1.0'><stream:features>" + (authenticated ? "<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'/>" : "<mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><mechanism>PLAIN</mechanism></mechanisms>") + "</stream:features>")
                case let .stanzaReceived(element): handle(element)
                case .streamClosed:
                    sawStreamClose = true
                    send("</stream:stream>")
                case .error: break
                }
            }
        }
        if !ended { receive() }
    }

    private func handle(_ element: DuckoXMPP.XMLElement) {
        if element.name == "auth" {
            authenticated = true
            parser = XMPPStreamParser()
            send("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
        } else if element.name == "iq", let id = element.attribute("id") {
            let iq = XMPPIQ(element: element)
            if element.child(named: "bind", namespace: XMPPNamespaces.bind) != nil {
                send("<iq type='result' id='\(id)'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><jid>alice@example.com/fixture</jid></bind></iq>")
            } else if element.child(named: "query", namespace: XMPPNamespaces.roster) != nil {
                if iq.type == "set" { mutated = true }
                let body = mutated ? "" : "<query xmlns='jabber:iq:roster' ver='initial'/>"
                send("<iq type='result' id='\(id)'>\(body)</iq>")
            } else if iq.type == "set" {
                send("<iq type='result' id='\(id)'/>")
            } else if iq.type == "get" {
                send("<iq type='error' id='\(id)'><error type='cancel'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>")
            }
        }
    }

    private func send(_ text: String) {
        connection?.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }

    func stop() {
        connection?.cancel(); listener?.cancel()
    }
}

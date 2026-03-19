import os
import Testing
@testable import DuckoXMPP

// MARK: - Tests

enum ServiceOutageModuleTests {
    struct OutageParsing {
        @Test
        func `Emits event with all fields when outage present in stream features`() async throws {
            let module = ServiceOutageModule()
            var features = XMLElement(name: "features", namespace: "http://etherx.jabber.org/streams")
            var outage = XMLElement(name: "outage", namespace: XMPPNamespaces.serviceOutage)
            var desc = XMLElement(name: "description")
            desc.addText("Scheduled maintenance")
            outage.addChild(desc)
            var expectedEnd = XMLElement(name: "expected-end")
            expectedEnd.addText("2026-03-20T06:00:00Z")
            outage.addChild(expectedEnd)
            var altDomain = XMLElement(name: "alternative-domain")
            altDomain.addText("backup.example.com")
            outage.addChild(altDomain)
            features.addChild(outage)
            let serverFeatures = features

            let receivedInfo = OSAllocatedUnfairLock<ServiceOutageInfo?>(initialState: nil)
            let context = ModuleContext(
                sendStanza: { _ in },
                sendIQ: { _ in nil },
                emitEvent: { event in
                    if case let .serviceOutageReceived(info) = event {
                        receivedInfo.withLock { $0 = info }
                    }
                },
                generateID: { "test-1" },
                connectedJID: { FullJID.parse("user@example.com/res") },
                domain: "example.com",
                serverStreamFeatures: { serverFeatures }
            )
            module.setUp(context)

            try await module.handleConnect()

            let info = try #require(receivedInfo.withLock { $0 })
            #expect(info.description == "Scheduled maintenance")
            #expect(info.expectedEnd == "2026-03-20T06:00:00Z")
            #expect(info.alternativeDomain == "backup.example.com")
        }

        @Test
        func `Handles partial fields gracefully`() async throws {
            let module = ServiceOutageModule()
            var features = XMLElement(name: "features", namespace: "http://etherx.jabber.org/streams")
            var outage = XMLElement(name: "outage", namespace: XMPPNamespaces.serviceOutage)
            var desc = XMLElement(name: "description")
            desc.addText("Brief maintenance")
            outage.addChild(desc)
            features.addChild(outage)
            let serverFeatures = features

            let receivedInfo = OSAllocatedUnfairLock<ServiceOutageInfo?>(initialState: nil)
            let context = ModuleContext(
                sendStanza: { _ in },
                sendIQ: { _ in nil },
                emitEvent: { event in
                    if case let .serviceOutageReceived(info) = event {
                        receivedInfo.withLock { $0 = info }
                    }
                },
                generateID: { "test-1" },
                connectedJID: { FullJID.parse("user@example.com/res") },
                domain: "example.com",
                serverStreamFeatures: { serverFeatures }
            )
            module.setUp(context)

            try await module.handleConnect()

            let info = try #require(receivedInfo.withLock { $0 })
            #expect(info.description == "Brief maintenance")
            #expect(info.expectedEnd == nil)
            #expect(info.alternativeDomain == nil)
        }

        @Test
        func `Does not emit event when no outage in features`() async throws {
            let module = ServiceOutageModule()
            var features = XMLElement(name: "features", namespace: "http://etherx.jabber.org/streams")
            features.addChild(XMLElement(name: "bind", namespace: XMPPNamespaces.bind))
            let serverFeatures = features

            let eventEmitted = OSAllocatedUnfairLock(initialState: false)
            let context = ModuleContext(
                sendStanza: { _ in },
                sendIQ: { _ in nil },
                emitEvent: { event in
                    if case .serviceOutageReceived = event {
                        eventEmitted.withLock { $0 = true }
                    }
                },
                generateID: { "test-1" },
                connectedJID: { FullJID.parse("user@example.com/res") },
                domain: "example.com",
                serverStreamFeatures: { serverFeatures }
            )
            module.setUp(context)

            try await module.handleConnect()

            #expect(!eventEmitted.withLock { $0 })
        }
    }

    struct StreamResume {
        @Test
        func `Checks for outage on stream resume`() async throws {
            let module = ServiceOutageModule()
            var features = XMLElement(name: "features", namespace: "http://etherx.jabber.org/streams")
            var outage = XMLElement(name: "outage", namespace: XMPPNamespaces.serviceOutage)
            var desc = XMLElement(name: "description")
            desc.addText("Resumed outage")
            outage.addChild(desc)
            features.addChild(outage)
            let serverFeatures = features

            let receivedInfo = OSAllocatedUnfairLock<ServiceOutageInfo?>(initialState: nil)
            let context = ModuleContext(
                sendStanza: { _ in },
                sendIQ: { _ in nil },
                emitEvent: { event in
                    if case let .serviceOutageReceived(info) = event {
                        receivedInfo.withLock { $0 = info }
                    }
                },
                generateID: { "test-1" },
                connectedJID: { FullJID.parse("user@example.com/res") },
                domain: "example.com",
                serverStreamFeatures: { serverFeatures }
            )
            module.setUp(context)

            try await module.handleResume()

            let info = try #require(receivedInfo.withLock { $0 })
            #expect(info.description == "Resumed outage")
        }
    }

    struct DiscoFeature {
        @Test
        func `Does not advertise service outage in disco features`() {
            let module = ServiceOutageModule()
            #expect(module.features.isEmpty)
        }
    }
}

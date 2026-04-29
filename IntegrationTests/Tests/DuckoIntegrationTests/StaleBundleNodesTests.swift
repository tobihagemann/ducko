import DuckoXMPP
import Testing

/// Deterministic tests for `ResetTestServerState.staleBundleNodes(in:ownedBy:keeping:)`.
/// The live reset suite only exercises whatever state the server happens to
/// have, so it can't prove the predicate excludes the live bundle, foreign
/// JIDs, or non-bundle nodes. These cases pin that behaviour against
/// synthetic disco#items results so a future refactor can't drift one of
/// the predicate's two callers (sweep loop vs. postcondition re-query).
///
/// Declared as a top-level `enum` so the suite does not inherit
/// `DuckoIntegrationTests`'s `.enabled(if: TestCredentials.isAvailable)`
/// trait — the predicate has no live-server dependency and must run on any
/// developer or CI environment.
enum StaleBundleNodesTests {
    struct Filtering {
        private let aliceJID = BareJID.parse("alice@xmpp.tobiha.de")!
        private let bobJID = BareJID.parse("bob@xmpp.tobiha.de")!
        private let liveDeviceID: UInt32 = 4242
        private var liveBundleNode: String {
            "\(OMEMOModule.bundleNodePrefix)\(liveDeviceID)"
        }

        @Test func `stale own bundles are reported, live bundle is preserved`() {
            let items: [ServiceDiscoveryModule.Item] = [
                bundleItem(jid: aliceJID, deviceID: 1),
                bundleItem(jid: aliceJID, deviceID: liveDeviceID),
                bundleItem(jid: aliceJID, deviceID: 99)
            ]
            let stale = DuckoIntegrationTests.ResetTestServerState.staleBundleNodes(
                in: items,
                ownedBy: aliceJID,
                keeping: liveBundleNode
            )
            #expect(Set(stale) == [
                "\(OMEMOModule.bundleNodePrefix)1",
                "\(OMEMOModule.bundleNodePrefix)99"
            ])
        }

        @Test func `foreign-JID bundle items are ignored`() {
            let items: [ServiceDiscoveryModule.Item] = [
                bundleItem(jid: bobJID, deviceID: 1),
                bundleItem(jid: aliceJID, deviceID: 1)
            ]
            let stale = DuckoIntegrationTests.ResetTestServerState.staleBundleNodes(
                in: items,
                ownedBy: aliceJID,
                keeping: liveBundleNode
            )
            #expect(stale == ["\(OMEMOModule.bundleNodePrefix)1"])
        }

        @Test func `non-bundle PEP nodes are ignored`() {
            let items: [ServiceDiscoveryModule.Item] = [
                ServiceDiscoveryModule.Item(jid: .bare(aliceJID), node: XMPPNamespaces.omemoDevices),
                ServiceDiscoveryModule.Item(jid: .bare(aliceJID), node: "urn:xmpp:bookmarks:1"),
                ServiceDiscoveryModule.Item(jid: .bare(aliceJID), node: "http://www.xmpp.org/extensions/xep-0084.html#metadata")
            ]
            let stale = DuckoIntegrationTests.ResetTestServerState.staleBundleNodes(
                in: items,
                ownedBy: aliceJID,
                keeping: liveBundleNode
            )
            #expect(stale.isEmpty)
        }

        @Test func `items without a node attribute are ignored`() {
            let items: [ServiceDiscoveryModule.Item] = [
                ServiceDiscoveryModule.Item(jid: .bare(aliceJID), name: "Avatar"),
                ServiceDiscoveryModule.Item(jid: .bare(aliceJID))
            ]
            let stale = DuckoIntegrationTests.ResetTestServerState.staleBundleNodes(
                in: items,
                ownedBy: aliceJID,
                keeping: liveBundleNode
            )
            #expect(stale.isEmpty)
        }

        @Test func `empty disco result yields no stale nodes`() {
            let stale = DuckoIntegrationTests.ResetTestServerState.staleBundleNodes(
                in: [],
                ownedBy: aliceJID,
                keeping: liveBundleNode
            )
            #expect(stale.isEmpty)
        }

        @Test func `a second pass over the post-sweep state yields no stale nodes`() {
            let items: [ServiceDiscoveryModule.Item] = [
                bundleItem(jid: aliceJID, deviceID: liveDeviceID)
            ]
            let stale = DuckoIntegrationTests.ResetTestServerState.staleBundleNodes(
                in: items,
                ownedBy: aliceJID,
                keeping: liveBundleNode
            )
            #expect(stale.isEmpty)
        }

        private func bundleItem(jid: BareJID, deviceID: UInt32) -> ServiceDiscoveryModule.Item {
            ServiceDiscoveryModule.Item(
                jid: .bare(jid),
                node: "\(OMEMOModule.bundleNodePrefix)\(deviceID)"
            )
        }
    }
}

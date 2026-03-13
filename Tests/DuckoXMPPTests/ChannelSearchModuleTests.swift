import Testing
@testable import DuckoXMPP

struct ChannelSearchModuleTests {
    @Test
    func `Namespace constants`() {
        #expect(XMPPNamespaces.channelSearch == "urn:xmpp:channel-search:0")
        #expect(XMPPNamespaces.channelSearchQuery == "urn:xmpp:channel-search:0:search")
    }

    @Test
    func `SearchQuery defaults`() {
        let query = ChannelSearchModule.SearchQuery(keyword: "test")
        #expect(query.keyword == "test")
        #expect(query.searchInName)
        #expect(query.searchInDescription)
        #expect(query.sortKey == nil)
        #expect(query.maxResults == nil)
        #expect(query.after == nil)
    }

    @Test
    func `ChannelInfo creation`() throws {
        let jid = try #require(BareJID.parse("room@conference.example.com"))
        let info = ChannelSearchModule.ChannelInfo(
            address: jid,
            name: "Test Room",
            userCount: 42,
            isOpen: true,
            description: "A test room"
        )
        #expect(info.address == jid)
        #expect(info.name == "Test Room")
        #expect(info.userCount == 42)
        #expect(info.isOpen == true)
        #expect(info.description == "A test room")
    }

    @Test
    func `SearchResult empty`() {
        let result = ChannelSearchModule.SearchResult(items: [], totalCount: nil, lastID: nil)
        #expect(result.items.isEmpty)
        #expect(result.totalCount == nil)
        #expect(result.lastID == nil)
    }

    @Test
    func `SearchResult with pagination`() throws {
        let jid = try #require(BareJID.parse("room@conference.example.com"))
        let item = ChannelSearchModule.ChannelInfo(
            address: jid, name: "Room", userCount: 5, isOpen: true, description: nil
        )
        let result = ChannelSearchModule.SearchResult(
            items: [item], totalCount: 100, lastID: "last-item-id"
        )
        #expect(result.items.count == 1)
        #expect(result.totalCount == 100)
        #expect(result.lastID == "last-item-id")
    }

    @Test
    func `Module features`() {
        let module = ChannelSearchModule()
        #expect(module.features == [XMPPNamespaces.channelSearch])
    }
}

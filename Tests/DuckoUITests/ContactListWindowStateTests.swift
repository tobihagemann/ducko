import Testing
@testable import DuckoUI

@MainActor
struct ContactListWindowStateTests {
    @Test func `toggleSearch reveals the search field`() {
        let state = ContactListWindowState()
        #expect(state.isSearching == false)

        state.toggleSearch()

        #expect(state.isSearching == true)
    }

    @Test func `toggleSearch off clears the query`() {
        let state = ContactListWindowState()
        state.toggleSearch()
        state.searchText = "alice"

        state.toggleSearch()

        #expect(state.isSearching == false)
        #expect(state.searchText == "")
    }

    @Test func `endSearch resets both the flag and the query`() {
        let state = ContactListWindowState()
        state.isSearching = true
        state.searchText = "bob"

        state.endSearch()

        #expect(state.isSearching == false)
        #expect(state.searchText == "")
    }
}

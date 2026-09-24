import DuckoCore
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoUI

struct IdentityResolverTests {
    private let first: Account
    private let second: Account
    private let disabled: Account

    init() throws {
        self.first = try Self.account("first@example.com")
        self.second = try Self.account("second@example.com")
        self.disabled = try Self.account("disabled@example.com", isEnabled: false)
    }

    private static func account(_ jid: String, isEnabled: Bool = true) throws -> Account {
        try Account(id: UUID(), jid: #require(BareJID.parse(jid)), isEnabled: isEnabled, connectOnLaunch: true, createdAt: Date())
    }

    private func connected(_ account: Account) throws -> AccountService.ConnectionState {
        try .connected(#require(FullJID.parse("\(account.jid)/ducko")))
    }

    private func resolve(picked: Account? = nil, held: Account? = nil, _ states: [UUID: AccountService.ConnectionState]) -> UUID? {
        IdentityResolver.resolve(pickedID: picked?.id, heldID: held?.id, accounts: [disabled, first, second], connectionStates: states)?.id
    }

    @Test func `a connected pick wins`() throws {
        let states = try [first.id: connected(first), second.id: connected(second)]
        #expect(resolve(picked: second, held: first, states) == second.id)
    }

    @Test(arguments: [AccountService.ConnectionState.connecting, .disconnected])
    func `a pick that is not connected still wins`(state: AccountService.ConnectionState) throws {
        let states = try [first.id: connected(first), second.id: state]
        #expect(resolve(picked: second, held: first, states) == second.id)
    }

    @Test func `a disabled pick falls back to the held identity`() throws {
        let states = try [first.id: connected(first), second.id: connected(second)]
        #expect(resolve(picked: disabled, held: second, states) == second.id)
    }

    @Test func `the held identity wins over list order without a pick`() throws {
        let states = try [first.id: connected(first), second.id: connected(second)]
        #expect(resolve(held: second, states) == second.id)
    }

    @Test func `without a pick or hold the first connected account wins`() throws {
        let states = try [first.id: .disconnected, second.id: connected(second)]
        #expect(resolve(held: first, states) == second.id)
    }

    @Test func `with nothing connected the first enabled account wins`() {
        #expect(resolve(held: second, [:]) == first.id)
    }

    @Test func `a held identity that was disabled no longer wins`() throws {
        let states = try [first.id: connected(first), disabled.id: connected(disabled)]
        let resolved = IdentityResolver.resolve(pickedID: nil, heldID: disabled.id, accounts: [first, disabled], connectionStates: states)
        #expect(resolved?.id == first.id)
    }
}

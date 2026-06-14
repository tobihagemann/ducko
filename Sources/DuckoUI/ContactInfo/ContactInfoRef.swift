import Foundation

/// Presentation value for the Contact Info window. Carries the `accountID` alongside
/// the JID because the window's actions need it: `ProfileService.fetchProfile(for:accountID:)`
/// takes an account, and `RosterService.contact(jidString:)` returns the first match across
/// all accounts — so a bare JID alone resolves the wrong account when it exists on two.
public struct ContactInfoRef: Codable, Hashable {
    public var accountID: UUID
    public var jid: String

    public init(accountID: UUID, jid: String) {
        self.accountID = accountID
        self.jid = jid
    }
}

import Foundation
import Testing
@testable import DuckoCore

enum ProfileServicePurgeTests {
    struct Purge {
        @Test
        @MainActor
        func `forgetAccount clears only the targeted account's profile`() {
            let service = ProfileService()
            let accountA = UUID()
            let accountB = UUID()
            service.setOwnProfileForTesting(ProfileInfo(fullName: "Alice"), accountID: accountA)
            service.setOwnProfileForTesting(ProfileInfo(fullName: "Bob"), accountID: accountB)
            #expect(service.ownProfile(for: accountA) != nil)
            #expect(service.ownProfile(for: accountB) != nil)

            service.forgetAccount(accountA)

            #expect(service.ownProfile(for: accountA) == nil)
            #expect(service.ownProfile(for: accountB)?.fullName == "Bob")
        }

        @Test
        @MainActor
        func `a connect that finds no own vCard clears the kept profile`() {
            let service = ProfileService()
            let accountID = UUID()
            service.setOwnProfileForTesting(ProfileInfo(fullName: "Alice"), accountID: accountID)

            service.receiveOwnVCard(nil, accountID: accountID)

            #expect(service.ownProfile(for: accountID) == nil)
        }
    }
}

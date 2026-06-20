import Foundation
import Testing
@testable import DuckoCore

enum ProfileServicePurgeTests {
    struct Purge {
        @Test
        @MainActor
        func `purgeAccount clears only the targeted account's profile`() {
            let service = ProfileService()
            let accountA = UUID()
            let accountB = UUID()
            service.setOwnProfileForTesting(ProfileInfo(fullName: "Alice"), accountID: accountA)
            service.setOwnProfileForTesting(ProfileInfo(fullName: "Bob"), accountID: accountB)
            #expect(service.ownProfile(for: accountA) != nil)
            #expect(service.ownProfile(for: accountB) != nil)

            service.purgeAccount(accountA)

            #expect(service.ownProfile(for: accountA) == nil)
            #expect(service.ownProfile(for: accountB)?.fullName == "Bob")
        }
    }
}

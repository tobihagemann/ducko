import CryptoKit
import DuckoXMPP
import Foundation
import os

private let log = Logger(subsystem: "com.ducko.core", category: "profile")

@MainActor @Observable
public final class ProfileService {
    public enum ProfileServiceError: Error, LocalizedError {
        case notConnected

        public var errorDescription: String? {
            switch self {
            case .notConnected: "Not connected to account"
            }
        }
    }

    public private(set) var ownProfile: ProfileInfo?

    private weak var accountService: AccountService?

    public init() {}

    // MARK: - Wiring

    func setAccountService(_ service: AccountService) {
        accountService = service
    }

    // MARK: - Public API

    public func fetchOwnProfile(accountID: UUID) async {
        guard let client = accountService?.client(for: accountID) else { return }
        guard let vcardModule = await client.module(ofType: VCardModule.self) else { return }

        do {
            let vcard = try await vcardModule.fetchOwnVCard(forceRefresh: true)
            if let vcard {
                ownProfile = mapVCardToProfileInfo(vcard)
            }
        } catch {
            log.warning("Failed to fetch own vCard: \(error)")
        }
    }

    public func publishProfile(_ profile: ProfileInfo, accountID: UUID) async throws {
        guard let client = accountService?.client(for: accountID) else {
            throw ProfileServiceError.notConnected
        }
        guard let vcardModule = await client.module(ofType: VCardModule.self) else {
            throw ProfileServiceError.notConnected
        }

        let vcard = mapProfileInfoToVCard(profile)
        try await vcardModule.publishVCard(vcard)
        ownProfile = profile
    }

    // MARK: - Mapping

    private func mapVCardToProfileInfo(_ vcard: VCardModule.VCard) -> ProfileInfo {
        ProfileInfo(
            fullName: vcard.fullName,
            nickname: vcard.nickname,
            familyName: vcard.name?.familyName,
            givenName: vcard.name?.givenName,
            middleName: vcard.name?.middleName,
            namePrefix: vcard.name?.prefix,
            nameSuffix: vcard.name?.suffix,
            emails: vcard.emails.map { mapEmail($0) },
            telephones: vcard.telephones.map { mapTelephone($0) },
            addresses: vcard.addresses.map { mapAddress($0) },
            organization: vcard.organization,
            title: vcard.title,
            role: vcard.role,
            url: vcard.url,
            birthday: vcard.birthday,
            note: vcard.note,
            photoData: vcard.photoData.map { Data($0) },
            photoType: vcard.photoType
        )
    }

    private func mapProfileInfoToVCard(_ profile: ProfileInfo) -> VCardModule.VCard {
        var name: VCardModule.VCard.Name?
        if profile.familyName != nil || profile.givenName != nil || profile.middleName != nil
            || profile.namePrefix != nil || profile.nameSuffix != nil {
            name = VCardModule.VCard.Name(
                familyName: profile.familyName,
                givenName: profile.givenName,
                middleName: profile.middleName,
                prefix: profile.namePrefix,
                suffix: profile.nameSuffix
            )
        }

        let photoBytes = profile.photoData.map { Array($0) }
        let photoHash: String? = photoBytes.map { bytes in
            Insecure.SHA1.hash(data: bytes)
                .map { byte in
                    let hex = String(byte, radix: 16, uppercase: false)
                    return hex.count < 2 ? "0" + hex : hex
                }
                .joined()
        }

        return VCardModule.VCard(
            fullName: profile.fullName,
            nickname: profile.nickname,
            name: name,
            emails: profile.emails.map { mapEmailBack($0) },
            telephones: profile.telephones.map { mapTelephoneBack($0) },
            addresses: profile.addresses.map { mapAddressBack($0) },
            organization: profile.organization,
            title: profile.title,
            role: profile.role,
            url: profile.url,
            birthday: profile.birthday,
            note: profile.note,
            photoData: photoBytes,
            photoType: profile.photoType,
            photoHash: photoHash
        )
    }

    // MARK: - Entry Type Mapping

    private func mapEntryType(_ type: VCardModule.EntryType) -> ProfileInfo.EntryType {
        switch type {
        case .home: .home
        case .work: .work
        }
    }

    private func mapEntryTypeBack(_ type: ProfileInfo.EntryType) -> VCardModule.EntryType {
        switch type {
        case .home: .home
        case .work: .work
        }
    }

    private func mapEmail(_ email: VCardModule.VCard.Email) -> ProfileInfo.EmailEntry {
        ProfileInfo.EmailEntry(address: email.address, types: email.types.map { mapEntryType($0) })
    }

    private func mapEmailBack(_ entry: ProfileInfo.EmailEntry) -> VCardModule.VCard.Email {
        VCardModule.VCard.Email(address: entry.address, types: entry.types.map { mapEntryTypeBack($0) })
    }

    private func mapTelephone(_ tel: VCardModule.VCard.Telephone) -> ProfileInfo.TelephoneEntry {
        ProfileInfo.TelephoneEntry(number: tel.number, types: tel.types.map { mapEntryType($0) })
    }

    private func mapTelephoneBack(_ entry: ProfileInfo.TelephoneEntry) -> VCardModule.VCard.Telephone {
        VCardModule.VCard.Telephone(number: entry.number, types: entry.types.map { mapEntryTypeBack($0) })
    }

    private func mapAddress(_ adr: VCardModule.VCard.Address) -> ProfileInfo.AddressEntry {
        ProfileInfo.AddressEntry(
            street: adr.street,
            locality: adr.locality,
            region: adr.region,
            postalCode: adr.postalCode,
            country: adr.country,
            types: adr.types.map { mapEntryType($0) }
        )
    }

    private func mapAddressBack(_ entry: ProfileInfo.AddressEntry) -> VCardModule.VCard.Address {
        VCardModule.VCard.Address(
            street: entry.street,
            locality: entry.locality,
            region: entry.region,
            postalCode: entry.postalCode,
            country: entry.country,
            types: entry.types.map { mapEntryTypeBack($0) }
        )
    }
}

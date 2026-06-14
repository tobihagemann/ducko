import DuckoCore
import Logging
import SwiftUI

private let log = Logger(label: "im.ducko.ui.contactinfo")

@MainActor @Observable
public final class ContactInfoWindowState {
    let ref: ContactInfoRef
    var contact: Contact?
    var profile: ProfileInfo?
    var isLoadingProfile = false
    var profileError: String?
    var nickname = ""

    private let environment: AppEnvironment

    init(ref: ContactInfoRef, environment: AppEnvironment) {
        self.ref = ref
        self.environment = environment
    }

    // MARK: - Computed

    var jid: String {
        ref.jid
    }

    var displayName: String {
        contact?.displayName ?? ref.jid
    }

    private var presence: PresenceService.PresenceStatus? {
        contact.flatMap { environment.presenceService.contactPresences[$0.jid] }
    }

    var presenceDisplay: ContactPresenceDisplay {
        guard let contact else { return .unknown }
        return ContactPresenceDisplay.resolve(
            subscription: contact.subscription,
            presence: presence,
            isPending: contact.isPendingSubscription
        )
    }

    var statusMessage: String? {
        contact.flatMap { environment.presenceService.statusMessage(for: $0.jid) }
    }

    /// True when we don't receive this contact's presence (`none`/`from`), so the view
    /// can offer a "Request presence" affordance.
    var canRequestPresence: Bool {
        guard let subscription = contact?.subscription else { return true }
        switch subscription {
        case .none, .from: return true
        case .to, .both: return false
        }
    }

    // MARK: - Lifecycle

    func load() async {
        refreshContact()
        nickname = contact?.localAlias ?? ""

        isLoadingProfile = true
        profileError = nil
        defer { isLoadingProfile = false }

        do {
            profile = try await environment.profileService.fetchProfile(for: ref.jid, accountID: ref.accountID)
        } catch {
            profileError = error.localizedDescription
            // Keep the JID-bearing error at debug; warning logs must stay free of JIDs.
            log.warning("Failed to fetch peer profile")
            log.debug("Peer profile fetch error: \(error)")
        }
    }

    private func refreshContact() {
        contact = environment.rosterService.contact(jidString: ref.jid, accountID: ref.accountID)
    }

    // MARK: - Actions

    func rename() async {
        guard let contact else { return }
        try? await environment.rosterService.renameContact(contact, newAlias: nickname, accountID: ref.accountID)
        refreshContact()
    }

    func requestPresence() async {
        try? await environment.rosterService.requestSubscription(jidString: ref.jid, accountID: ref.accountID)
    }

    func toggleBlock() async {
        guard let contact else { return }
        if contact.isBlocked {
            try? await environment.rosterService.unblockContact(jidString: ref.jid, accountID: ref.accountID)
        } else {
            try? await environment.rosterService.blockContact(jidString: ref.jid, accountID: ref.accountID)
        }
        refreshContact()
    }

    func remove() async {
        guard let contact else { return }
        try? await environment.rosterService.removeContact(contact, accountID: ref.accountID)
        refreshContact()
    }
}

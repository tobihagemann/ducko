import Foundation
import DuckoXMPP

@MainActor @Observable
public final class PresenceService {
    public var myPresence: PresenceStatus = .available
    public var myStatusMessage: String?
    public private(set) var contactPresences: [BareJID: PresenceStatus] = [:]

    public enum PresenceStatus: String, Sendable {
        case available, away, xa, dnd, offline
    }

    public init() {}

    public func setPresence(_ status: PresenceStatus, message: String?) {
        myPresence = status
        myStatusMessage = message
    }

    public func goOnline() {
        myPresence = .available
    }

    public func goOffline() {
        myPresence = .offline
    }

    // MARK: - Event Handling

    func handleEvent(_ event: XMPPEvent, accountID: UUID) {
        // Stub — will be fleshed out with PresenceModule in a future prompt.
    }

    // MARK: - Idle Monitoring

    /// Opt-in idle monitoring (GUI calls this, CLI doesn't).
    public func startIdleMonitoring() {
        // Stub — will use IOKit/CGEventSource in a future prompt.
    }
}

import DuckoCore

/// Summarizes the enabled accounts' displayed presences (`PresenceService.displayedPresences()`) for the status menus.
enum StatusSummary {
    typealias Presences = [(status: PresenceService.PresenceStatus, message: String?)]

    /// The shown account's status, or its message when set, followed by counts of the accounts showing another
    /// status, e.g. "Available · 2 Offline".
    static func label(for presence: (status: PresenceService.PresenceStatus, message: String?), presences: Presences) -> String {
        var base = presence.status.displayName
        if let message = presence.message, !message.isEmpty {
            base = message
        }
        let others = PresenceService.PresenceStatus.allCases.compactMap { status -> String? in
            let count = presences.count { $0.status == status }
            guard status != presence.status, count > 0 else { return nil }
            return "\(count) \(status.displayName)"
        }
        return others.isEmpty ? base : "\(base) · \(others.joined(separator: ", "))"
    }

    /// Checked when every enabled account shows `status`, mixed when only some do.
    static func mark(for status: PresenceService.PresenceStatus, presences: Presences) -> MenuStatusRow.Mark {
        mark(matching: presences.count { $0.status == status }, of: presences.count)
    }

    /// Checked when every enabled account shows `status` with `message`, mixed when only some do.
    static func mark(for status: PresenceService.PresenceStatus, message: String, presences: Presences) -> MenuStatusRow.Mark {
        mark(matching: presences.count { $0.status == status && $0.message == message }, of: presences.count)
    }

    private static func mark(matching count: Int, of total: Int) -> MenuStatusRow.Mark {
        if count == 0 { return .none }
        return count == total ? .checked : .mixed
    }
}

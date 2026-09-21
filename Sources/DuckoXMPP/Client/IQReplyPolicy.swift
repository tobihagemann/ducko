/// Decides whether an inbound IQ answers a pending request.
///
/// Only `result` and `error` answer a request.
///
/// A request with no `to`, or one addressed to the account's own bare JID, is account-scoped. The server answers
/// stanzas it handles on the account's behalf with no `from` or the account's bare JID (RFC 6120 §8.1.2.1, e.g.
/// Prosody `mod_pep`). An error the server raises itself comes from the server's domain.
///
/// Any other request is answered only from exactly the JID it addressed, resource included, since an error bounce
/// echoes the original `to` as its `from` (RFC 6120 §8.3.1).
enum IQReplyPolicy {
    static func accepts(reply: XMPPIQ, requestTo: JID?, ownJID: FullJID?) -> Bool {
        guard reply.isResult || reply.isError, let ownJID else { return false }
        let from: JID?
        if let rawFrom = reply.element.attribute("from") {
            guard let parsed = JID.parse(rawFrom) else { return false }
            from = parsed
        } else {
            from = nil
        }
        let ownBare = ownJID.bareJID
        if let requestTo, requestTo != .bare(ownBare) {
            return from == requestTo
        }
        switch from {
        case .none:
            return true
        case let .bare(bare):
            if bare == ownBare { return true }
            return reply.isError && bare.localPart == nil && bare.domainPart == ownBare.domainPart
        case .full:
            return false
        }
    }
}

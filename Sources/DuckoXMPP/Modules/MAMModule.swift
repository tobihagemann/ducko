import os

private let log = Logger(subsystem: "com.ducko.xmpp", category: "mam")

/// Implements XEP-0313 Message Archive Management — queries the server
/// for archived messages with pagination support.
public final class MAMModule: XMPPModule, Sendable {
    // MARK: - Types

    /// Three-state RSM `<before>` semantics.
    public enum RSMBefore: Sendable {
        /// No `<before>` element — page forward from the start (default).
        case omitted
        /// Empty `<before/>` — requests the last page of results.
        case lastPage
        /// `<before>ID</before>` — page backward from the given item ID.
        case id(String)
    }

    /// Query parameters for `queryMessages`.
    public struct Query: Sendable {
        public let to: BareJID?
        public let with: BareJID?
        public let start: String?
        public let end: String?
        public let before: RSMBefore
        public let after: String?
        public let max: Int?
        public let afterID: String?
        public let beforeID: String?
        public let flipPage: Bool

        public init(
            to: BareJID? = nil,
            with: BareJID? = nil,
            start: String? = nil,
            end: String? = nil,
            before: RSMBefore = .omitted,
            after: String? = nil,
            max: Int? = nil,
            afterID: String? = nil,
            beforeID: String? = nil,
            flipPage: Bool = false
        ) {
            self.to = to
            self.with = with
            self.start = start
            self.end = end
            self.before = before
            self.after = after
            self.max = max
            self.afterID = afterID
            self.beforeID = beforeID
            self.flipPage = flipPage
        }
    }

    // MARK: - State

    private struct State {
        var context: ModuleContext?
        var activeQueries: [String: [ArchivedMessage]] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>

    public init() {
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
    }

    // MARK: - Lifecycle

    public func handleDisconnect() async {
        state.withLock { $0.activeQueries.removeAll() }
    }

    // MARK: - Message Handling

    public func handleMessage(_ message: XMPPMessage) throws {
        guard let result = message.element.child(named: "result", namespace: XMPPNamespaces.mam),
              let queryID = result.attribute("queryid") else {
            return
        }

        guard let archived = ArchivedMessage.parse(result) else {
            log.warning("Failed to parse MAM result")
            return
        }

        let appended = state.withLock { state -> Bool in
            guard state.activeQueries[queryID] != nil else { return false }
            state.activeQueries[queryID]?.append(archived)
            return true
        }
        if !appended {
            log.debug("Ignoring MAM result for unregistered query: \(queryID)")
        }
    }

    // MARK: - Public API

    /// Queries the message archive with optional filters, extended fields, and pagination.
    /// For MUC room archives, set `to` to the room's bare JID.
    public func queryMessages(_ query: Query = Query()) async throws -> (messages: [ArchivedMessage], fin: MAMFin) {
        guard let context = state.withLock({ $0.context }) else {
            return ([], MAMFin(complete: true, first: nil, last: nil, count: nil))
        }

        let queryID = context.generateID()

        // Register the query before sending; defer ensures cleanup on failure
        state.withLock { $0.activeQueries[queryID] = [] }
        defer { state.withLock { _ = $0.activeQueries.removeValue(forKey: queryID) } }

        // Build IQ
        var iq = XMPPIQ(type: .set, id: context.generateID())
        if let to = query.to { iq.to = .bare(to) }
        var queryElement = XMLElement(name: "query", namespace: XMPPNamespaces.mam, attributes: ["queryid": queryID])

        if let form = Self.buildFilterForm(jid: query.with, start: query.start, end: query.end) {
            queryElement.addChild(form)
        }
        if let extForm = Self.buildExtendedForm(afterID: query.afterID, beforeID: query.beforeID, flipPage: query.flipPage) {
            queryElement.addChild(extForm)
        }
        if let rsm = Self.buildRSM(max: query.max, before: query.before, after: query.after) {
            queryElement.addChild(rsm)
        }

        iq.element.addChild(queryElement)

        // Send and await the <fin> element (returned as IQ result child)
        let finElement = try await context.sendIQ(iq)

        // Collect accumulated results
        let messages = state.withLock { state -> [ArchivedMessage] in
            return state.activeQueries.removeValue(forKey: queryID) ?? []
        }

        // Parse fin
        let fin: MAMFin = if let finElement, let parsed = MAMFin.parse(finElement) {
            parsed
        } else {
            MAMFin(complete: true, first: nil, last: nil, count: nil)
        }

        context.emitEvent(.archivedMessagesLoaded(messages, fin: fin))

        return (messages, fin)
    }

    /// Backward-compatible overload with individual parameters.
    /// Does not support `.lastPage` or extended fields; use the `Query`-based overload for those.
    public func queryMessages(
        to: BareJID? = nil,
        with jid: BareJID? = nil,
        start: String? = nil,
        end: String? = nil,
        before: String? = nil,
        after: String? = nil,
        max: Int? = nil
    ) async throws -> (messages: [ArchivedMessage], fin: MAMFin) {
        let rsmBefore: RSMBefore = if let before { .id(before) } else { .omitted }
        return try await queryMessages(Query(
            to: to, with: jid, start: start, end: end,
            before: rsmBefore, after: after, max: max
        ))
    }

    // MARK: - Private

    private static func buildFilterForm(jid: BareJID?, start: String?, end: String?) -> XMLElement? {
        guard jid != nil || start != nil || end != nil else { return nil }

        var fields: [DataFormField] = [
            DataFormField(variable: "FORM_TYPE", type: "hidden", values: [XMPPNamespaces.mam])
        ]
        if let jid { fields.append(DataFormField(variable: "with", values: [jid.description])) }
        if let start { fields.append(DataFormField(variable: "start", values: [start])) }
        if let end { fields.append(DataFormField(variable: "end", values: [end])) }

        return buildSubmitForm(fields)
    }

    private static func buildExtendedForm(afterID: String?, beforeID: String?, flipPage: Bool) -> XMLElement? {
        guard afterID != nil || beforeID != nil || flipPage else { return nil }

        var fields: [DataFormField] = [
            DataFormField(variable: "FORM_TYPE", type: "hidden", values: [XMPPNamespaces.mamExtended])
        ]
        if let afterID { fields.append(DataFormField(variable: "after-id", values: [afterID])) }
        if let beforeID { fields.append(DataFormField(variable: "before-id", values: [beforeID])) }
        if flipPage { fields.append(DataFormField(variable: "flip-page", values: ["true"])) }

        return buildSubmitForm(fields)
    }

    private static func buildRSM(max: Int?, before: RSMBefore, after: String?) -> XMLElement? {
        let hasBefore = switch before {
        case .omitted: false
        case .lastPage, .id: true
        }
        guard max != nil || hasBefore || after != nil else { return nil }

        var rsm = XMLElement(name: "set", namespace: XMPPNamespaces.rsm)

        if let max {
            var maxElement = XMLElement(name: "max")
            maxElement.addText(String(max))
            rsm.addChild(maxElement)
        }
        switch before {
        case .omitted:
            break
        case .lastPage:
            rsm.addChild(XMLElement(name: "before"))
        case let .id(id):
            var beforeElement = XMLElement(name: "before")
            beforeElement.addText(id)
            rsm.addChild(beforeElement)
        }
        if let after {
            var afterElement = XMLElement(name: "after")
            afterElement.addText(after)
            rsm.addChild(afterElement)
        }

        return rsm
    }
}

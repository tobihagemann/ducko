import os

private let log = Logger(subsystem: "com.ducko.xmpp", category: "mam")

/// Implements XEP-0313 Message Archive Management — queries the server
/// for archived messages with pagination support.
public final class MAMModule: XMPPModule, Sendable {
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

    /// Queries the message archive with optional filters and pagination.
    public func queryMessages(
        with jid: BareJID? = nil,
        start: String? = nil,
        end: String? = nil,
        before: String? = nil,
        after: String? = nil,
        max: Int? = nil
    ) async throws -> (messages: [ArchivedMessage], fin: MAMFin) {
        guard let context = state.withLock({ $0.context }) else {
            return ([], MAMFin(complete: true, first: nil, last: nil, count: nil))
        }

        let queryID = context.generateID()

        // Register the query before sending; defer ensures cleanup on failure
        state.withLock { $0.activeQueries[queryID] = [] }
        defer { state.withLock { _ = $0.activeQueries.removeValue(forKey: queryID) } }

        // Build IQ
        var iq = XMPPIQ(type: .set, id: context.generateID())
        var query = XMLElement(name: "query", namespace: XMPPNamespaces.mam, attributes: ["queryid": queryID])

        if let form = Self.buildFilterForm(jid: jid, start: start, end: end) {
            query.addChild(form)
        }
        if let rsm = Self.buildRSM(max: max, before: before, after: after) {
            query.addChild(rsm)
        }

        iq.element.addChild(query)

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

    // MARK: - Private

    private static func buildFilterForm(jid: BareJID?, start: String?, end: String?) -> XMLElement? {
        guard jid != nil || start != nil || end != nil else { return nil }

        var form = XMLElement(name: "x", namespace: "jabber:x:data", attributes: ["type": "submit"])

        var formTypeField = XMLElement(name: "field", attributes: ["var": "FORM_TYPE", "type": "hidden"])
        var formTypeValue = XMLElement(name: "value")
        formTypeValue.addText(XMPPNamespaces.mam)
        formTypeField.addChild(formTypeValue)
        form.addChild(formTypeField)

        if let jid { form.addChild(Self.formField(name: "with", value: jid.description)) }
        if let start { form.addChild(Self.formField(name: "start", value: start)) }
        if let end { form.addChild(Self.formField(name: "end", value: end)) }

        return form
    }

    private static func formField(name: String, value: String) -> XMLElement {
        var field = XMLElement(name: "field", attributes: ["var": name])
        var valueElement = XMLElement(name: "value")
        valueElement.addText(value)
        field.addChild(valueElement)
        return field
    }

    private static func buildRSM(max: Int?, before: String?, after: String?) -> XMLElement? {
        guard max != nil || before != nil || after != nil else { return nil }

        var rsm = XMLElement(name: "set", namespace: XMPPNamespaces.rsm)

        if let max {
            var maxElement = XMLElement(name: "max")
            maxElement.addText(String(max))
            rsm.addChild(maxElement)
        }
        if let before {
            var beforeElement = XMLElement(name: "before")
            beforeElement.addText(before)
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

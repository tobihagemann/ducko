import Testing
@testable import DuckoXMPP

private let ownJID = FullJID.parse("user@example.com/ducko")!

struct ReplyCase: Sendable, CustomTestStringConvertible {
    let to: String?
    let type: XMPPIQ.IQType
    let from: String?
    let accepts: Bool

    var testDescription: String {
        "\(type.rawValue) from \(from ?? "absent") to \(to ?? "absent") is \(accepts ? "accepted" : "rejected")"
    }

    enum Accepted {
        case neither, errorOnly, both
    }

    /// One case per reply type for each `(from, accepted)` row.
    static func table(to: String?, _ rows: [(String?, Accepted)]) -> [ReplyCase] {
        rows.flatMap { from, accepted in
            [
                ReplyCase(to: to, type: .result, from: from, accepts: accepted == .both),
                ReplyCase(to: to, type: .error, from: from, accepts: accepted != .neither)
            ]
        }
    }
}

private let accountScopedRows: [(String?, ReplyCase.Accepted)] = [
    (nil, .both),
    ("bad@@example.com", .neither),
    ("user@example.com", .both),
    ("user@example.com/ducko", .neither),
    ("example.com", .errorOnly),
    ("other@example.com", .neither)
]

private let replyCases: [ReplyCase] = ReplyCase.table(to: nil, accountScopedRows)
    + ReplyCase.table(to: "user@example.com", accountScopedRows)
    + ReplyCase.table(to: "example.com", [
        (nil, .neither),
        ("bad@@example.com", .neither),
        ("user@example.com", .neither),
        ("user@example.com/ducko", .neither),
        ("example.com", .both),
        ("other.example.com", .neither)
    ])
    + ReplyCase.table(to: "peer@example.com", [
        (nil, .neither),
        ("bad@@example.com", .neither),
        ("user@example.com", .neither),
        ("user@example.com/ducko", .neither),
        ("example.com", .neither),
        ("peer@example.com", .both),
        ("peer@example.com/res", .neither),
        ("other@example.com", .neither)
    ])
    + ReplyCase.table(to: "peer@example.com/res", [
        (nil, .neither),
        ("bad@@example.com", .neither),
        ("user@example.com", .neither),
        ("user@example.com/ducko", .neither),
        ("example.com", .neither),
        ("peer@example.com/res", .both),
        ("peer@example.com", .neither),
        ("peer@example.com/other", .neither),
        ("other@example.com", .neither)
    ])
    + ReplyCase.table(to: "user@example.com/ducko", [
        (nil, .neither),
        ("user@example.com", .neither),
        ("example.com", .neither),
        ("user@example.com/ducko", .both)
    ])

private func reply(type: XMPPIQ.IQType, from: String?) -> XMPPIQ {
    var iq = XMPPIQ(type: type, id: "reply")
    iq.element.attributes["from"] = from
    return iq
}

struct IQReplyPolicyTests {
    @Test(arguments: replyCases)
    func `reply matrix`(replyCase: ReplyCase) throws {
        let requestTo = try replyCase.to.map { try #require(JID.parse($0)) }
        let accepted = IQReplyPolicy.accepts(reply: reply(type: replyCase.type, from: replyCase.from), requestTo: requestTo, ownJID: ownJID)
        #expect(accepted == replyCase.accepts)
    }

    @Test(arguments: [XMPPIQ.IQType.get, .set])
    func `request stanzas never answer a request`(type: XMPPIQ.IQType) {
        #expect(!IQReplyPolicy.accepts(reply: reply(type: type, from: nil), requestTo: nil, ownJID: ownJID))
    }

    @Test
    func `an unbound account accepts no reply`() {
        #expect(!IQReplyPolicy.accepts(reply: reply(type: .result, from: nil), requestTo: nil, ownJID: nil))
    }
}

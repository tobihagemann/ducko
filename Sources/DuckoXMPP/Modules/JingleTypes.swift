/// Jingle action per XEP-0166 §7.
enum JingleAction: String {
    case sessionInitiate = "session-initiate"
    case sessionAccept = "session-accept"
    case sessionTerminate = "session-terminate"
    case transportInfo = "transport-info"
    case transportReplace = "transport-replace"
    case transportAccept = "transport-accept"
    case transportReject = "transport-reject"
    case sessionInfo = "session-info"
    case contentAdd = "content-add"
    case contentAccept = "content-accept"
    case contentReject = "content-reject"
    case contentRemove = "content-remove"
}

/// Reason for terminating a Jingle session per XEP-0166 §7.4.
public enum JingleTerminateReason: String, Sendable {
    case success
    case decline
    case cancel
    case busy
    case timeout
    case connectivityError = "connectivity-error"
    case failedTransport = "failed-transport"
}

/// Senders attribute on a Jingle content element per XEP-0166 §7.3.
/// Controls which party sends media/file data within the content.
public enum JingleContentSenders: String, Sendable {
    case none
    case initiator
    case responder
    case both
}

/// Range element for partial file transfers per XEP-0234 §6.
public struct JingleFileRange: Sendable, Hashable {
    public let offset: Int64?
    public let length: Int64?

    public init(offset: Int64? = nil, length: Int64? = nil) {
        self.offset = offset
        self.length = length
    }

    /// Parses from a `<range/>` element.
    public init?(from element: XMLElement) {
        guard element.name == "range" else { return nil }
        self.offset = element.attribute("offset").flatMap(Int64.init)
        self.length = element.attribute("length").flatMap(Int64.init)
    }

    /// Serializes to a `<range/>` element.
    public func toXML() -> XMLElement {
        var attributes: [String: String] = [:]
        if let offset { attributes["offset"] = String(offset) }
        if let length { attributes["length"] = String(length) }
        return XMLElement(name: "range", attributes: attributes)
    }
}

/// File description inside a Jingle content element per XEP-0234.
public struct JingleFileDescription: Sendable, Hashable {
    public let name: String
    public let size: Int64
    public let mediaType: String?
    public let hash: String?
    public let date: String?
    public let desc: String?
    public let range: JingleFileRange?

    public init(
        name: String, size: Int64, mediaType: String? = nil, hash: String? = nil,
        date: String? = nil, desc: String? = nil, range: JingleFileRange? = nil
    ) {
        self.name = name
        self.size = size
        self.mediaType = mediaType
        self.hash = hash
        self.date = date
        self.desc = desc
        self.range = range
    }

    /// Parses from a `<description xmlns='...file-transfer:5'>` element.
    public init?(from element: XMLElement) {
        guard element.name == "description",
              element.namespace == XMPPNamespaces.jingleFileTransfer,
              let file = element.child(named: "file"),
              let name = file.childText(named: "name"),
              let sizeText = file.childText(named: "size"),
              let size = Int64(sizeText) else { return nil }

        self.name = Self.sanitizeFileName(name)
        self.size = size
        self.mediaType = file.childText(named: "media-type")
        self.hash = file.child(named: "hash")?.textContent
        self.date = file.childText(named: "date")
        self.desc = file.childText(named: "desc")
        self.range = file.child(named: "range").flatMap(JingleFileRange.init(from:))
    }

    /// Serializes to a `<description>` element containing a `<file>`.
    public func toXML() -> XMLElement {
        var file = XMLElement(name: "file")
        file.setChildText(named: "name", to: name)
        file.setChildText(named: "size", to: String(size))
        if let mediaType {
            file.setChildText(named: "media-type", to: mediaType)
        }
        if let hash {
            var hashElement = XMLElement(name: "hash", namespace: "urn:xmpp:hashes:2", attributes: ["algo": "sha-256"])
            hashElement.addText(hash)
            file.addChild(hashElement)
        }
        if let date {
            file.setChildText(named: "date", to: date)
        }
        if let desc {
            file.setChildText(named: "desc", to: desc)
        }
        if let range {
            file.addChild(range.toXML())
        }

        var description = XMLElement(name: "description", namespace: XMPPNamespaces.jingleFileTransfer)
        description.addChild(file)
        return description
    }

    /// Strips path components from a filename to prevent directory traversal (XEP-0234 §9).
    static func sanitizeFileName(_ name: String) -> String {
        var result = name
        if let lastSlash = result.lastIndex(of: "/") {
            result = String(result[result.index(after: lastSlash)...])
        }
        if let lastBackslash = result.lastIndex(of: "\\") {
            result = String(result[result.index(after: lastBackslash)...])
        }
        if result.isEmpty || result == "." || result == ".." {
            result = "unnamed"
        }
        return result
    }
}

/// SOCKS5 Bytestreams transport per XEP-0260.
public struct SOCKS5Transport: Sendable, Hashable {
    public let sid: String
    public let candidates: [Candidate]

    public init(sid: String, candidates: [Candidate] = []) {
        self.sid = sid
        self.candidates = candidates
    }

    /// A SOCKS5 transport candidate.
    public struct Candidate: Sendable, Hashable {
        public let cid: String
        public let host: String
        public let port: UInt16
        public let jid: String
        public let priority: UInt32
        public let type: CandidateType

        public init(cid: String, host: String, port: UInt16, jid: String, priority: UInt32, type: CandidateType) {
            self.cid = cid
            self.host = host
            self.port = port
            self.jid = jid
            self.priority = priority
            self.type = type
        }
    }

    /// SOCKS5 candidate type.
    public enum CandidateType: String, Sendable, Hashable {
        case direct
        case proxy
    }

    /// Parses from a `<transport xmlns='...s5b:1'>` element.
    public init?(from element: XMLElement) {
        guard element.name == "transport",
              element.namespace == XMPPNamespaces.jingleS5B,
              let sid = element.attribute("sid") else { return nil }

        self.sid = sid
        self.candidates = element.children(named: "candidate").compactMap { candidate in
            guard let cid = candidate.attribute("cid"),
                  let host = candidate.attribute("host"),
                  let portStr = candidate.attribute("port"),
                  let port = UInt16(portStr),
                  let jid = candidate.attribute("jid"),
                  let priorityStr = candidate.attribute("priority"),
                  let priority = UInt32(priorityStr) else { return nil }
            let type = candidate.attribute("type").flatMap(CandidateType.init(rawValue:)) ?? .direct
            return Candidate(cid: cid, host: host, port: port, jid: jid, priority: priority, type: type)
        }
    }

    /// Serializes to a `<transport>` element.
    public func toXML() -> XMLElement {
        var transport = XMLElement(name: "transport", namespace: XMPPNamespaces.jingleS5B, attributes: ["sid": sid])
        for candidate in candidates {
            let candidateElement = XMLElement(
                name: "candidate",
                attributes: [
                    "cid": candidate.cid,
                    "host": candidate.host,
                    "jid": candidate.jid,
                    "port": String(candidate.port),
                    "priority": String(candidate.priority),
                    "type": candidate.type.rawValue
                ]
            )
            transport.addChild(candidateElement)
        }
        return transport
    }
}

/// In-Band Bytestreams transport per XEP-0261.
public struct IBBTransport: Sendable, Hashable {
    public let sid: String
    public let blockSize: Int

    public init(sid: String, blockSize: Int) {
        self.sid = sid
        self.blockSize = blockSize
    }

    /// Parses from a `<transport xmlns='...ibb:1'>` element.
    public init?(from element: XMLElement) {
        guard element.name == "transport",
              element.namespace == XMPPNamespaces.jingleIBB,
              let sid = element.attribute("sid"),
              let blockSizeStr = element.attribute("block-size"),
              let blockSize = Int(blockSizeStr) else { return nil }

        self.sid = sid
        self.blockSize = blockSize
    }

    /// Serializes to a `<transport>` element.
    public func toXML() -> XMLElement {
        XMLElement(
            name: "transport",
            namespace: XMPPNamespaces.jingleIBB,
            attributes: ["sid": sid, "block-size": String(blockSize)]
        )
    }
}

/// Transport description for a Jingle content element.
public enum JingleTransportDescription: Sendable, Hashable {
    case socks5(SOCKS5Transport)
    case ibb(IBBTransport)

    /// Detects transport type by namespace and parses accordingly.
    public static func parse(from element: XMLElement) -> JingleTransportDescription? {
        switch element.namespace {
        case XMPPNamespaces.jingleS5B:
            if let transport = SOCKS5Transport(from: element) {
                return .socks5(transport)
            }
        case XMPPNamespaces.jingleIBB:
            if let transport = IBBTransport(from: element) {
                return .ibb(transport)
            }
        default:
            break
        }
        return nil
    }

    /// Serializes to the appropriate transport XML element.
    public func toXML() -> XMLElement {
        switch self {
        case let .socks5(transport): transport.toXML()
        case let .ibb(transport): transport.toXML()
        }
    }
}

/// A Jingle content element containing file description and transport.
struct JingleContent {
    let name: String
    let creator: String
    let senders: JingleContentSenders?
    let description: JingleFileDescription
    let transport: JingleTransportDescription

    /// The effective senders value, defaulting to `.both` when not explicitly set.
    var effectiveSenders: JingleContentSenders {
        senders ?? .both
    }

    init(
        name: String, creator: String, senders: JingleContentSenders? = nil,
        description: JingleFileDescription, transport: JingleTransportDescription
    ) {
        self.name = name
        self.creator = creator
        self.senders = senders
        self.description = description
        self.transport = transport
    }

    /// Parses from a `<content>` element.
    init?(from element: XMLElement) {
        guard element.name == "content",
              let name = element.attribute("name"),
              let creator = element.attribute("creator") else { return nil }

        guard let descElement = element.child(named: "description", namespace: XMPPNamespaces.jingleFileTransfer),
              let description = JingleFileDescription(from: descElement) else { return nil }

        guard let transportElement = element.child(named: "transport"),
              let transport = JingleTransportDescription.parse(from: transportElement) else { return nil }

        self.name = name
        self.creator = creator
        self.senders = element.attribute("senders").flatMap(JingleContentSenders.init(rawValue:))
        self.description = description
        self.transport = transport
    }

    /// Serializes to a `<content>` element.
    func toXML() -> XMLElement {
        var attributes = ["creator": creator, "name": name]
        if let senders {
            attributes["senders"] = senders.rawValue
        }
        var content = XMLElement(name: "content", attributes: attributes)
        content.addChild(description.toXML())
        content.addChild(transport.toXML())
        return content
    }
}

/// IBB session state for tracking in-band data transfer.
struct IBBSessionState {
    let ibbSID: String
    let blockSize: Int
    var receivedData: [UInt8] = []
    var nextExpectedSeq: UInt16 = 0
    let expectedSize: Int64
    var hasOpened: Bool = false
}

/// Transport connection state within a Jingle session.
enum TransportState {
    case pending
    case connecting
    case connected(candidateCID: String)
    case failed
    case replacePending
}

/// State of a Jingle session.
struct JingleSession {
    let peer: FullJID
    let role: Role
    var transportState: TransportState
    let primaryContentName: String
    var contents: [String: JingleContent]

    /// The primary content — deterministic lookup by name.
    var content: JingleContent {
        // swiftlint:disable:next force_unwrapping
        contents[primaryContentName]!
    }

    /// Whether this side initiated or is responding.
    enum Role {
        case initiator
        case responder
    }

    init(
        peer: FullJID,
        role: Role,
        transportState: TransportState = .pending,
        content: JingleContent
    ) {
        self.peer = peer
        self.role = role
        self.transportState = transportState
        self.primaryContentName = content.name
        self.contents = [content.name: content]
    }
}

/// Simplified file offer for event consumers.
public struct JingleFileOffer: Sendable {
    public let sid: String
    public let from: FullJID
    public let fileName: String
    public let fileSize: Int64
    public let mediaType: String?

    public init(sid: String, from: FullJID, fileName: String, fileSize: Int64, mediaType: String? = nil) {
        self.sid = sid
        self.from = from
        self.fileName = fileName
        self.fileSize = fileSize
        self.mediaType = mediaType
    }
}

/// A file request from a peer via session-initiate with senders='responder'.
/// The peer is the initiator but wants us (the responder) to send data.
public struct JingleFileRequest: Sendable {
    public let sid: String
    public let from: FullJID
    public let fileDescription: JingleFileDescription

    public init(sid: String, from: FullJID, fileDescription: JingleFileDescription) {
        self.sid = sid
        self.from = from
        self.fileDescription = fileDescription
    }
}

/// Parsed checksum from a session-info per XEP-0234 §5.
public struct JingleChecksumInfo: Sendable {
    public let contentName: String
    public let algo: String
    public let hash: String

    public init(contentName: String, algo: String, hash: String) {
        self.contentName = contentName
        self.algo = algo
        self.hash = hash
    }
}

/// Jingle action per XEP-0166 §7.
public enum JingleAction: String, Sendable {
    case sessionInitiate = "session-initiate"
    case sessionAccept = "session-accept"
    case sessionTerminate = "session-terminate"
    case transportInfo = "transport-info"
    case transportReplace = "transport-replace"
    case transportAccept = "transport-accept"
    case transportReject = "transport-reject"
    case sessionInfo = "session-info"
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

/// File description inside a Jingle content element per XEP-0234.
public struct JingleFileDescription: Sendable, Hashable {
    public let name: String
    public let size: Int64
    public let mediaType: String?
    public let hash: String?
    public let date: String?

    public init(name: String, size: Int64, mediaType: String? = nil, hash: String? = nil, date: String? = nil) {
        self.name = name
        self.size = size
        self.mediaType = mediaType
        self.hash = hash
        self.date = date
    }

    /// Parses from a `<description xmlns='...file-transfer:5'>` element.
    public init?(from element: XMLElement) {
        guard element.name == "description",
              element.namespace == XMPPNamespaces.jingleFileTransfer,
              let file = element.child(named: "file"),
              let name = file.childText(named: "name"),
              let sizeText = file.childText(named: "size"),
              let size = Int64(sizeText) else { return nil }

        self.name = name
        self.size = size
        self.mediaType = file.childText(named: "media-type")
        self.hash = file.child(named: "hash")?.textContent
        self.date = file.childText(named: "date")
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

        var description = XMLElement(name: "description", namespace: XMPPNamespaces.jingleFileTransfer)
        description.addChild(file)
        return description
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
public struct JingleContent: Sendable {
    public let name: String
    public let creator: String
    public let description: JingleFileDescription
    public let transport: JingleTransportDescription

    public init(name: String, creator: String, description: JingleFileDescription, transport: JingleTransportDescription) {
        self.name = name
        self.creator = creator
        self.description = description
        self.transport = transport
    }

    /// Parses from a `<content>` element.
    public init?(from element: XMLElement) {
        guard element.name == "content",
              let name = element.attribute("name"),
              let creator = element.attribute("creator") else { return nil }

        guard let descElement = element.child(named: "description", namespace: XMPPNamespaces.jingleFileTransfer),
              let description = JingleFileDescription(from: descElement) else { return nil }

        guard let transportElement = element.child(named: "transport"),
              let transport = JingleTransportDescription.parse(from: transportElement) else { return nil }

        self.name = name
        self.creator = creator
        self.description = description
        self.transport = transport
    }

    /// Serializes to a `<content>` element.
    public func toXML() -> XMLElement {
        var content = XMLElement(name: "content", attributes: ["creator": creator, "name": name])
        content.addChild(description.toXML())
        content.addChild(transport.toXML())
        return content
    }
}

/// State of a Jingle session.
public struct JingleSession: Sendable {
    public let sid: String
    public let peer: FullJID
    public let role: Role
    public var state: State
    public let content: JingleContent

    /// Whether this side initiated or is responding.
    public enum Role: Sendable {
        case initiator
        case responder
    }

    /// Session lifecycle state.
    public enum State: Sendable {
        case pending
        case active
        case terminated
    }

    public init(sid: String, peer: FullJID, role: Role, state: State, content: JingleContent) {
        self.sid = sid
        self.peer = peer
        self.role = role
        self.state = state
        self.content = content
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

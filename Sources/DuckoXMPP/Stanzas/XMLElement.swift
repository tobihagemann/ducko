/// Lightweight XML element type for XMPP stanza representation.
struct XMLElement: Hashable, Sendable {
    var name: String
    var namespace: String?
    var attributes: [String: String]
    var children: [Node]

    enum Node: Hashable, Sendable {
        case text(String)
        case element(XMLElement)
    }

    init(name: String, namespace: String? = nil, attributes: [String: String] = [:], children: [Node] = []) {
        self.name = name
        self.namespace = namespace
        self.attributes = attributes
        self.children = children
    }

    // MARK: - Attribute Lookup

    func attribute(_ name: String) -> String? {
        attributes[name]
    }

    // MARK: - Child Lookup

    func child(named name: String) -> XMLElement? {
        for case .element(let child) in children where child.name == name {
            return child
        }
        return nil
    }

    func child(named name: String, namespace: String) -> XMLElement? {
        for case .element(let child) in children where child.name == name && child.namespace == namespace {
            return child
        }
        return nil
    }

    func children(named name: String) -> [XMLElement] {
        children.compactMap { node in
            guard case .element(let child) = node, child.name == name else { return nil }
            return child
        }
    }

    // MARK: - Text Content

    /// Concatenated text of all direct text nodes.
    var textContent: String? {
        let text = children.compactMap { node -> String? in
            guard case .text(let value) = node else { return nil }
            return value
        }.joined()
        return text.isEmpty ? nil : text
    }

    // MARK: - Mutation

    mutating func addText(_ text: String) {
        children.append(.text(text))
    }

    mutating func addChild(_ element: XMLElement) {
        children.append(.element(element))
    }

    mutating func setAttribute(_ name: String, value: String) {
        attributes[name] = value
    }

    // MARK: - Child Text Helpers

    /// Returns the text content of the first child element with the given name.
    func childText(named name: String) -> String? {
        child(named: name)?.textContent
    }

    /// Replaces the text content of a named child element. Removes the child if `value` is `nil`.
    mutating func setChildText(named name: String, to value: String?) {
        children.removeAll { node in
            guard case .element(let child) = node else { return false }
            return child.name == name
        }
        if let value {
            var child = XMLElement(name: name)
            child.addText(value)
            children.append(.element(child))
        }
    }

    // MARK: - Serialization

    var xmlString: String {
        var result = "<\(name)"

        if let namespace {
            result += " xmlns=\"\(Self.escape(namespace))\""
        }

        for (key, value) in attributes.sorted(by: { $0.key < $1.key }) {
            result += " \(key)=\"\(Self.escape(value))\""
        }

        if children.isEmpty {
            result += "/>"
        } else {
            result += ">"
            for child in children {
                switch child {
                case .text(let text):
                    result += Self.escape(text)
                case .element(let element):
                    result += element.xmlString
                }
            }
            result += "</\(name)>"
        }

        return result
    }

    static func escape(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count)
        for char in string {
            switch char {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default: result.append(char)
            }
        }
        return result
    }
}

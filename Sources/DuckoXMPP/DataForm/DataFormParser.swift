/// A single field in a `jabber:x:data` form per XEP-0004.
public struct DataFormField: Sendable {
    public let variable: String
    public let type: String?
    public let label: String?
    public var values: [String]
    public let options: [(label: String?, value: String)]

    public init(
        variable: String,
        type: String? = nil,
        label: String? = nil,
        values: [String] = [],
        options: [(label: String?, value: String)] = []
    ) {
        self.variable = variable
        self.type = type
        self.label = label
        self.values = values
        self.options = options
    }

    /// XEP-0004 §3.2 FORM_TYPE header for a `pubsub#publish-options` submit form.
    ///
    /// Prosody and other servers silently drop the entire publish-options form
    /// when this header is missing, leaving PEP nodes with default access
    /// instead of the publisher's requested configuration.
    public static let pubsubPublishOptionsHeader = DataFormField(
        variable: "FORM_TYPE",
        type: "hidden",
        values: [XMPPNamespaces.pubsubPublishOptions]
    )
}

/// Parses a `<x xmlns='jabber:x:data'>` element into an array of ``DataFormField``.
func parseDataForm(_ element: XMLElement) -> [DataFormField] {
    guard element.name == "x",
          element.namespace == XMPPNamespaces.dataForms else { return [] }

    return element.children(named: "field").compactMap { field in
        guard let variable = field.attribute("var") else { return nil }

        let type = field.attribute("type")
        let label = field.attribute("label")
        let values = field.children(named: "value").compactMap(\.textContent)

        let options: [(label: String?, value: String)] = field.children(named: "option").compactMap { option in
            guard let value = option.child(named: "value")?.textContent else { return nil }
            return (label: option.attribute("label"), value: value)
        }

        return DataFormField(variable: variable, type: type, label: label, values: values, options: options)
    }
}

/// Builds a `<x type='submit'>` element from an array of ``DataFormField``.
func buildSubmitForm(_ fields: [DataFormField]) -> XMLElement {
    var form = XMLElement(name: "x", namespace: XMPPNamespaces.dataForms, attributes: ["type": "submit"])

    for field in fields {
        var attributes = ["var": field.variable]
        if let type = field.type { attributes["type"] = type }
        var fieldElement = XMLElement(name: "field", attributes: attributes)
        for value in field.values {
            var valueElement = XMLElement(name: "value")
            valueElement.addText(value)
            fieldElement.addChild(valueElement)
        }
        form.addChild(fieldElement)
    }

    return form
}

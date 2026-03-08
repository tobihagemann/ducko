import Testing
@testable import DuckoXMPP

enum DataFormParserTests {
    struct Parsing {
        @Test
        func `Parses data form fields from XML element`() {
            let form = buildSampleForm()
            let fields = parseDataForm(form)

            #expect(fields.count == 4)

            let formType = fields.first { $0.variable == "FORM_TYPE" }
            #expect(formType?.type == "hidden")
            #expect(formType?.values == ["http://jabber.org/protocol/muc#roomconfig"])

            let roomName = fields.first { $0.variable == "muc#roomconfig_roomname" }
            #expect(roomName?.type == "text-single")
            #expect(roomName?.label == "Room Name")
            #expect(roomName?.values == ["Test Room"])

            let persistent = fields.first { $0.variable == "muc#roomconfig_persistentroom" }
            #expect(persistent?.type == "boolean")
            #expect(persistent?.values == ["0"])

            let broadcast = fields.first { $0.variable == "muc#roomconfig_presencebroadcast" }
            #expect(broadcast?.type == "list-multi")
            #expect(broadcast?.values == ["moderator", "participant"])
            #expect(broadcast?.options.count == 3)
            #expect(broadcast?.options[0].label == "Moderator")
            #expect(broadcast?.options[0].value == "moderator")
        }

        @Test
        func `Returns empty for non-data-form element`() {
            let element = XMLElement(name: "iq")
            let fields = parseDataForm(element)
            #expect(fields.isEmpty)
        }

        @Test
        func `Skips fields without var attribute`() {
            var form = XMLElement(name: "x", namespace: XMPPNamespaces.dataForms, attributes: ["type": "form"])

            // Field without var (fixed type)
            var fixedField = XMLElement(name: "field", attributes: ["type": "fixed"])
            var fixedValue = XMLElement(name: "value")
            fixedValue.addText("Instructions here")
            fixedField.addChild(fixedValue)
            form.addChild(fixedField)

            // Field with var
            var namedField = XMLElement(name: "field", attributes: ["var": "name", "type": "text-single"])
            var namedValue = XMLElement(name: "value")
            namedValue.addText("hello")
            namedField.addChild(namedValue)
            form.addChild(namedField)

            let fields = parseDataForm(form)
            #expect(fields.count == 1)
            #expect(fields[0].variable == "name")
        }
    }

    struct Building {
        @Test
        func `Builds submit form from fields`() {
            let fields = [
                DataFormField(variable: "FORM_TYPE", type: "hidden", values: ["http://jabber.org/protocol/muc#roomconfig"]),
                DataFormField(variable: "muc#roomconfig_roomname", values: ["My Room"]),
                DataFormField(variable: "muc#roomconfig_persistentroom", values: ["1"])
            ]
            let form = buildSubmitForm(fields)

            #expect(form.name == "x")
            #expect(form.namespace == "jabber:x:data")
            #expect(form.attribute("type") == "submit")

            let formFields = form.children(named: "field")
            #expect(formFields.count == 3)

            let roomNameField = formFields.first { $0.attribute("var") == "muc#roomconfig_roomname" }
            let value = roomNameField?.child(named: "value")?.textContent
            #expect(value == "My Room")
        }

        @Test
        func `Round-trip parse and build preserves structure`() {
            let form = buildSampleForm()
            var fields = parseDataForm(form)
            #expect(fields.count == 4)

            // Modify a value
            if let index = fields.firstIndex(where: { $0.variable == "muc#roomconfig_roomname" }) {
                fields[index].values = ["Modified"]
            }

            // Build submit form and verify
            let submitForm = buildSubmitForm(fields)
            let nameField = submitForm.children(named: "field").first { $0.attribute("var") == "muc#roomconfig_roomname" }
            let nameValue = nameField?.child(named: "value")?.textContent
            #expect(nameValue == "Modified")
        }
    }
}

// MARK: - Helpers

private func buildSampleForm() -> XMLElement {
    var form = XMLElement(name: "x", namespace: XMPPNamespaces.dataForms, attributes: ["type": "form"])

    // FORM_TYPE (hidden)
    var formTypeField = XMLElement(name: "field", attributes: ["var": "FORM_TYPE", "type": "hidden"])
    var formTypeValue = XMLElement(name: "value")
    formTypeValue.addText("http://jabber.org/protocol/muc#roomconfig")
    formTypeField.addChild(formTypeValue)
    form.addChild(formTypeField)

    // Room name (text-single)
    var nameField = XMLElement(name: "field", attributes: ["var": "muc#roomconfig_roomname", "type": "text-single", "label": "Room Name"])
    var nameValue = XMLElement(name: "value")
    nameValue.addText("Test Room")
    nameField.addChild(nameValue)
    form.addChild(nameField)

    // Persistent (boolean)
    var persistField = XMLElement(name: "field", attributes: ["var": "muc#roomconfig_persistentroom", "type": "boolean", "label": "Persistent"])
    var persistValue = XMLElement(name: "value")
    persistValue.addText("0")
    persistField.addChild(persistValue)
    form.addChild(persistField)

    // Presence broadcast (list-multi with options)
    var broadcastField = XMLElement(name: "field", attributes: ["var": "muc#roomconfig_presencebroadcast", "type": "list-multi", "label": "Roles to Broadcast"])
    var bv1 = XMLElement(name: "value")
    bv1.addText("moderator")
    broadcastField.addChild(bv1)
    var bv2 = XMLElement(name: "value")
    bv2.addText("participant")
    broadcastField.addChild(bv2)

    for (label, value) in [("Moderator", "moderator"), ("Participant", "participant"), ("Visitor", "visitor")] {
        var option = XMLElement(name: "option", attributes: ["label": label])
        var optValue = XMLElement(name: "value")
        optValue.addText(value)
        option.addChild(optValue)
        broadcastField.addChild(option)
    }
    form.addChild(broadcastField)

    return form
}

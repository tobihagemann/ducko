import Testing
@testable import DuckoXMPP

struct RegistrationModuleTests {
    @Test
    func `Namespace constants`() {
        #expect(XMPPNamespaces.register == "jabber:iq:register")
        #expect(XMPPNamespaces.registerFeature == "http://jabber.org/features/iq-register")
    }

    @Test
    func `Module features`() {
        let module = RegistrationModule()
        #expect(module.features == [XMPPNamespaces.register])
    }

    @Test
    func `RegistrationForm legacy type`() {
        let form = RegistrationModule.RegistrationForm(
            formType: .legacy,
            instructions: "Please provide a username and password",
            isRegistered: false,
            hasUsername: true,
            hasPassword: true,
            hasEmail: false,
            dataFormFields: []
        )
        #expect(form.formType == .legacy)
        #expect(form.instructions == "Please provide a username and password")
        #expect(!form.isRegistered)
        #expect(form.hasUsername)
        #expect(form.hasPassword)
        #expect(!form.hasEmail)
        #expect(form.dataFormFields.isEmpty)
    }

    @Test
    func `RegistrationForm data form type`() {
        let fields = [
            DataFormField(variable: "username", type: "text-single"),
            DataFormField(variable: "password", type: "text-private"),
            DataFormField(variable: "email", type: "text-single")
        ]
        let form = RegistrationModule.RegistrationForm(
            formType: .dataForm,
            instructions: nil,
            isRegistered: true,
            hasUsername: true,
            hasPassword: true,
            hasEmail: true,
            dataFormFields: fields
        )
        #expect(form.formType == .dataForm)
        #expect(form.isRegistered)
        #expect(form.dataFormFields.count == 3)
    }

    @Test
    func `FormType cases`() {
        let legacy = RegistrationModule.FormType.legacy
        let dataForm = RegistrationModule.FormType.dataForm
        // Verify they're distinct
        switch legacy {
        case .legacy: break
        case .dataForm: Issue.record("Expected legacy")
        }
        switch dataForm {
        case .dataForm: break
        case .legacy: Issue.record("Expected dataForm")
        }
    }
}

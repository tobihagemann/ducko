import DuckoXMPP

// periphery:ignore - used by AccountService registration methods, awaiting UI consumer
/// Bridge type for `RegistrationModule.RegistrationForm` so DuckoUI can display
/// registration forms without importing DuckoXMPP.
public struct RegistrationFormInfo: Sendable {
    public enum FormKind: Sendable {
        case legacy
        case dataForm
    }

    public let formKind: FormKind
    public let instructions: String?
    public let isRegistered: Bool
    public let hasUsername: Bool
    public let hasPassword: Bool
    public let hasEmail: Bool
    public let dataFormFields: [RoomConfigField]

    /// Initializes from a ``RegistrationModule/RegistrationForm``.
    public init(from form: RegistrationModule.RegistrationForm) {
        self.formKind = form.formType == .dataForm ? .dataForm : .legacy
        self.instructions = form.instructions
        self.isRegistered = form.isRegistered
        self.hasUsername = form.hasUsername
        self.hasPassword = form.hasPassword
        self.hasEmail = form.hasEmail
        self.dataFormFields = form.dataFormFields.map { RoomConfigField(from: $0) }
    }
}

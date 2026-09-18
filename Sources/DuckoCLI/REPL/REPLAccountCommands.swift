import DuckoCore
import DuckoXMPP
import Foundation

func handleUnregisterAccountREPLCommand(context: REPLContext) async {
    print("WARNING: This will permanently unregister your account from the server.")
    print("Type 'yes' to confirm:")
    guard readLine()?.trimmingCharacters(in: .whitespaces) == "yes" else {
        print("Cancelled.")
        return
    }
    print("Also delete chat history? (yes/no):")
    let includeHistory = readLine()?.trimmingCharacters(in: .whitespaces) == "yes"
    do {
        try await context.environment.cancelAccount(context.accountID, includeHistory: includeHistory)
        print("Account unregistered.")
        if includeHistory {
            print("Chat history deleted.")
        }
        Foundation.exit(0)
    } catch {
        print(context.formatter.formatError(error))
    }
}

func handleCheckRegistrationREPLCommand(_ arguments: String, context: REPLContext) async {
    let jid = arguments.isEmpty ? nil : arguments
    do {
        let form = try await context.environment.accountService.retrieveRegistrationForm(
            accountID: context.accountID, from: jid
        )
        print(context.formatter.formatRegistrationForm(form))
    } catch {
        print(context.formatter.formatError(error))
    }
}

func handleSubmitRegistrationREPLCommand(_ arguments: String, context: REPLContext) async {
    let jid = arguments.isEmpty ? nil : arguments
    do {
        let form = try await context.environment.accountService.retrieveRegistrationForm(
            accountID: context.accountID, from: jid
        )
        print(context.formatter.formatRegistrationForm(form))

        switch form.formKind {
        case .legacy:
            try await submitLegacyRegistration(form: form, jid: jid, context: context)
        case .dataForm:
            try await submitDataFormRegistration(form: form, jid: jid, context: context)
        }
        print("Registration submitted successfully.")
    } catch {
        print(context.formatter.formatError(error))
    }
}

private func submitLegacyRegistration(form: RegistrationFormInfo, jid: String?, context: REPLContext) async throws {
    print("\nEnter registration details (press Enter to skip):")
    var username = ""
    var password = ""
    var email = ""
    if form.hasUsername {
        print("Username: ", terminator: "")
        username = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
    }
    if form.hasPassword {
        password = String(cString: getpass("Password: "))
    }
    if form.hasEmail {
        print("Email: ", terminator: "")
        email = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
    }
    try await context.environment.accountService.submitRegistration(
        accountID: context.accountID,
        username: username,
        password: password,
        email: email.isEmpty ? nil : email,
        to: jid
    )
}

private func submitDataFormRegistration(form: RegistrationFormInfo, jid: String?, context: REPLContext) async throws {
    var fields = form.dataFormFields
    print("\nEnter field values (press Enter to keep current):")
    for index in fields.indices where fields[index].isUserEditable {
        let label = fields[index].displayLabel
        let current = fields[index].values.joined(separator: ", ")
        print("\(label) [\(current)]: ", terminator: "")
        let fieldInput = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
        if !fieldInput.isEmpty {
            fields[index].values = [fieldInput]
        }
    }
    try await context.environment.accountService.submitRegistrationDataForm(
        accountID: context.accountID,
        fields: fields,
        to: jid
    )
}

func handleAvatarREPLCommand(_ arguments: String, context: REPLContext) async {
    if arguments.isEmpty {
        let hash = await MainActor.run { context.environment.avatarService.ownAvatarHash(for: context.accountID) }
        if let hash {
            print("Own avatar hash: \(hash)")
        } else {
            print("No avatar set.")
        }
        return
    }

    guard let jid = BareJID.parse(arguments) else {
        print("Invalid JID: \(arguments)")
        return
    }

    guard let avatar = await context.environment.avatarService.fetchAvatar(for: jid, accountID: context.accountID) else {
        print("No avatar found for \(jid).")
        return
    }

    print("Avatar for \(jid):")
    print("  Hash: \(avatar.hash)")
    print("  Type: \(avatar.mimeType)")
    print("  Size: \(avatar.data.count) bytes")
}

func handleProfileREPLCommand(context: REPLContext) async {
    let output = await fetchAndFormatProfile(
        environment: context.environment, accountID: context.accountID, formatter: context.formatter
    )
    print(output)
}

func handleConnectionInfoREPLCommand(context: REPLContext) async {
    let info = await MainActor.run { context.environment.accountService.tlsInfo(for: context.accountID) }
    if let info {
        print(context.formatter.formatTLSInfo(info))
    } else {
        print("No TLS connection info available.")
    }
}

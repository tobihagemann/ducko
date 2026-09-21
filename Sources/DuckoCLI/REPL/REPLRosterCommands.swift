import DuckoCore
import DuckoXMPP
import Foundation

func handleRosterCommand(context: REPLContext) async {
    let environment = context.environment
    let (groups, presences) = await MainActor.run {
        (environment.rosterService.groups, environment.presenceService.contactPresences)
    }

    guard !groups.isEmpty else {
        print(context.formatter.formatEmptyResult(.roster(accountID: context.accountID)))
        return
    }

    printRoster(groups: groups, presences: presences, formatter: context.formatter)
}

func handleAddCommand(_ arguments: String, context: REPLContext) async {
    let parts = arguments.split(separator: " ", maxSplits: 1)
    let jidString = String(parts[0])
    guard let bareJID = BareJID.parse(jidString) else {
        print(context.formatter.formatError(CLIError.invalidJID(jidString)))
        return
    }
    let name: String? = parts.count > 1 ? String(parts[1]) : nil

    do {
        let outcome = try await context.environment.rosterService.addContact(jid: bareJID, name: name, groups: [], accountID: context.accountID)
        print(context.formatter.formatRosterCommand(outcome))
    } catch {
        print(context.formatter.formatError(error))
    }
}

func handleRemoveCommand(_ jidString: String, context: REPLContext) async {
    do {
        let outcome = try await context.environment.rosterService.removeContact(jidString: jidString, accountID: context.accountID)
        print(context.formatter.formatRosterCommand(outcome))
    } catch {
        print(context.formatter.formatError(error))
    }
}

func handleApproveREPLCommand(_ jidString: String, context: REPLContext) async {
    await handleSubscriptionCommand(jidString, context: context, success: "Approved subscription from") {
        try await context.environment.rosterService.approveSubscription(jidString: $0, accountID: context.accountID)
    }
}

func handleDenyREPLCommand(_ jidString: String, context: REPLContext) async {
    await handleSubscriptionCommand(jidString, context: context, success: "Denied subscription from") {
        try await context.environment.rosterService.denySubscription(jidString: $0, accountID: context.accountID)
    }
}

private func handleSubscriptionCommand(
    _ jidString: String, context: REPLContext, success: String, action: (String) async throws -> Void
) async {
    guard BareJID.parse(jidString) != nil else {
        print(context.formatter.formatError(CLIError.invalidJID(jidString)))
        return
    }
    do {
        try await action(jidString)
        print("\(success) \(jidString).")
    } catch {
        print(context.formatter.formatError(error))
    }
}

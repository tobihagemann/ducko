import DuckoCore
import DuckoXMPP

func printRoster(groups: [ContactGroup], presences: [BareJID: PresenceService.PresenceStatus], formatter: any CLIFormatter) {
    for group in groups {
        print(formatter.formatGroupHeader(group))
        for contact in group.contacts {
            let presence = presences[contact.jid]
            print(formatter.formatContactWithPresence(contact, presence: presence))
        }
    }
}

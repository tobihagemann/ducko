import DuckoXMPP
import Foundation

actor CLIEventHandler {
    private let formatter: any CLIFormatter

    init(formatter: any CLIFormatter) {
        self.formatter = formatter
    }

    func handleEvent(_ event: XMPPEvent, accountID: UUID) {
        guard let output = formatter.formatEvent(event, accountID: accountID) else { return }
        print(output)
    }
}

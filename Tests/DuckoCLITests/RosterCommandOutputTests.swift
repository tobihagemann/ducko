import ArgumentParser
import DuckoCore
import Foundation
import Testing
@testable import DuckoCLI

@MainActor
struct RosterCommandOutputTests {
    @Test(arguments: [RosterCommandOutcome.LocalStatus.synchronized, .incomplete, .different])
    func `finite command prints one outcome and exits only after teardown`(status: RosterCommandOutcome.LocalStatus) async throws {
        let outcome = RosterCommandOutcome(operation: .remove, accountID: UUID(), jid: "bob@example.com", localStatus: status, subscriptionStatus: .notRequested)
        var tornDown = false
        var lines: [String] = []
        do {
            try await RosterCommandOutput.run(formatter: JSONFormatter(), output: {
                #expect(tornDown)
                lines.append($0)
            }, operation: {
                try await ConnectedOperation.run(connect: {}, ready: {}, operation: { outcome }, teardown: { tornDown = true })
            })
            #expect(status == .synchronized)
        } catch let code as ExitCode {
            #expect(code == ExitCode(3))
            #expect(status != .synchronized)
        }
        #expect(lines.count == 1)
        let object = try #require(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: String])
        #expect(object["operation"] == "remove")
        #expect(object["account"] == outcome.accountID.uuidString)
        #expect(object["jid"] == outcome.jid)
        #expect(object["remote_status"] == "confirmed")
        #expect(object["local_status"] == status.rawValue)
        #expect(object["result"] == (outcome.isComplete ? "complete" : "partial"))
    }

    @Test(arguments: [RosterCommandError.RemoteStatus.notSent, .rejected, .unconfirmed])
    func `preconfirmation errors retain structured remote status`(status: RosterCommandError.RemoteStatus) async throws {
        let error = RosterCommandError(operation: .add, accountID: UUID(), jid: "bob@example.com", status: status, detail: "Controlled fixture")
        var lines: [String] = []
        await #expect(throws: ExitCode.failure) {
            try await RosterCommandOutput.run(formatter: JSONFormatter(), output: { lines.append($0) }, operation: { throw error })
        }
        #expect(lines.count == 1)
        let object = try #require(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: String])
        #expect(object["remote_status"] == status.rawValue)
        #expect(object["type"] == "error")
        #expect(object["local_status"] == "notStarted")
        #expect(object["jid"] == error.jid)
    }

    @Test(arguments: [RosterCommandOutcome.LocalStatus.synchronized, .incomplete, .different])
    func `human and structured formatters report the same outcome`(status: RosterCommandOutcome.LocalStatus) throws {
        let outcome = RosterCommandOutcome(operation: .add, accountID: UUID(), jid: "bob@example.com", localStatus: status, subscriptionStatus: .incomplete)
        #expect(!outcome.isComplete)
        #expect(PlainFormatter().formatRosterCommand(outcome) == outcome.message)
        #expect(ANSIFormatter().formatRosterCommand(outcome).contains(outcome.message))
        let object = try #require(JSONSerialization.jsonObject(with: Data(JSONFormatter().formatRosterCommand(outcome).utf8)) as? [String: String])
        #expect(object["message"] == outcome.message)
        #expect(object["subscription_status"] == "incomplete")
        #expect(object["result"] == "partial")
    }
}

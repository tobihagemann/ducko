import ArgumentParser
import DuckoCore

extension DuckoCLI {
    struct OMEMO: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "omemo",
            abstract: "OMEMO encryption management",
            subcommands: [Fingerprint.self, Devices.self, Trust.self, Untrust.self]
        )

        struct Fingerprint: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Display your own OMEMO device fingerprint"
            )

            @OptionGroup var global: GlobalOptions

            @OptionGroup var accountOption: AccountOption

            func run() async throws {
                let formatter = global.formatter

                try await ConnectedOperation.run(formatter: formatter, account: accountOption.account) { env, selectedAccount in
                    let fingerprint = await env.omemoService.ownFingerprint(accountID: selectedAccount.id)
                    if let fingerprint {
                        print(OMEMODeviceInfo.formatFingerprint(fingerprint))
                    } else {
                        print("No OMEMO identity found.")
                    }
                }
            }
        }

        struct Devices: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "List a contact's OMEMO devices with trust status"
            )

            @OptionGroup var global: GlobalOptions

            @OptionGroup var accountOption: AccountOption

            @Argument(help: "The contact JID")
            var jid: String

            func run() async throws {
                let formatter = global.formatter

                try await ConnectedOperation.run(formatter: formatter, account: accountOption.account) { env, selectedAccount in
                    let devices = await env.omemoService.deviceInfoList(for: jid, accountID: selectedAccount.id)
                    if devices.isEmpty {
                        print("No known OMEMO devices for \(jid).")
                    } else {
                        for device in devices {
                            let fp = device.fingerprint.isEmpty ? "(no fingerprint)" : OMEMODeviceInfo.formatFingerprint(device.fingerprint)
                            print("  \(device.deviceID)  \(fp)  [\(device.trustLevel.rawValue)]")
                        }
                    }
                }
            }
        }

        struct Trust: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Trust a contact's OMEMO device"
            )

            @OptionGroup var global: GlobalOptions

            @OptionGroup var accountOption: AccountOption

            @Argument(help: "The contact JID")
            var jid: String

            @Argument(help: "The device ID to trust")
            var deviceID: UInt32

            func run() async throws {
                let formatter = global.formatter

                try await ConnectedOperation.run(formatter: formatter, account: accountOption.account) { env, selectedAccount in
                    let devices = await env.omemoService.deviceInfoList(for: jid, accountID: selectedAccount.id)
                    guard let device = devices.first(where: { $0.deviceID == deviceID }) else {
                        print("Device \(deviceID) not found for \(jid).")
                        return
                    }

                    try await env.omemoService.trustDevice(
                        accountID: selectedAccount.id, peerJID: jid,
                        deviceID: deviceID, fingerprint: device.fingerprint
                    )
                    print("Trusted device \(deviceID) for \(jid).")
                }
            }
        }

        struct Untrust: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Untrust a contact's OMEMO device"
            )

            @OptionGroup var global: GlobalOptions

            @OptionGroup var accountOption: AccountOption

            @Argument(help: "The contact JID")
            var jid: String

            @Argument(help: "The device ID to untrust")
            var deviceID: UInt32

            func run() async throws {
                let formatter = global.formatter

                try await ConnectedOperation.run(formatter: formatter, account: accountOption.account) { env, selectedAccount in
                    try await env.omemoService.untrustDevice(
                        accountID: selectedAccount.id, peerJID: jid, deviceID: deviceID
                    )
                    print("Untrusted device \(deviceID) for \(jid).")
                }
            }
        }
    }
}

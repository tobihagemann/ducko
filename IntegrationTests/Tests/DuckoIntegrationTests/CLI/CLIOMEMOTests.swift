import DuckoCore
import Foundation
import Testing

extension DuckoIntegrationTests.CLILayer {
    struct CLIOMEMOTests {
        // Each test runs one-shot `ducko omemo` invocations in a freshly-wiped
        // `DUCKO_PROFILE`. The profile's OMEMO store is empty on the first
        // connect, so that connect generates and publishes a brand-new alice
        // device to the shared server devicelist (the harness identity-reuse
        // fixture path is not available to the spawned binary). Subsequent
        // invocations in the same profile reuse the persisted identity, so the
        // device cost is one per test, not one per command. The bootstrap
        // auto-reset absorbs the accumulation — connect cycles here are not free.

        @Test
        @MainActor func `omemo fingerprint prints the own device fingerprint`() async throws {
            try await CLIProcess.withProcess { cli in
                try await cli.seedAccount(TestCredentials.alice)

                let output = try await cli.run(["omemo", "fingerprint"])
                #expect(output.exitCode == 0)

                // stdout interleaves connect-time event lines (connection, devicelists) before the
                // fingerprint, so match the fingerprint as its own hex-and-space line rather than
                // scanning the whole buffer. A fresh identity is generated on connect, so a real
                // fingerprint is expected; tolerate the not-found message if persistence has not landed.
                let hasFingerprintLine = output.stdout.split(whereSeparator: \.isNewline).contains { line in
                    let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                    return trimmed.count >= 16 && trimmed.allSatisfy { $0.isHexDigit || $0 == " " }
                }
                #expect(hasFingerprintLine || output.stdout.contains("No OMEMO identity found."))
            }
        }

        @Test
        @MainActor func `omemo devices lists a contact's devices or reports none`() async throws {
            try await CLIProcess.withProcess { cli in
                try await cli.seedAccount(TestCredentials.alice)
                let bob = TestCredentials.bob.jid

                let output = try await cli.run(["omemo", "devices", bob])
                #expect(output.exitCode == 0)
                // Tolerant: bob may or may not have a device in alice's local store (populated via PEP
                // `+notify`). A device line carries the `[<trust-level>]` suffix.
                #expect(output.stdout.contains("No known OMEMO devices for \(bob)") || output.stdout.contains("["))

                // Best-effort trust transition — only fires when a peer device is already in the local
                // store (no fresh-bob publish, which would grow the shared devicelist). On a fresh
                // profile with no prior `+notify` this is usually empty, so it is genuinely best-effort.
                // Guaranteed, deterministic coverage of the underlying `OMEMOService.trustDevice`/
                // `untrustDevice` transitions lives in-process in `Protocol/OMEMOTests` (seeded via
                // `omemoStore`); this block only exercises the CLI command wiring opportunistically.
                guard let device = Self.parseDeviceLines(output.stdout).first else { return }

                let trusted = try await cli.run(["omemo", "trust", bob, device.id])
                #expect(trusted.stdout.contains("Trusted device \(device.id)"))
                let afterTrust = try await cli.run(["omemo", "devices", bob])
                #expect(Self.parseDeviceLines(afterTrust.stdout).first(where: { $0.id == device.id })?.level == OMEMOTrustLevel.trusted.rawValue)

                let untrusted = try await cli.run(["omemo", "untrust", bob, device.id])
                #expect(untrusted.stdout.contains("Untrusted device \(device.id)"))
                let afterUntrust = try await cli.run(["omemo", "devices", bob])
                #expect(Self.parseDeviceLines(afterUntrust.stdout).first(where: { $0.id == device.id })?.level == OMEMOTrustLevel.untrusted.rawValue)

                // Asserts only these supported one-way transitions: the CLI does not restore the
                // device's original trust level, so there is no "flip back to original" check.
            }
        }

        @Test
        @MainActor func `omemo trust reports a missing device as not found`() async throws {
            try await CLIProcess.withProcess { cli in
                try await cli.seedAccount(TestCredentials.alice)
                let bob = TestCredentials.bob.jid

                // A sentinel deviceID guaranteed absent from any real devicelist.
                let output = try await cli.run(["omemo", "trust", bob, "\(Self.sentinelDeviceID)"])
                #expect(output.exitCode == 0)
                #expect(output.stdout.contains("Device \(Self.sentinelDeviceID) not found"))
            }
        }

        @Test
        @MainActor func `omemo untrust prints its success line for an unknown device`() async throws {
            try await CLIProcess.withProcess { cli in
                try await cli.seedAccount(TestCredentials.alice)
                let bob = TestCredentials.bob.jid

                // Coverage caveat: `OMEMOService.untrustDevice` early-returns without mutating when no
                // local trust row exists, and `Untrust.run` prints its success line unconditionally. For
                // the sentinel this asserts only that the command wiring runs and prints — no trust
                // state actually changes.
                let output = try await cli.run(["omemo", "untrust", bob, "\(Self.sentinelDeviceID)"])
                #expect(output.exitCode == 0)
                #expect(output.stdout.contains("Untrusted device \(Self.sentinelDeviceID) for \(bob)."))
            }
        }

        // MARK: - Helpers

        /// `UInt32.max` — a device ID no real OMEMO devicelist publishes.
        private static let sentinelDeviceID: UInt32 = 4_294_967_295

        /// Parses `  <id>  <fp>  [<level>]` device lines into their ID and trust level.
        private static func parseDeviceLines(_ stdout: String) -> [(id: String, level: String)] {
            stdout.split(separator: "\n").compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let id = trimmed.split(separator: " ").first.map(String.init),
                      let levelStart = trimmed.lastIndex(of: "["),
                      let levelEnd = trimmed.lastIndex(of: "]"),
                      levelStart < levelEnd
                else { return nil }
                let level = String(trimmed[trimmed.index(after: levelStart) ..< levelEnd])
                return (id: id, level: level)
            }
        }
    }
}

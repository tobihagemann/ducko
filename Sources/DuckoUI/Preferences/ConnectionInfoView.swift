import DuckoCore
import SwiftUI

struct ConnectionInfoView: View {
    let tlsInfo: TLSInfo

    var body: some View {
        Form {
            Section("TLS Connection") {
                LabeledContent("TLS Version", value: tlsInfo.protocolVersion)
                    .accessibilityIdentifier("tlsVersion")
                LabeledContent("Cipher Suite", value: tlsInfo.cipherSuite)
                    .accessibilityIdentifier("cipherSuite")
            }

            Section("Certificate") {
                if let subject = tlsInfo.certificateSubject {
                    LabeledContent("Subject", value: subject)
                        .accessibilityIdentifier("certSubject")
                }
                if let issuer = tlsInfo.certificateIssuer {
                    LabeledContent("Issuer", value: issuer)
                        .accessibilityIdentifier("certIssuer")
                }
                if let expiry = tlsInfo.certificateExpiry {
                    LabeledContent("Expires", value: expiry.formatted(date: .abbreviated, time: .shortened))
                        .accessibilityIdentifier("certExpiry")
                }
                if let fingerprint = tlsInfo.certificateSHA256 {
                    LabeledContent("SHA-256") {
                        Text(fingerprint)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .accessibilityIdentifier("certFingerprint")
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 450)
    }
}

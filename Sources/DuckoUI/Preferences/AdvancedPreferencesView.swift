import AppKit
import SwiftUI

struct AdvancedPreferencesView: View {
    @State private var preferences = AdvancedPreferences()

    var body: some View {
        Form {
            Section("Data") {
                LabeledContent("Data Location") {
                    HStack {
                        Text(preferences.dataLocation.path(percentEncoded: false))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Button("Reveal in Finder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: preferences.dataLocation.path(percentEncoded: false))
                        }
                    }
                }
            }

            Section("Logging") {
                Picker("Log Level", selection: Bindable(preferences).logLevel) {
                    Text("Default").tag("default")
                    Text("Debug").tag("debug")
                    Text("Verbose").tag("verbose")
                }
            }
        }
        .formStyle(.grouped)
    }
}

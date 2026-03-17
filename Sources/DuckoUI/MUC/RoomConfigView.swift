import DuckoCore
import SwiftUI

/// Editable room configuration form. Embedded inside `RoomSettingsView`'s General tab.
struct RoomConfigView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let roomJIDString: String
    let accountID: UUID
    @Binding var saveRequested: Bool

    @State private var fields: [RoomConfigField] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView("Loading room configuration...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Failed to load configuration",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                configForm
            }
        }
        .task {
            await loadConfig()
        }
        .onChange(of: saveRequested) {
            if saveRequested {
                Task {
                    await saveConfig()
                }
            }
        }
        .accessibilityIdentifier("room-config-view")
    }

    private var configForm: some View {
        Form {
            ForEach(editableFields.indices, id: \.self) { index in
                fieldRow(for: editableFields[index])
            }
        }
        .formStyle(.grouped)
    }

    /// Editable fields (excluding hidden FORM_TYPE).
    private var editableFields: [RoomConfigField] {
        fields.filter { $0.variable != "FORM_TYPE" && $0.type != "hidden" }
    }

    @ViewBuilder
    private func fieldRow(for field: RoomConfigField) -> some View {
        let label = field.label ?? field.variable

        switch field.type {
        case "boolean":
            Toggle(label, isOn: boolBinding(for: field.variable))
        case "list-single":
            Picker(label, selection: singleValueBinding(for: field.variable)) {
                ForEach(field.options, id: \.value) { option in
                    Text(option.label ?? option.value).tag(option.value)
                }
            }
        case "text-multi":
            LabeledContent(label) {
                TextEditor(text: multiLineBinding(for: field.variable))
                    .frame(height: 60)
            }
        case "list-multi":
            VStack(alignment: .leading) {
                Text(label)
                ForEach(field.options, id: \.value) { option in
                    Toggle(
                        option.label ?? option.value,
                        isOn: multiSelectBinding(for: field.variable, value: option.value)
                    )
                }
            }
        default:
            TextField(label, text: singleValueBinding(for: field.variable))
        }
    }

    // MARK: - Bindings

    private func boolBinding(for variable: String) -> Binding<Bool> {
        Binding(
            get: {
                let val = fieldValue(for: variable)
                return val == "1" || val == "true"
            },
            set: { newValue in setFieldValue(for: variable, value: newValue ? "1" : "0") }
        )
    }

    private func singleValueBinding(for variable: String) -> Binding<String> {
        Binding(
            get: { fieldValue(for: variable) },
            set: { newValue in setFieldValue(for: variable, value: newValue) }
        )
    }

    private func multiSelectBinding(for variable: String, value: String) -> Binding<Bool> {
        Binding(
            get: { fields.first(where: { $0.variable == variable })?.values.contains(value) ?? false },
            set: { isSelected in
                guard let index = fields.firstIndex(where: { $0.variable == variable }) else { return }
                if isSelected {
                    if !fields[index].values.contains(value) { fields[index].values.append(value) }
                } else {
                    fields[index].values.removeAll { $0 == value }
                }
            }
        )
    }

    private func multiLineBinding(for variable: String) -> Binding<String> {
        Binding(
            get: { fields.first(where: { $0.variable == variable })?.values.joined(separator: "\n") ?? "" },
            set: { newValue in
                if let index = fields.firstIndex(where: { $0.variable == variable }) {
                    fields[index].values = newValue.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                }
            }
        )
    }

    private func fieldValue(for variable: String) -> String {
        fields.first(where: { $0.variable == variable })?.values.first ?? ""
    }

    private func setFieldValue(for variable: String, value: String) {
        if let index = fields.firstIndex(where: { $0.variable == variable }) {
            fields[index].values = [value]
        }
    }

    // MARK: - Actions

    private func loadConfig() async {
        do {
            fields = try await environment.chatService.getRoomConfig(jidString: roomJIDString, accountID: accountID)
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func saveConfig() async {
        do {
            try await environment.chatService.submitRoomConfig(jidString: roomJIDString, fields: fields, accountID: accountID)
            saveRequested = false
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            saveRequested = false
        }
    }
}

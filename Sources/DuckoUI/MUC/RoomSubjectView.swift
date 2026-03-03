import DuckoCore
import SwiftUI

struct RoomSubjectView: View {
    let windowState: ChatWindowState
    @State private var isEditing = false
    @State private var editText = ""

    private var subject: String? {
        windowState.conversation?.roomSubject
    }

    var body: some View {
        HStack {
            if isEditing {
                TextField("Room topic", text: $editText)
                    .textFieldStyle(.roundedBorder)

                Button("Save") {
                    let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { await windowState.setRoomSubject(text) }
                    isEditing = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Cancel") {
                    isEditing = false
                }
                .controlSize(.small)
            } else {
                Text(subject ?? "No topic set")
                    .font(.callout)
                    .foregroundStyle(subject != nil ? .primary : .tertiary)
                    .lineLimit(1)

                Spacer()

                Button {
                    editText = subject ?? ""
                    isEditing = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .accessibilityIdentifier("room-subject-view")
    }
}

import SwiftUI
import UniformTypeIdentifiers

struct FileDropOverlay: ViewModifier {
    let windowState: ChatWindowState
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if isTargeted {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)

                        Text("Drop files to send")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.ultraThinMaterial)
                    .accessibilityIdentifier("file-drop-overlay")
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                handleDrop(providers)
            }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            windowState.loadFileURL(from: provider)
            handled = true
        }
        return handled
    }
}

extension View {
    func fileDropTarget(windowState: ChatWindowState) -> some View {
        modifier(FileDropOverlay(windowState: windowState))
    }
}

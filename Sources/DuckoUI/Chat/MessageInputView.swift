import DuckoCore
import SwiftUI
import UniformTypeIdentifiers

struct MessageInputView: View {
    @Bindable var windowState: ChatWindowState
    @State private var text = ""
    @State private var showFileImporter = false
    @State private var isSending = false
    @FocusState private var isInputFocused: Bool

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        (!trimmedText.isEmpty || !windowState.pendingAttachments.isEmpty) && !isSending
    }

    var body: some View {
        VStack(spacing: 0) {
            SendErrorBanner(windowState: windowState)

            ReplyComposeBar(windowState: windowState)

            PendingAttachmentBar(windowState: windowState)

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    showFileImporter = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("attachment-button")

                TextField("Message", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1 ... 5)
                    .onKeyPress(.return, phases: .down) { keyPress in
                        if keyPress.modifiers.contains(.shift) {
                            return .ignored
                        }
                        sendMessage()
                        return .handled
                    }
                    .onChange(of: text) {
                        guard !text.isEmpty else { return }
                        Task { await windowState.userIsTyping() }
                    }
                    .onChange(of: windowState.editingMessage?.id) {
                        if let editing = windowState.editingMessage {
                            text = editing.body
                            isInputFocused = true
                        }
                    }
                    .onPasteCommand(of: [.image, .fileURL]) { providers in
                        handlePaste(providers)
                    }
                    .focused($isInputFocused)
                    .accessibilityIdentifier("message-field")
                    .onAppear { isInputFocused = true }

                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityIdentifier("send-button")
            }
            .padding(12)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handleFileImporterResult(result)
        }
    }

    private func sendMessage() {
        let body = trimmedText
        let hasAttachments = !windowState.pendingAttachments.isEmpty

        guard !body.isEmpty || hasAttachments else { return }
        text = ""
        isSending = true

        Task {
            if hasAttachments {
                await windowState.sendAttachments()
            }
            if !body.isEmpty {
                await windowState.sendMessage(body)
            }
            // Restore composer text only on typed send errors (e.g. encryption-required-but-no-trusted-devices); untyped failures leave the composer empty.
            if windowState.lastSendError != nil, let failedBody = windowState.lastFailedSendBody {
                text = failedBody
            }
            isSending = false
        }
    }

    private func handleFileImporterResult(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result else { return }
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }

            // Copy to temp so the security-scoped bookmark isn't needed later
            let tempDir = FileManager.default.temporaryDirectory
            let dest = tempDir.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else { continue }
            windowState.addAttachment(url: dest)
        }
    }

    private func handlePaste(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                windowState.loadFileURL(from: provider)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    let tempDir = FileManager.default.temporaryDirectory
                    let fileName = "pasted-image-\(UUID().uuidString).png"
                    let tempURL = tempDir.appendingPathComponent(fileName)
                    do {
                        try data.write(to: tempURL)
                        Task { @MainActor in
                            windowState.addAttachment(url: tempURL)
                        }
                    } catch {}
                }
            }
        }
    }
}

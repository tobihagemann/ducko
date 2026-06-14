import SwiftUI

/// Opens (or selects) a chat tab in the single chat window and brings it forward.
/// Built once by the app from `ChatContainerState.open` + `openWindow(id:)` and injected
/// into the scenes that open chats, so call sites don't repeat the open-then-surface pair.
public struct OpenChatAction {
    let handler: (String) -> Void

    public init(handler: @escaping (String) -> Void) {
        self.handler = handler
    }

    public func callAsFunction(_ jidString: String) {
        handler(jidString)
    }
}

public extension EnvironmentValues {
    @Entry var openChat = OpenChatAction { _ in }
}

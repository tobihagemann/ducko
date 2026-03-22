import DuckoCore
import SwiftUI

public struct TranscriptViewerWindow: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var state: TranscriptViewerState?

    public init() {}

    public var body: some View {
        Group {
            if let state {
                NavigationSplitView {
                    TranscriptSidebarView(state: state)
                } detail: {
                    TranscriptDetailView(state: state)
                }
            } else {
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            let viewerState = TranscriptViewerState(environment: environment)
            state = viewerState
            await viewerState.load()
        }
    }
}

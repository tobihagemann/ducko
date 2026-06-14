import DuckoCore
import SwiftUI

public struct ContactInfoWindow: View {
    @Environment(AppEnvironment.self) private var environment
    @Binding var ref: ContactInfoRef?
    @State private var state: ContactInfoWindowState?

    public init(ref: Binding<ContactInfoRef?>) {
        _ref = ref
    }

    public var body: some View {
        content
            .navigationTitle(state?.displayName ?? "Contact Info")
            .task(id: ref) {
                guard let ref else { return }
                if state?.ref != ref {
                    state = ContactInfoWindowState(ref: ref, environment: environment)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let state {
            ContactInfoView(state: state)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

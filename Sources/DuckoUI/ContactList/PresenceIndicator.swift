import DuckoCore
import SwiftUI

struct PresenceIndicator: View {
    let status: PresenceService.PresenceStatus?

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        switch status {
        case .available: .green
        case .away, .xa: .yellow
        case .dnd: .red
        case .offline, .none: .gray
        }
    }
}

import DuckoCore
import SwiftUI

struct PresenceIndicator: View {
    let status: PresenceService.PresenceStatus?
    var isPendingSubscription: Bool = false

    var body: some View {
        if isPendingSubscription {
            Circle()
                .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
                .foregroundStyle(.orange)
                .frame(width: 8, height: 8)
        } else {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
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

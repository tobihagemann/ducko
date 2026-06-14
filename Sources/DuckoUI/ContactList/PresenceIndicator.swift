import DuckoCore
import SwiftUI

struct PresenceIndicator: View {
    let display: ContactPresenceDisplay

    init(display: ContactPresenceDisplay) {
        self.display = display
    }

    /// Convenience for a known own/local presence, which is never unknown or pending.
    init(status: PresenceService.PresenceStatus?) {
        self.display = ContactPresenceDisplay.resolve(presence: status)
    }

    var body: some View {
        switch display {
        case .pending:
            Circle()
                .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
                .foregroundStyle(.orange)
                .frame(width: 8, height: 8)
        case .unknown:
            Circle()
                .stroke(lineWidth: 1.5)
                .foregroundStyle(.gray)
                .frame(width: 8, height: 8)
        case .available, .away, .dnd, .offline:
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
    }

    private var color: Color {
        switch display {
        case .available: .green
        case .away: .yellow
        case .dnd: .red
        case .offline, .unknown, .pending: .gray
        }
    }
}

import SwiftUI

extension Color {
    static func forNickname(_ nickname: String) -> Color {
        let hash = nickname.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .mint]
        return colors[abs(hash) % colors.count]
    }
}

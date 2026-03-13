import DuckoCore
import SwiftUI

extension Color {
    /// XEP-0392 consistent color for a nickname.
    ///
    /// Uses SHA-1 hue computation + HSLuv perceptually uniform color space.
    /// Lightness adapts to the color scheme for readability.
    static func forNickname(_ nickname: String, colorScheme: ColorScheme) -> Color {
        let hue = ConsistentColorHue.hue(for: nickname)
        let lightness: Double = colorScheme == .dark ? 65 : 50
        return HSLuvColor.color(hue: hue, saturation: 100, lightness: lightness)
    }
}

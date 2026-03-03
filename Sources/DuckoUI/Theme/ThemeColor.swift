import SwiftUI

public struct ThemeColor: Codable, Sendable, Equatable {
    public let light: String
    public let dark: String

    public init(light: String, dark: String) {
        self.light = light
        self.dark = dark
    }

    public func resolved(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .light:
            Color(hex: light)
        case .dark:
            Color(hex: dark)
        @unknown default:
            Color(hex: light)
        }
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var hexValue: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&hexValue)
        let red = Double((hexValue >> 16) & 0xFF) / 255
        let green = Double((hexValue >> 8) & 0xFF) / 255
        let blue = Double(hexValue & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }
}

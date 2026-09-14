import DuckoCore
import Foundation

extension Bundle {
    /// DuckoUI's resource bundle, resolved via the shared `duckoResourceBundle` search so it
    /// loads from the code-signing-valid `Contents/Resources/` location in a packaged app rather
    /// than the bundle root the generated `Bundle.module` expects (which `fatalError`s at launch).
    static let duckoUIModule: Bundle = duckoResourceBundle(named: "Ducko_DuckoUI.bundle") { .module }
}

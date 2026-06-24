import Foundation

/// Shared width bounds for the auto-sizing contact-list window, in points.
/// Pure geometry, so these live in DuckoCore alongside the sizing arithmetic
/// rather than with the view code.
public enum ContactListWidthMetrics {
    /// Floor so the "me" header stays comfortable when names are short.
    public static let floor: CGFloat = 200
    /// Fixed row chrome (insets + status dot + spacing + avatar) added to the
    /// widest measured name to reach the window width.
    public static let rowChrome: CGFloat = 70
}

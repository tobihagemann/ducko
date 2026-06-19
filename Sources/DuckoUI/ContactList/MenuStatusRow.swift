import DuckoCore
import SwiftUI

/// A status row for SwiftUI menus: a colored dot, a label, and an active checkmark. Shared by the Contacts
/// header and the menu-bar status menus so the row treatment stays uniform across both surfaces.
///
/// A macOS menu item renders a single leading image (the colored dot takes that slot), so the active checkmark
/// is embedded into the title text — a separate trailing `Image` after a `Spacer()` is dropped by the menu.
struct MenuStatusRow: View {
    let status: PresenceService.PresenceStatus
    let label: String
    let isActive: Bool

    var body: some View {
        HStack {
            MenuStatusDot(status: status)
            if isActive {
                Text(label) + Text("  ") + Text(Image(systemName: "checkmark"))
            } else {
                Text(label)
            }
        }
    }
}

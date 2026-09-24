import DuckoCore
import SwiftUI

/// A status row for SwiftUI menus: a colored dot, a label, and a trailing mark. Shared by the Contacts
/// header and the menu-bar status menus so the row treatment stays uniform across both surfaces.
///
/// A macOS menu item renders a single leading image (the colored dot takes that slot), so the mark
/// is embedded into the title text — a separate trailing `Image` after a `Spacer()` is dropped by the menu.
struct MenuStatusRow: View {
    /// A checkmark for the active row, or a dash (the macOS mixed state) for a status only some accounts show.
    enum Mark {
        case none
        case checked
        case mixed

        var symbolName: String? {
            switch self {
            case .none: nil
            case .checked: "checkmark"
            case .mixed: "minus"
            }
        }
    }

    let status: PresenceService.PresenceStatus
    let label: String
    let mark: Mark

    var body: some View {
        HStack {
            MenuStatusDot(status: status)
            if let symbolName = mark.symbolName {
                Text("\(label)  \(Image(systemName: symbolName))")
            } else {
                Text(label)
            }
        }
    }
}

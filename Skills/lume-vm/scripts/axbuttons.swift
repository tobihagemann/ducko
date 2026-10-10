import AppKit
import ApplicationServices

// Lists or presses the pressable elements in an app's windows.
// Runs in the VM's GUI session, through `vm.sh ax`.
//   axbuttons list                 every app's AX windows and their pressable titles
//   axbuttons press <pid> <title>  press the first element whose title, or else description, matches, ignoring surrounding whitespace
func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(e, a as CFString, &v)
    return v
}

let pressable: Set<String> = [kAXButtonRole, kAXMenuItemRole, kAXMenuButtonRole, kAXPopUpButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, "AXLink"]

func pressables(_ e: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 12 else { return [] }
    var out: [AXUIElement] = []
    if let role = attr(e, kAXRoleAttribute) as? String, pressable.contains(role) { out.append(e) }
    for c in attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] { out += pressables(c, depth: depth + 1) }
    return out
}

func title(_ e: AXUIElement) -> String {
    (attr(e, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (attr(e, kAXDescriptionAttribute) as? String) ?? "-"
}

// Set on the system-wide element, the timeout covers every element; set on one element, it covers that one alone.
AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 2)

let args = CommandLine.arguments
if args.count == 2, args[1] == "list" {
    for app in NSWorkspace.shared.runningApplications {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        for w in attr(ax, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
            print(app.processIdentifier, app.localizedName ?? "?", "window:", title(w), "pressable:", pressables(w).map(title))
        }
    }
} else if args.count == 4, args[1] == "press", let pid = Int32(args[2]) {
    let ax = AXUIElementCreateApplication(pid)
    for w in attr(ax, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
        if let e = pressables(w).first(where: { title($0).trimmingCharacters(in: .whitespaces) == args[3] }) {
            // A press that opens a menu reports an error although the menu opens, so the result is not checked.
            AXUIElementPerformAction(e, kAXPressAction as CFString)
            exit(0)
        }
    }
    FileHandle.standardError.write(Data("no pressable element titled \(args[3])\n".utf8))
    exit(1)
} else {
    FileHandle.standardError.write(Data("usage: axbuttons list | press <pid> <title>\n".utf8))
    exit(2)
}

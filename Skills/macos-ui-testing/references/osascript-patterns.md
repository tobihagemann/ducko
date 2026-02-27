# osascript UI Scripting Patterns

## Contents

- Element addressing patterns
- Working with SwiftUI views
- Toolbar overflow items
- Sheet elements
- Secure text fields (passwords)
- Waiting for UI changes
- Error handling

## Element Addressing Patterns

osascript addresses elements via hierarchical paths through the accessibility tree:

```
tell application "System Events" to <action> of <element> of <parent> of window 1 of process "AppName"
```

### By index

```bash
# First text field in a group
osascript -e 'tell application "System Events" to set value of text field 1 of group 1 of window 1 of process "App" to "value"'

# Second button
osascript -e 'tell application "System Events" to click button 2 of group 1 of window 1 of process "App"'
```

### By name/description

```bash
# Button with specific title
osascript -e 'tell application "System Events" to click button "Submit" of group 1 of window 1 of process "App"'

# Text field with specific accessibility description
osascript -e 'tell application "System Events" to set value of text field "Email" of group 1 of window 1 of process "App" to "user@example.com"'
```

### Nested groups

SwiftUI views often nest elements in multiple group layers:

```bash
# Two levels deep
osascript -e 'tell application "System Events" to set value of text field 1 of group 1 of group 2 of window 1 of process "App" to "value"'
```

## Working with SwiftUI Views

SwiftUI maps views to accessibility elements:
- `Text` -> `static text`
- `TextField` -> `text field`
- `SecureField` -> `text field` (with `role description` = "secure text field")
- `Button` -> `button`
- `VStack/HStack/ZStack` -> `group`
- `List` -> `table` or `list`
- `Toggle` -> `checkbox`

### `set value` vs `keystroke` for text fields

`set value` updates the accessibility attribute directly but **does not trigger SwiftUI's `@State`/`@Binding` update**. Buttons that depend on form state (e.g., "Connect") will not enable.

Use `keystroke` instead when the app uses SwiftUI data bindings. This requires the app to be frontmost and the field focused, so combine with activation and click in a single osascript block (see Multi-Step Interaction Sequences in the main skill).

### Adding accessibility identifiers

For reliable automation, add identifiers to SwiftUI views:

```swift
TextField("Email", text: $email)
    .accessibilityIdentifier("emailField")
```

Then target by description:

```bash
osascript -e 'tell application "System Events" to get every text field of group 1 of window 1 of process "App" whose description is "emailField"'
```

## Toolbar Overflow Items

SwiftUI toolbar items may be hidden behind a `>>` overflow popup when the window is too narrow. These are accessible via `pop up button 1 of toolbar 1`:

```bash
# Open the overflow menu
osascript -e 'tell application "System Events" to click pop up button 1 of toolbar 1 of window 1 of process "App"'

# Click a specific item from the overflow menu
osascript -e 'tell application "System Events" to click menu item "New Chat" of menu 1 of pop up button 1 of toolbar 1 of window 1 of process "App"'
```

To combine in a single block:

```bash
osascript << 'APPLESCRIPT'
tell application "System Events"
    tell process "App"
        click pop up button 1 of toolbar 1 of window 1
        delay 0.5
        click menu item "New Chat" of menu 1 of pop up button 1 of toolbar 1 of window 1
    end tell
end tell
APPLESCRIPT
```

## Sheet Elements

SwiftUI `.sheet()` presentations appear as `sheet 1 of window 1`. Children are under the sheet, not the window:

```bash
# Elements inside a sheet
osascript -e 'tell application "System Events" to get entire contents of sheet 1 of window 1 of process "App"'

# Click a button inside a sheet
osascript -e 'tell application "System Events" to click button 2 of group 1 of sheet 1 of window 1 of process "App"'

# Set a text field inside a sheet
osascript -e 'tell application "System Events" to set value of text field 1 of group 1 of sheet 1 of window 1 of process "App" to "value"'
```

**Common mistake**: Addressing elements as `... of window 1` when a sheet is open. Elements are under `sheet 1 of window 1`, not `window 1`.

## Secure Text Fields (Passwords)

Secure text fields (SwiftUI `SecureField`) accept `set value` but return empty string on `get value` (the OS protects password readback):

```bash
# Setting works
osascript -e 'tell application "System Events" to set value of text field 2 of group 1 of window 1 of process "App" to "password123"'

# Reading returns empty
osascript -e 'tell application "System Events" to get value of text field 2 of group 1 of window 1 of process "App"'
# Output: ""
```

To verify a password was entered, check that the field is non-empty via `peekaboo see`.

## Waiting for UI Changes

After clicking a button that triggers navigation or async work, wait before reading new UI state:

```bash
# Click Connect button
osascript -e 'tell application "System Events" to click button "Submit" of group 1 of window 1 of process "App"'

# Wait for UI to update
sleep 2

# Check new state
peekaboo see --app App --json
```

For polling until a condition is met:

```bash
# Wait up to 10 seconds for a specific element to appear
for i in $(seq 1 10); do
    result=$(osascript -e 'tell application "System Events" to get every button of window 1 of process "App" whose name is "Done"' 2>&1)
    if [[ "$result" != "" && "$result" != *"error"* ]]; then
        echo "Element found"
        break
    fi
    sleep 1
done
```

## Error Handling

Common errors and their meanings:

| Error | Cause | Fix |
|---|---|---|
| `Can't get application "App"` | App not registered with Launch Services (common for SwiftPM-built apps) | Use process name instead (see below) |
| `Can't get window 1` | No windows open | Wait for app to initialize |
| `Can't get text field 1` | Element doesn't exist at that path | Explore hierarchy first |
| `NSCannotCreateScriptCommandError` | Accessibility permission denied | Grant in System Settings > Privacy > Accessibility |
| `(-25211)` | System Events not allowed | Grant Terminal/Claude accessibility access |

### Activating SwiftPM-built apps

`tell application "AppName" to activate` fails for SwiftPM executables because they are not registered with Launch Services. Use System Events instead:

```bash
# WRONG — fails with "Can't get application" (-1728)
osascript -e 'tell application "MyApp" to activate'

# CORRECT — works for any running process
osascript -e 'tell application "System Events" to set frontmost of process "MyApp" to true'
```

### Exploring unknown hierarchies

When element paths are unclear, explore incrementally:

```bash
# Step 1: Top-level window contents
osascript -e 'tell application "System Events" to get {role, description} of every UI element of window 1 of process "App"'

# Step 2: Dig into a group
osascript -e 'tell application "System Events" to get {role, description} of every UI element of group 1 of window 1 of process "App"'

# Step 3: Get all properties of a specific element
osascript -e 'tell application "System Events" to get properties of text field 1 of group 1 of window 1 of process "App"'
```

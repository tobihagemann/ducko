# osascript UI Scripting Patterns

## Contents

- Element addressing patterns
- Working with SwiftUI views
- Secure text fields (passwords)
- Waiting for UI changes
- Error handling

## Element Addressing Patterns

osascript addresses elements via a hierarchical path through the accessibility tree. The general pattern:

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

### Adding accessibility identifiers

For reliable automation, add identifiers to SwiftUI views:

```swift
TextField("Email", text: $email)
    .accessibilityIdentifier("emailField")
```

Then target by description (may vary by macOS version):

```bash
osascript -e 'tell application "System Events" to get every text field of group 1 of window 1 of process "App" whose description is "emailField"'
```

## Secure Text Fields (Passwords)

Secure text fields (SwiftUI `SecureField`) accept `set value` but return empty string on `get value` (by design — the OS protects password readback):

```bash
# Setting works
osascript -e 'tell application "System Events" to set value of text field 2 of group 1 of window 1 of process "App" to "password123"'

# Reading returns empty
osascript -e 'tell application "System Events" to get value of text field 2 of group 1 of window 1 of process "App"'
# Output: ""
```

To verify a password was entered, check that the field is non-empty via Peekaboo's `see` command (the element will show a non-empty value indicator).

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
| `Can't get application "App"` | App not running or wrong name | Check `peekaboo list apps` for exact name |
| `Can't get window 1` | No windows open | Wait for app to initialize |
| `Can't get text field 1` | Element doesn't exist at that path | Explore hierarchy first |
| `NSCannotCreateScriptCommandError` | Accessibility permission denied | Grant in System Settings > Privacy > Accessibility |
| `(-25211)` | System Events not allowed | Grant Terminal/Claude accessibility access |

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

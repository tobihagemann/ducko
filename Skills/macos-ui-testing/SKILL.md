---
name: macos-ui-testing
description: "Background-safe macOS app UI testing using Peekaboo CLI and osascript. This skill should be used when the user asks to \"test the app UI\", \"check the UI\", \"interact with the running app\", \"take a screenshot of the app\", \"fill in the form\", \"click the button\", \"verify the UI state\", \"automate the app\", or wants to automate interaction with a running macOS application without stealing keyboard/mouse focus from the user."
---

# macOS UI Testing (Background-Safe)

Run the `/peekaboo` skill first to load full Peekaboo CLI reference. This skill adds background-safe patterns on top.

Test and interact with running macOS applications without stealing focus. Combine Peekaboo CLI for reading UI state and element-targeted clicks with osascript for background-safe text input and value reading.

## Background Safety Rules

Simulated keystrokes (`peekaboo type`, `peekaboo paste`, `peekaboo hotkey`) go to the **frontmost app**, not the target app. Always use background-safe alternatives.

| Action | Background-Safe | Command |
|---|---|---|
| Read UI tree | Yes | `peekaboo see --app APP --json` |
| Screenshot | Yes | `peekaboo image --window-id WID` |
| Click element | Yes | `peekaboo click --no-auto-focus --on ELEM --app APP` |
| Set text value | Yes* | `osascript` with `set value of` |
| Read text value | Yes | `osascript` with `get value of` |
| Click button | Yes | `osascript` with `click button` |
| Type keystrokes | **NO** | Lands in frontmost app |
| Paste (Cmd+V) | **NO** | Lands in frontmost app |
| Hotkeys | **NO** | Lands in frontmost app |

*`set value` updates the accessibility layer but **does not trigger SwiftUI `@State` bindings**. Use `keystroke` inside a single osascript block when SwiftUI binding updates are needed (see Multi-Step Interaction Sequences below).

## Workflow

### Step 1: Launch the App

```bash
# For SwiftPM-built apps:
swift run AppName &>/dev/null &
APP_PID=$!
sleep 3

# For installed apps:
open -a "AppName"
```

### Step 2: Verify the App Is Running

```bash
peekaboo list apps | grep -i AppName
```

### Step 3: Read the UI Tree

```bash
peekaboo see --app AppName --json
```

Parse the JSON output to find element IDs (`elem_N`), roles, and labels.

### Step 4: Take a Screenshot

Resolve the window ID first, then capture by ID:

```bash
peekaboo list windows --app AppName
peekaboo image --window-id WID --path /tmp/screenshot.png
```

### Step 5: Interact with Elements

**Click an element** (accessibility API, no focus needed):

```bash
peekaboo click --no-auto-focus --on elem_4 --app AppName
```

**Set a text field value** (background-safe, but does NOT trigger SwiftUI bindings):

```bash
osascript -e 'tell application "System Events" to set value of text field 1 of group 1 of window 1 of process "AppName" to "text"'
```

**Read a text field value**:

```bash
osascript -e 'tell application "System Events" to get value of text field 1 of group 1 of window 1 of process "AppName"'
```

**Click a button by name**:

```bash
osascript -e 'tell application "System Events" to click button "Submit" of group 1 of window 1 of process "AppName"'
```

### Step 6: Verify Results

Take another screenshot or read values back to confirm the interaction succeeded.

### Step 7: Stop the App

```bash
kill $APP_PID
```

## Multi-Step Interaction Sequences

Each tool call returns focus to the terminal. Multi-step flows **must** be in a single `osascript` heredoc -- splitting across tool calls loses focus between steps.

```bash
osascript << 'APPLESCRIPT'
tell application "System Events"
    set frontmost of process "AppName" to true
    delay 0.5
    tell process "AppName"
        click text field 1 of group 1 of window 1
        delay 0.3
        keystroke "username"
        delay 0.2
        keystroke tab
        delay 0.2
        keystroke "password"
        delay 0.3
        click button 1 of group 1 of window 1
    end tell
end tell
APPLESCRIPT
```

This pattern uses `keystroke` (triggers SwiftUI bindings) and keeps focus on the target app throughout the sequence.

**Important**: Use `osascript << 'APPLESCRIPT'` heredoc syntax (not `osascript -e`) to avoid shell escaping issues.

## osascript Element Discovery

When the UI hierarchy is unknown, explore it incrementally with osascript. See [references/osascript-patterns.md](references/osascript-patterns.md) for element addressing patterns and exploration techniques.

## Peekaboo Focus Timeout Issue

Peekaboo's `click`, `type`, `image` with `--app` try to activate the app first. For SwiftPM-built apps this often times out because `NSRunningApplication.activate()` is not acknowledged.

**Workarounds:**
- Use `--no-auto-focus` on `click` commands
- Use `--window-id WID` instead of `--app` for `image` captures
- `see --app` works fine (read-only, skips focus)

**Caveat with `--no-auto-focus`**: Clicks use absolute screen coordinates. If another window overlaps the target, the click hits the wrong window. Prefer `osascript` click (accessibility API, position-independent) for reliable button clicks.

## Additional Resources

- Full Peekaboo CLI reference: `peekaboo --help` or `peekaboo <subcommand> --help`
- osascript UI scripting patterns: [references/osascript-patterns.md](references/osascript-patterns.md)

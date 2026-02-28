---
name: ducko-ui
description: End-to-end UI testing for the Ducko macOS app using pre-built helper scripts. This skill should be used when the user asks to "test ducko", "test the app", "run E2E tests", "test the app end-to-end", "test the UI", "send a test message", or wants to verify DuckoApp works from login through messaging.
---

# Ducko UI Test

Run the `/macos-ui-testing` skill first to load generic macOS UI automation patterns. This skill provides Ducko-specific helper scripts on top.

End-to-end UI testing for DuckoApp with reusable shell scripts. Each script is a self-contained osascript wrapper that can be allowlisted individually in `settings.local.json`.

## Prerequisites

- Peekaboo CLI installed (`/opt/homebrew/bin/peekaboo`)
- Accessibility permissions granted for Terminal/Claude
- Test credentials stored in memory (never in committable files)

## Scripts

All scripts are in `scripts/` relative to this skill. Run from the repo root or use absolute paths.

Scripts rely on SwiftUI accessibility identifiers (e.g. `jid-field`, `message-field`) for reliable element targeting instead of fragile positional selectors.

| Script | Purpose | Arguments |
|---|---|---|
| `ducko-launch.sh` | Build and launch DuckoApp, output window ID | none |
| `ducko-login.sh` | Fill JID + password, click Connect | `JID PASSWORD` |
| `ducko-new-chat.sh` | Open New Chat sheet, fill JID, start chat | `JID` |
| `ducko-send.sh` | Type a message and send it | `MESSAGE` |
| `ducko-screenshot.sh` | Capture window screenshot | `[FILENAME]` (optional, absolute path or relative to `/private/tmp/claude/`) |
| `ducko-connect.sh` | Reconnect by restarting the app | none |
| `ducko-stop.sh` | Kill DuckoApp process | none |
| `ducko-window-id.sh` | Print window ID of DuckoApp (used by other scripts) | none |

## Workflow

### Fresh install E2E test

For first-time setup when no account exists:

```bash
SCRIPTS="Skills/ducko-ui/scripts"

# 1. Launch
WID=$($SCRIPTS/ducko-launch.sh)

# 2. Login (only needed for fresh install)
$SCRIPTS/ducko-login.sh "USER_JID" "PASSWORD_HERE"

# 3. Screenshot to verify
$SCRIPTS/ducko-screenshot.sh "after-login.png"

# 4. Start a conversation
$SCRIPTS/ducko-new-chat.sh "CHAT_PARTNER_JID"

# 5. Send messages
$SCRIPTS/ducko-send.sh "Hello from Ducko!"
$SCRIPTS/ducko-send.sh "Testing 1-2-3"

# 6. Screenshot to verify
$SCRIPTS/ducko-screenshot.sh "after-messages.png"

# 7. Cleanup
$SCRIPTS/ducko-stop.sh
```

### Relaunch E2E test (existing account)

When an account already exists, the app auto-connects on launch using Keychain credentials. No login step needed:

```bash
SCRIPTS="Skills/ducko-ui/scripts"

# 1. Launch (auto-connects)
WID=$($SCRIPTS/ducko-launch.sh)
sleep 3  # wait for auto-connect

# 2. Screenshot to verify connected state
$SCRIPTS/ducko-screenshot.sh "after-relaunch.png"

# 3. Send a message
$SCRIPTS/ducko-send.sh "Relaunch test message"

# 4. Cleanup
$SCRIPTS/ducko-stop.sh
```

### Quick message test (app already running)

```bash
SCRIPTS="Skills/ducko-ui/scripts"
$SCRIPTS/ducko-send.sh "Quick test message"
$SCRIPTS/ducko-screenshot.sh
```

### Reconnect (app disconnected)

If the app is running but disconnected (e.g. network drop), restart it to trigger auto-connect:

```bash
SCRIPTS="Skills/ducko-ui/scripts"
$SCRIPTS/ducko-connect.sh
```

## Permission Allowlisting

To allow these scripts in `settings.local.json` without prompts:

```json
{
  "permissions": {
    "allow": [
      "Bash(Skills/ducko-ui/scripts/*)"
    ]
  }
}
```

## Notes

- Scripts use `keystroke` (not `set value`) to trigger SwiftUI bindings
- App activation uses `set frontmost of process` (works with SwiftPM builds)
- Multi-step interactions are bundled in single osascript blocks to avoid focus loss
- Arguments passed via `osascript - "$ARG" << 'APPLESCRIPT'` + `on run argv` (no shell injection)
- Credentials are arguments, never hardcoded
- All scripts require `dangerouslyDisableSandbox: true` — the launch script for `swift build`, and all osascript scripts because the sandbox blocks System Events' `hiservices-xpcservice`
- Element targeting uses `entire contents` + `AXIdentifier` matching for reliability across window sizes

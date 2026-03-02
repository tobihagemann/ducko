---
name: ducko-ui
description: End-to-end UI testing for the Ducko macOS app using pre-built helper scripts. This skill should be used when the user asks to "test ducko", "test the app", "run E2E tests", "test the app end-to-end", "test the UI", "send a test message", or wants to verify DuckoApp works from login through messaging.
---

# Ducko UI Test

Run the `/macos-ui-testing` skill first to load generic macOS UI automation patterns. This skill provides Ducko-specific helper scripts on top.

End-to-end UI testing for DuckoApp with reusable shell scripts. Each script is a self-contained osascript wrapper that can be allowlisted individually in `settings.local.json`.

## Window Architecture

DuckoApp uses separate windows instead of a single NavigationSplitView:

- **Contact List Window** (`id: "contacts"`) — singleton window showing roster contacts grouped by roster groups, status bar with presence picker, and searchable toolbar. This is the main window shown after login.
- **Chat Windows** (`id: "chat"`, keyed by JID string) — per-conversation windows opened by double-clicking a contact or using "New Chat". Each window has its own message state.
- **MenuBarExtra** — quick status switching, "Show Contact List", and "Quit Ducko".

## Prerequisites

- Peekaboo CLI installed (`/opt/homebrew/bin/peekaboo`)
- Accessibility permissions granted for Terminal/Claude

## Scripts

All scripts are in `scripts/` relative to this skill. Run from the repo root or use absolute paths.

Scripts rely on SwiftUI accessibility identifiers for reliable element targeting instead of fragile positional selectors.

### Accessibility Identifiers

| Identifier | Element | Window |
|---|---|---|
| `contact-list` | Contact list view | Contacts |
| `contact-row-{jid}` | Individual contact row | Contacts |
| `status-picker` | Presence status menu | Contacts |
| `status-message-field` | Status message text field | Contacts |
| `search-contacts` | Search field (via .searchable) | Contacts |
| `message-field` | Message input text field | Chat |
| `send-button` | Send message button | Chat |
| `new-chat-jid-field` | JID field in New Chat sheet | Contacts |
| `start-chat-button` | Start Chat button in sheet | Contacts |
| `add-contact-jid-field` | JID field in Add Contact sheet | Contacts |
| `add-contact-button` | Add Contact button in sheet | Contacts |
| `jid-field` | JID field in account setup | Contacts |
| `password-field` | Password field in account setup | Contacts |
| `connect-button` | Connect button in account setup | Contacts |
| `chat-tab-bar` | Tab bar (visible when >1 tab) | Chat |
| `chat-tab-{jid}` | Individual chat tab | Chat |
| `typing-indicator` | Typing indicator dots | Chat |
| `reply-compose-bar` | Reply/edit compose bar above input | Chat |
| `message-search-bar` | Cmd+F search bar in chat | Chat |
| `sort-mode-menu` | View options menu (sort/filter) | Contacts |

### Script Reference

| Script | Purpose | Arguments |
|---|---|---|
| `ducko-launch.sh` | Build and launch DuckoApp, output window ID | none |
| `ducko-login.sh` | Fill JID + password, click Connect | `JID PASSWORD` |
| `ducko-new-chat.sh` | Open New Chat sheet from contact list, fill JID, start chat | `JID` |
| `ducko-add-contact.sh` | Open Add Contact sheet from contact list, fill JID, submit | `JID` |
| `ducko-send.sh` | Type a message and send it in the active chat window | `MESSAGE` |
| `ducko-screenshot.sh` | Capture window screenshot | `[FILENAME]` (optional, absolute path or relative to `/private/tmp/claude/`) |
| `ducko-search.sh` | Toggle Cmd+F search bar in chat, optionally search | `[QUERY]` (optional) |
| `ducko-reply.sh` | Right-click a message and select Reply | `[TEXT]` (optional, matches message containing TEXT; default: last message) |
| `ducko-sort.sh` | Open View Options menu, optionally select sort/filter | `[alphabetical\|byStatus\|recentConversation\|hideOffline]` (optional) |
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

# 3. Screenshot to verify contact list
$SCRIPTS/ducko-screenshot.sh "after-login.png"

# 4. Start a conversation (opens a chat window)
$SCRIPTS/ducko-new-chat.sh "CHAT_PARTNER_JID"

# 5. Send messages in the chat window
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

# 1. Launch (auto-connects, shows contact list)
WID=$($SCRIPTS/ducko-launch.sh)
sleep 3  # wait for auto-connect

# 2. Screenshot to verify contact list
$SCRIPTS/ducko-screenshot.sh "after-relaunch.png"

# 3. Start a chat and send a message
$SCRIPTS/ducko-new-chat.sh "CHAT_PARTNER_JID"
$SCRIPTS/ducko-send.sh "Relaunch test message"

# 4. Cleanup
$SCRIPTS/ducko-stop.sh
```

### Quick message test (chat window already open)

```bash
SCRIPTS="Skills/ducko-ui/scripts"
$SCRIPTS/ducko-send.sh "Quick test message"
$SCRIPTS/ducko-screenshot.sh
```

### Chat UI polish test (message grouping, search, reply)

Tests features from Prompt 18 — message grouping, search bar, reply compose bar, and context menu:

```bash
SCRIPTS="Skills/ducko-ui/scripts"

# 1. Launch and open a chat
WID=$($SCRIPTS/ducko-launch.sh)
sleep 3
$SCRIPTS/ducko-new-chat.sh "CHAT_PARTNER_JID"
sleep 2

# 2. Send grouped messages (within 2-min window → single timestamp)
$SCRIPTS/ducko-send.sh "Message one"
sleep 1
$SCRIPTS/ducko-send.sh "Message two"
sleep 1
$SCRIPTS/ducko-send.sh "Message three"
$SCRIPTS/ducko-screenshot.sh "grouped-messages.png"

# 3. Test Cmd+F search
$SCRIPTS/ducko-search.sh "Message two"
$SCRIPTS/ducko-screenshot.sh "search-results.png"
$SCRIPTS/ducko-search.sh  # toggle search off

# 4. Test reply compose bar
$SCRIPTS/ducko-reply.sh "Message one"
$SCRIPTS/ducko-screenshot.sh "reply-bar.png"

# 5. Cleanup
$SCRIPTS/ducko-stop.sh
```

### Contact list sort/filter test

Tests sort modes and hide-offline toggle:

```bash
SCRIPTS="Skills/ducko-ui/scripts"

# 1. Launch
WID=$($SCRIPTS/ducko-launch.sh)
sleep 3

# 2. Open sort menu (visual verification)
$SCRIPTS/ducko-sort.sh
$SCRIPTS/ducko-screenshot.sh "sort-menu.png"

# 3. Select a sort mode
$SCRIPTS/ducko-sort.sh byStatus
$SCRIPTS/ducko-screenshot.sh "sorted-by-status.png"

# 4. Toggle hide offline
$SCRIPTS/ducko-sort.sh hideOffline
$SCRIPTS/ducko-screenshot.sh "hide-offline.png"

# 5. Cleanup
$SCRIPTS/ducko-stop.sh
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
- The contact list window is a singleton (`Window`, not `WindowGroup`). The "New Chat" button is in its toolbar.
- Chat windows are data-driven (`WindowGroup` keyed by JID string). `ducko-send.sh` targets the frontmost chat window.

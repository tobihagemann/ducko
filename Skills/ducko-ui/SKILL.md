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
| `join-room-toolbar-button` | Join Room toolbar button | Contacts |
| `room-row-{jid}` | Room row in Rooms section | Contacts |
| `room-invite-banner` | Pending room invitation banner | Contacts |
| `room-jid-field` | Room JID field in Join Room dialog | Contacts |
| `room-nickname-field` | Nickname field in Join Room dialog | Contacts |
| `join-room-button` | Join button in Join Room dialog | Contacts |
| `browse-rooms-button` | Browse Rooms button in Join Room dialog | Contacts |
| `room-subject-view` | Room topic banner (editable) | Chat |
| `participant-sidebar` | Participant sidebar list | Chat |
| `toggle-participant-sidebar` | Sidebar toggle button (person.2 icon) | Chat |
| `attachment-button` | Paperclip file picker button | Chat |
| `pending-attachments` | Pending attachment bar above input | Chat |
| `file-drop-overlay` | Drag-and-drop overlay | Chat |
| `attachment-view` | Attachment in message bubble | Chat |
| `image-preview` | Full-size image preview sheet | Chat |
| `link-preview` | Link preview card in message bubble | Chat |
| `my-profile-toolbar-button` | My Profile toolbar button | Contacts |
| `profile-edit-view` | Profile editing sheet | Contacts |
| `profile-fullname-field` | Full Name text field | Profile |
| `profile-nickname-field` | Nickname text field | Profile |
| `profile-given-name-field` | Given Name text field | Profile |
| `profile-family-name-field` | Family Name text field | Profile |
| `profile-email-field-{index}` | Email text field (0-indexed) | Profile |
| `profile-phone-field-{index}` | Phone text field (0-indexed) | Profile |
| `profile-org-field` | Organization text field | Profile |
| `profile-title-field` | Title text field | Profile |
| `profile-save-button` | Save button | Profile |
| `profile-cancel-button` | Cancel button | Profile |

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
| `ducko-join-room.sh` | Open Join Room sheet, fill room JID + nickname, join | `ROOM_JID [NICKNAME]` |
| `ducko-toggle-sidebar.sh` | Toggle participant sidebar in active groupchat window | none |
| `ducko-focus-contacts.sh` | Raise the Contacts window to the front | none |
| `ducko-connect.sh` | Reconnect by restarting the app | none |
| `ducko-profile.sh` | Open My Profile sheet from contact list toolbar | none |
| `ducko-preferences.sh` | Open Preferences (Settings) window via Cmd+, | none |
| `ducko-preferences-tab.sh` | Switch to a specific tab in the Preferences window | `<General\|Accounts\|Appearance\|Notifications\|Advanced>` |
| `ducko-stop.sh` | Kill DuckoApp process | none |
| `ducko-window-id.sh` | Print window ID of DuckoApp (used by other scripts) | none |

## Workflow

### Fresh install E2E test

For first-time setup when no account exists:

```bash
SCRIPTS="Skills/ducko-ui/scripts"

# 1. Launch
$SCRIPTS/ducko-launch.sh

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
$SCRIPTS/ducko-launch.sh

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
$SCRIPTS/ducko-launch.sh
$SCRIPTS/ducko-new-chat.sh "CHAT_PARTNER_JID"

# 2. Send grouped messages (within 2-min window → single timestamp)
$SCRIPTS/ducko-send.sh "Message one"
$SCRIPTS/ducko-send.sh "Message two"
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
$SCRIPTS/ducko-launch.sh

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

### MUC (Group Chat) test

Tests MUC features — join room, send group message, toggle participant sidebar:

```bash
SCRIPTS="Skills/ducko-ui/scripts"

# 1. Launch
$SCRIPTS/ducko-launch.sh

# 2. Join a room (opens Join Room dialog, fills fields, joins)
# The room appears in the "Rooms" section of the contact list
# and a chat window opens automatically.
$SCRIPTS/ducko-join-room.sh "room@conference.example.com" "mynick"

# 3. Screenshot the room chat
# Shows: room subject banner, sender nicknames (color-coded),
# participant sidebar toggle button (person.2 icon) in header
$SCRIPTS/ducko-screenshot.sh "muc-joined.png"

# 4. Send a group message
$SCRIPTS/ducko-send.sh "Hello room!"
$SCRIPTS/ducko-screenshot.sh "muc-chat.png"

# 5. Toggle participant sidebar
# Shows occupants grouped by affiliation (Owner, Admin, Member, etc.)
$SCRIPTS/ducko-toggle-sidebar.sh
$SCRIPTS/ducko-screenshot.sh "muc-sidebar.png"

# 6. Verify Rooms section in contact list
$SCRIPTS/ducko-focus-contacts.sh
$SCRIPTS/ducko-screenshot.sh "muc-rooms-section.png"

# 7. Cleanup
$SCRIPTS/ducko-stop.sh
```

### File attachment test

Tests file attachment features — paperclip picker, pending bar, and attachment rendering:

```bash
SCRIPTS="Skills/ducko-ui/scripts"

# 1. Launch and open a chat
$SCRIPTS/ducko-launch.sh
$SCRIPTS/ducko-new-chat.sh "CHAT_PARTNER_JID"

# 2. Screenshot to verify attachment button (paperclip) is visible
$SCRIPTS/ducko-screenshot.sh "attachment-button.png"

# 3. Send a message with a URL to verify link preview
$SCRIPTS/ducko-send.sh "Check out https://example.com"
$SCRIPTS/ducko-screenshot.sh "link-preview.png"

# 4. Cleanup
$SCRIPTS/ducko-stop.sh
```

### Preferences window test

Tests the Preferences window — open via Cmd+,, navigate tabs, verify account management:

```bash
SCRIPTS="Skills/ducko-ui/scripts"

# 1. Launch
$SCRIPTS/ducko-launch.sh

# 2. Open Preferences (Cmd+,)
$SCRIPTS/ducko-preferences.sh

# 3. Screenshot to verify preferences window (General tab by default)
$SCRIPTS/ducko-screenshot.sh "preferences-general.png"

# 4. Navigate to Accounts tab
$SCRIPTS/ducko-preferences-tab.sh Accounts
$SCRIPTS/ducko-screenshot.sh "preferences-accounts.png"

# 5. Navigate to Appearance tab (theme grid with live preview bubbles)
$SCRIPTS/ducko-preferences-tab.sh Appearance
$SCRIPTS/ducko-screenshot.sh "preferences-appearance.png"

# 6. Navigate to Notifications and Advanced tabs
$SCRIPTS/ducko-preferences-tab.sh Notifications
$SCRIPTS/ducko-screenshot.sh "preferences-notifications.png"
$SCRIPTS/ducko-preferences-tab.sh Advanced
$SCRIPTS/ducko-screenshot.sh "preferences-advanced.png"

# 7. Cleanup
$SCRIPTS/ducko-stop.sh
```

### Profile editing test

Tests the vCard profile editing flow — open profile sheet, verify fields:

```bash
SCRIPTS="Skills/ducko-ui/scripts"

# 1. Launch (account must exist)
$SCRIPTS/ducko-launch.sh

# 2. Open My Profile sheet from toolbar
$SCRIPTS/ducko-profile.sh

# 3. Screenshot to verify profile fields loaded
$SCRIPTS/ducko-screenshot.sh "profile-edit.png"

# 4. Cleanup
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

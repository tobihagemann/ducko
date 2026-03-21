---
name: ducko-ui
description: "End-to-end UI testing for the Ducko macOS app using pre-built helper scripts. This skill should be used when the user asks to \"test ducko\", \"test the app\", \"run E2E tests\", \"test the app end-to-end\", \"test the UI\", \"send a test message\", or wants to verify DuckoApp works from login through messaging."
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
| `room-settings-menu-item` | "Room Settings..." context menu item | Contacts |
| `room-settings-view` | Room settings sheet (tabs + destroy) | Room Settings |
| `room-settings-destroy` | Destroy Room button | Room Settings |
| `room-config-view` | Room config form (General tab) | Room Settings |
| `room-config-save` | Save config button | Room Settings |
| `affiliation-list-view` | Affiliation list (Members tab) | Room Settings |
| `affiliation-jid-field` | JID input for adding affiliation | Room Settings |
| `affiliation-add-button` | Add affiliation button | Room Settings |
| `change-nickname-menu-item` | "Change Nickname…" on self in sidebar | Chat (sidebar) |
| `change-nickname-field` | Nickname text field in change alert | Chat (sidebar) |
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
| `profile-avatar-preview` | Avatar preview image/initials | Profile |
| `profile-change-photo-button` | Change Photo button | Profile |
| `profile-remove-photo-button` | Remove Photo button | Profile |
| `profile-save-button` | Save button | Profile |
| `profile-cancel-button` | Cancel button | Profile |
| `bookmarks-toolbar-button` | Bookmarks toolbar button | Contacts |
| `bookmark-row-{jid}` | Individual bookmark row | Bookmarks |
| `add-bookmark-button` | Add Bookmark toolbar button | Bookmarks |
| `bookmark-jid-field` | Room JID field in Add Bookmark sheet | Bookmarks |
| `bookmark-nickname-field` | Nickname field in Add Bookmark sheet | Bookmarks |
| `bookmark-autojoin-toggle` | Auto-join toggle in Add Bookmark sheet | Bookmarks |
| `add-bookmark-confirm-button` | Add button in Add Bookmark sheet | Bookmarks |
| `remove-bookmark-button` | Remove bookmark button (per row) | Bookmarks |
| `chatStatesToggle` | Chat states (typing indicators) toggle | Preferences (Chat) |
| `displayedMarkersToggle` | Displayed markers (read receipts) toggle | Preferences (Chat) |
| `requireTLSToggle` | Require TLS toggle | Account Edit |
| `tlsVersion` | TLS Version label | Connection Info |
| `cipherSuite` | Cipher Suite label | Connection Info |
| `certSubject` | Certificate Subject label | Connection Info |
| `certIssuer` | Certificate Issuer label | Connection Info |
| `certExpiry` | Certificate Expiry label | Connection Info |
| `certFingerprint` | Certificate SHA-256 fingerprint | Connection Info |
| `retract-button` | Retract context menu button (own msgs) | Chat |
| `moderate-button` | Moderate context menu button (other users' msgs) | Chat |
| `retracted-message` | Retracted message tombstone | Chat |
| `setup-mode-picker` | Login/Register segmented control | Account Setup |
| `register-server-field` | Server domain field (Register mode) | Account Setup |
| `register-username-field` | Username field (Register mode) | Account Setup |
| `register-password-field` | Password field (Register mode) | Account Setup |
| `register-email-field` | Email field (Register mode) | Account Setup |
| `register-button` | Register button (Register mode) | Account Setup |
| `channel-search-field` | Channel search keyword field | Join Room |
| `channel-search-button` | Channel search button | Join Room |
| `new-password-field` | New password field | Change Password |
| `confirm-password-field` | Confirm password field | Change Password |
| `encrypted-indicator` | Lock icon on encrypted messages | Chat |
| `encryption-menu` | Encryption menu button in chat header | Chat |
| `device-fingerprints-sheet` | Device fingerprints sheet | Chat |
| `device-row-{deviceID}` | Individual device row | Device Fingerprints |
| `trust-button-{deviceID}` | Trust device button | Device Fingerprints |
| `untrust-button-{deviceID}` | Untrust device button | Device Fingerprints |
| `verify-button-{deviceID}` | Verify device button | Device Fingerprints |
| `encryptByDefaultToggle` | Encrypt by default preference toggle | Preferences (Chat) |
| `tofuToggle` | Trust on first use preference toggle | Preferences (Chat) |
| `file-transfer-banner` | Incoming file transfer/request banner | Chat |
| `accept-file-transfer-button` | Accept button on incoming file transfer | Chat |
| `decline-file-transfer-button` | Decline button on incoming file transfer | Chat |
| `fulfill-file-request-button` | Fulfill button on incoming file request | Chat |
| `decline-file-request-button` | Decline button on incoming file request | Chat |
| `accept-content-add-button` | Accept button on content-add offer | Chat |
| `decline-content-add-button` | Decline button on content-add offer | Chat |
| `cancel-account-button` | Cancel Account button | Account Detail |
| `check-registration-button` | Check Registration button | Account Detail |
| `registration-form-sheet` | Registration form sheet | Registration |
| `registration-submit-button` | Submit button in registration form | Registration |
| `registration-username-field` | Username field in registration form | Registration |
| `registration-password-field` | Password field in registration form | Registration |
| `registration-email-field` | Email field in registration form | Registration |

## Context Menu Features

### Contact Row

Right-click a contact row in the contact list:

- **Start Chat** — open a chat window with the contact
- **Pin / Unpin** — pin or unpin the contact to the top of the list
- **Mute / Unmute** — mute or unmute notifications
- **Rename** — set a local alias for the contact
- **Block / Unblock** — block or unblock the contact
- **Remove Contact** — remove from roster

### Room Row

Right-click a room row in the Rooms section:

- **Open Chat** — open the room chat window
- **Pin / Unpin** — pin or unpin the room to the top of the list
- **Mute / Unmute** — mute or unmute notifications
- **Invite User** — invite a JID to the room
- **Room Settings** — open room config sheet (owner only)
- **Leave Room** — leave the room

### Participant Sidebar

Right-click a participant in the chat window sidebar:

- **Kick** — kick participant (moderator required)
- **Ban** — ban participant (admin/owner required)
- **Grant Voice** — grant voice to visitor (moderator required)
- **Revoke Voice** — revoke voice from participant (moderator required)
- **Change Nickname** — change own nickname (self only)

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
| `ducko-room-settings.sh` | Open Room Settings sheet via context menu | `ROOM_JID` |
| `ducko-connect.sh` | Reconnect by restarting the app | none |
| `ducko-profile.sh` | Open My Profile sheet from contact list toolbar | none |
| `ducko-avatar.sh` | Upload an avatar image via profile sheet | `IMAGE_PATH` |
| `ducko-avatar-remove.sh` | Remove current avatar via profile sheet | none |
| `ducko-preferences.sh` | Open Preferences (Settings) window via Cmd+, | none |
| `ducko-preferences-tab.sh` | Switch to a specific tab in the Preferences window | `<General\|Accounts\|Chat\|Appearance\|Notifications\|Advanced>` |
| `ducko-status.sh` | Set presence status and optional status message | `STATUS [MESSAGE]` (`STATUS`: available\|away\|xa\|dnd\|offline) |
| `ducko-bookmarks.sh` | Open the Bookmarks sheet from contact list toolbar | none |
| `ducko-add-bookmark.sh` | Add a bookmark via the Bookmarks sheet | `ROOM_JID [NICKNAME]` |
| `ducko-remove-bookmark.sh` | Remove a bookmark from the Bookmarks sheet | `ROOM_JID` |
| `ducko-leave-room.sh` | Leave a room via context menu | `ROOM_JID` |
| `ducko-retract.sh` | Retract a message via context menu | `[TEXT]` (optional, matches message containing TEXT; default: last message) |
| `ducko-moderate.sh` | Moderate (remove) a message via context menu | `[TEXT]` (optional, matches message containing TEXT; default: last message) |
| `ducko-encrypt.sh` | Open encryption menu, optionally toggle or open fingerprints | `[on\|off\|fingerprints]` (optional) |
| `ducko-device-trust.sh` | Trust/untrust/verify an OMEMO device | `DEVICE_ID ACTION` (`ACTION`: trust\|untrust\|verify) |
| `ducko-attach.sh` | Attach a file via the attachment button in chat | `FILE_PATH` |
| `ducko-change-nickname.sh` | Change MUC nickname via participant sidebar context menu | `NICKNAME` |
| `ducko-room-topic.sh` | View or set the room topic | `[TEXT]` (optional; no args prints current topic) |
| `ducko-channel-search.sh` | Search for channels in the Join Room dialog | `QUERY` |
| `ducko-connection-info.sh` | Open Connection Info sheet from Preferences > Accounts | none |
| `ducko-register.sh` | Register a new account via in-band registration | `SERVER USERNAME PASSWORD [EMAIL]` |
| `ducko-change-password.sh` | Change account password via Preferences > Accounts | `NEW_PASSWORD` |
| `ducko-toggle-preference.sh` | Toggle any preference checkbox by identifier | `IDENTIFIER` (e.g., chatStatesToggle, encryptByDefaultToggle, tofuToggle) |
| `ducko-edit-profile.sh` | Edit profile fields and optionally save | `[--fullname NAME] [--nickname NICK] [--email EMAIL] [--save]` |
| `ducko-remove-contact.sh` | Remove a contact via context menu | `JID` |
| `ducko-invite-user.sh` | Invite a user to a room via context menu | `ROOM_JID INVITEE_JID` |
| `ducko-destroy-room.sh` | Destroy a room via Room Settings sheet | `ROOM_JID` |
| `ducko-room-config-save.sh` | Save room config in Room Settings sheet | `ROOM_JID` |
| `ducko-room-settings-tab.sh` | Switch to a tab in the Room Settings sheet | `<General\|Members>` |
| `ducko-add-affiliation.sh` | Add a JID to a room's affiliation list | `ROOM_JID JID` |
| `ducko-switch-tab.sh` | Switch to a specific chat tab by JID | `JID` |
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

### Room settings test

Tests room settings — open settings sheet from context menu, view config and affiliations:

```bash
SCRIPTS="Skills/ducko-ui/scripts"

# 1. Launch and join a room you own
$SCRIPTS/ducko-launch.sh
$SCRIPTS/ducko-join-room.sh "room@conference.example.com" "mynick"

# 2. Focus contacts and open Room Settings via context menu
$SCRIPTS/ducko-focus-contacts.sh
$SCRIPTS/ducko-room-settings.sh "room@conference.example.com"

# 3. Screenshot room settings (General tab with config form)
$SCRIPTS/ducko-screenshot.sh "room-settings-general.png"

# 4. Switch to Members tab to see affiliation list
$SCRIPTS/ducko-room-settings-tab.sh Members
$SCRIPTS/ducko-screenshot.sh "room-settings-members.png"

# 5. Cleanup
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

# 5. Navigate to Chat tab (chat states toggle)
$SCRIPTS/ducko-preferences-tab.sh Chat
$SCRIPTS/ducko-screenshot.sh "preferences-chat.png"

# 6. Navigate to Appearance tab (theme grid with live preview bubbles)
$SCRIPTS/ducko-preferences-tab.sh Appearance
$SCRIPTS/ducko-screenshot.sh "preferences-appearance.png"

# 7. Navigate to Notifications and Advanced tabs
$SCRIPTS/ducko-preferences-tab.sh Notifications
$SCRIPTS/ducko-screenshot.sh "preferences-notifications.png"
$SCRIPTS/ducko-preferences-tab.sh Advanced
$SCRIPTS/ducko-screenshot.sh "preferences-advanced.png"

# 8. Cleanup
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

### Avatar upload/remove test

Tests avatar upload and removal via the profile sheet:

```bash
SCRIPTS="Skills/ducko-ui/scripts"

# 1. Launch and open profile
$SCRIPTS/ducko-launch.sh
$SCRIPTS/ducko-profile.sh

# 2. Upload avatar
$SCRIPTS/ducko-avatar.sh "/path/to/test-image.png"
$SCRIPTS/ducko-screenshot.sh "avatar-uploaded.png"

# 3. Remove avatar
$SCRIPTS/ducko-avatar-remove.sh
$SCRIPTS/ducko-screenshot.sh "avatar-removed.png"

# 4. Cleanup
$SCRIPTS/ducko-stop.sh
```

### Device trust management test

Tests OMEMO encryption UI — encryption menu, device fingerprints sheet, and trust actions:

```bash
SCRIPTS="Skills/ducko-ui/scripts"

# 1. Launch and open a chat
$SCRIPTS/ducko-launch.sh
$SCRIPTS/ducko-new-chat.sh "CHAT_PARTNER_JID"

# 2. Screenshot to verify encryption menu button in chat header
$SCRIPTS/ducko-screenshot.sh "encryption-menu.png"

# 3. Open the device fingerprints sheet via the encryption menu
$SCRIPTS/ducko-encrypt.sh fingerprints
$SCRIPTS/ducko-screenshot.sh "device-fingerprints.png"

# 4. Verify device rows show trust status
# Each device row has trust-button-{deviceID} or untrust-button-{deviceID}
$SCRIPTS/ducko-screenshot.sh "device-trust-status.png"

# 5. Test encryption preference toggles
$SCRIPTS/ducko-preferences.sh
$SCRIPTS/ducko-preferences-tab.sh Chat
$SCRIPTS/ducko-screenshot.sh "encryption-preferences.png"

# 6. Cleanup
$SCRIPTS/ducko-stop.sh
```

### Presence/status test

Tests setting presence status and status message:

```bash
SCRIPTS="Skills/ducko-ui/scripts"

# 1. Launch
$SCRIPTS/ducko-launch.sh

# 2. Set status to Away
$SCRIPTS/ducko-status.sh away
$SCRIPTS/ducko-screenshot.sh "status-away.png"

# 3. Set status with a message
$SCRIPTS/ducko-status.sh dnd "In a meeting"
$SCRIPTS/ducko-screenshot.sh "status-dnd-message.png"

# 4. Back to Available
$SCRIPTS/ducko-status.sh available
$SCRIPTS/ducko-screenshot.sh "status-available.png"

# 5. Cleanup
$SCRIPTS/ducko-stop.sh
```

### Bookmarks management test

Tests bookmark lifecycle — open bookmarks, add, verify, remove:

```bash
SCRIPTS="Skills/ducko-ui/scripts"

# 1. Launch
$SCRIPTS/ducko-launch.sh

# 2. Open bookmarks
$SCRIPTS/ducko-bookmarks.sh
$SCRIPTS/ducko-screenshot.sh "bookmarks-list.png"

# 3. Add a bookmark
$SCRIPTS/ducko-add-bookmark.sh "room@conference.example.com" "mynick"
$SCRIPTS/ducko-screenshot.sh "bookmark-added.png"

# 4. Remove the bookmark
$SCRIPTS/ducko-remove-bookmark.sh "room@conference.example.com"
$SCRIPTS/ducko-screenshot.sh "bookmark-removed.png"

# 5. Cleanup
$SCRIPTS/ducko-stop.sh
```

### Message retraction test

Tests sending and retracting a message:

```bash
SCRIPTS="Skills/ducko-ui/scripts"

# 1. Launch and open a chat
$SCRIPTS/ducko-launch.sh
$SCRIPTS/ducko-new-chat.sh "CHAT_PARTNER_JID"

# 2. Send a message
$SCRIPTS/ducko-send.sh "This message will be retracted"
$SCRIPTS/ducko-screenshot.sh "before-retract.png"

# 3. Retract the message
$SCRIPTS/ducko-retract.sh "This message will be retracted"
$SCRIPTS/ducko-screenshot.sh "after-retract.png"

# 4. Cleanup
$SCRIPTS/ducko-stop.sh
```

### OMEMO encryption test

Tests encryption toggle, device fingerprints sheet, and device trust:

```bash
SCRIPTS="Skills/ducko-ui/scripts"

# 1. Launch and open a chat
$SCRIPTS/ducko-launch.sh
$SCRIPTS/ducko-new-chat.sh "CHAT_PARTNER_JID"

# 2. Enable encryption
$SCRIPTS/ducko-encrypt.sh on
$SCRIPTS/ducko-screenshot.sh "encryption-enabled.png"

# 3. Open device fingerprints sheet
$SCRIPTS/ducko-encrypt.sh fingerprints
$SCRIPTS/ducko-screenshot.sh "device-fingerprints.png"

# 4. Trust a device (replace DEVICE_ID with actual ID from screenshot)
# $SCRIPTS/ducko-device-trust.sh 12345 trust
# $SCRIPTS/ducko-screenshot.sh "device-trusted.png"

# 5. Cleanup
$SCRIPTS/ducko-stop.sh
```

### Room management test

Tests full room lifecycle — join, topic, nickname, file attachment, leave:

```bash
SCRIPTS="Skills/ducko-ui/scripts"

# 1. Launch and join a room
$SCRIPTS/ducko-launch.sh
$SCRIPTS/ducko-join-room.sh "room@conference.example.com" "mynick"

# 2. View current topic
$SCRIPTS/ducko-room-topic.sh
$SCRIPTS/ducko-screenshot.sh "room-topic-view.png"

# 3. Set a new topic
$SCRIPTS/ducko-room-topic.sh "Welcome to the test room!"
$SCRIPTS/ducko-screenshot.sh "room-topic-set.png"

# 4. Toggle sidebar and change nickname
$SCRIPTS/ducko-toggle-sidebar.sh
$SCRIPTS/ducko-change-nickname.sh "newnick"
$SCRIPTS/ducko-screenshot.sh "nickname-changed.png"

# 5. Leave the room
$SCRIPTS/ducko-focus-contacts.sh
$SCRIPTS/ducko-leave-room.sh "room@conference.example.com"
$SCRIPTS/ducko-screenshot.sh "room-left.png"

# 6. Cleanup
$SCRIPTS/ducko-stop.sh
```

### File attachment test (full)

Tests attaching and sending a file:

```bash
SCRIPTS="Skills/ducko-ui/scripts"

# 1. Launch and open a chat
$SCRIPTS/ducko-launch.sh
$SCRIPTS/ducko-new-chat.sh "CHAT_PARTNER_JID"

# 2. Attach a file
$SCRIPTS/ducko-attach.sh "/path/to/test-file.png"
$SCRIPTS/ducko-screenshot.sh "file-attached.png"

# 3. Send (the attached file appears in pending-attachments bar, send delivers it)
$SCRIPTS/ducko-send.sh "Here's a file"
$SCRIPTS/ducko-screenshot.sh "file-sent.png"

# 4. Cleanup
$SCRIPTS/ducko-stop.sh
```

### Connection info test

Tests viewing TLS connection details:

```bash
SCRIPTS="Skills/ducko-ui/scripts"

# 1. Launch (must be connected)
$SCRIPTS/ducko-launch.sh

# 2. Open connection info
$SCRIPTS/ducko-connection-info.sh
$SCRIPTS/ducko-screenshot.sh "connection-info.png"

# 3. Cleanup
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
- Element targeting uses `entire contents` + `AXIdentifier` matching for reliability across window sizes
- The contact list window is a singleton (`Window`, not `WindowGroup`). The "New Chat" button is in its toolbar.
- Chat windows are data-driven (`WindowGroup` keyed by JID string). `ducko-send.sh` targets the frontmost chat window.

---
name: ducko-cli
description: "Operate the Ducko XMPP CLI tool. Use when asked to send XMPP messages, start an interactive XMPP session, list accounts, check roster, view history, manage presence, or test the CLI. Covers running commands, authentication, output formats, and all subcommands."
---

# Ducko CLI

## Quick Start

```
ducko <subcommand> [options]
ducko --help
```

Default subcommand is `interactive` (REPL mode).

## Authentication

Password lookup order: macOS Keychain first, then prompt on `/dev/tty` if stdin is a TTY. Accounts can be created with `ducko account add <jid>` or in DuckoApp — the CLI and GUI share the same SwiftData database and Keychain.

## Global Options

| Option | Description |
|---|---|
| `--output plain\|ansi\|json` | Output format. Defaults to ANSI in terminal, plain when piped. |
| `--account <uuid>` | Select account by UUID. Uses first account if omitted. |

## Subcommands

Unless noted otherwise, each subcommand connects, performs its action, and disconnects.

### `send [--file <path>] [--method auto|http|jingle] <jid> [body]`

Send a message or file, then disconnect. At least one of `--file` or `body` is required. When both are provided, the file is uploaded first, then the body is sent as a separate caption message.

`--method auto` (default) picks HTTP upload; `http` forces XEP-0363; `jingle` forces XEP-0234 peer-to-peer and requires a full JID with resource.

```
ducko send alice@example.com "Hello"
ducko send --file photo.jpg alice@example.com
ducko send --file photo.jpg alice@example.com "Check this out"
ducko send --file photo.jpg --method jingle alice@example.com/resource
```

### `interactive` (default)

REPL mode. Connects once, then accepts commands on stdin:

- `send <jid> <message>` — send a message (auto-detects rooms)
- `/roster` — show contacts grouped with presence indicators
- `/status [status] [message]` — get or set presence status
- `/who` — show online contacts only
- `/history <jid> [limit]` — show message history (default 20 messages)
- `/join <room> [nickname]` — join a MUC room (sets as current room)
- `/leave [room]` — leave a MUC room (uses current room if omitted)
- `/members [room]` — show room occupants
- `/pm <nickname> <message>` — send private message to a room occupant (current room)
- `/topic [room] [text]` — view or set room topic
- `/nick <nickname>` — change nickname in current room
- `/destroy [reason]` — destroy current room (owner only)
- `/voice grant|revoke <nickname>` — grant or revoke voice (moderator only)
- `/affiliations [member|admin|owner|outcast]` — list affiliations (default: member)
- `/config` — show room configuration fields
- `/rooms [service]` — discover available rooms on MUC service
- `/sendfile [jid] <path>` — send a file (uses current room if jid omitted)
- `/accept [sid]` — accept incoming Jingle file transfer (uses latest offer if sid omitted)
- `/decline [sid]` — decline incoming Jingle file transfer (uses latest offer if sid omitted)
- `/transfers` — list active file transfers with progress
- `/add <jid> [name]` — add contact to roster
- `/remove <jid>` — remove contact from roster
- `/approve <jid>` — approve subscription request
- `/deny <jid>` — deny subscription request
- `/avatar [jid]` — view avatar info (own if no JID, contact's if given)
- `/profile` — view own vCard profile
- `/connection-info` — show TLS connection info (protocol, cipher, certificate)
- `/encrypt <jid> on|off` — toggle OMEMO encryption for a conversation
- `/pref chatstates on|off` — toggle chat state notifications (typing indicators)
- `/pref markers on|off` — toggle displayed markers (read receipts)
- `/reply <jid> <message>` — reply to last incoming message from JID
- `/retract <jid>` — retract last sent message to JID
- `/edit <jid> <new-body>` — edit last sent message to JID
- `/moderate [reason]` — moderate last message in current room (MUC moderator)
- `/search <jid> <query>` — search message history with JID
- `/directed-presence <jid>` — send directed presence to a JID
- `/check-registration [jid]` — show server registration form
- `/submit-registration [jid]` — submit registration to server/component
- `/unregister-account` — unregister account from server
- `/request-file <jid> <file>` — request a file from a peer
- `/fulfill [sid] <path>` — fulfill incoming file request
- `/add-file [sid] <path>` — add a file to an active Jingle session
- `/remove-content <sid> <cid>` — remove content from a Jingle session
- `help` — show available commands
- `quit` / `exit` — disconnect and exit

Interactive mode also prints async events as they arrive: typing indicators, delivery receipts, message corrections, Jingle transfer state changes, and MUC lifecycle events (`[new room]`, nickname changes, room destruction). Terminal bell rings on incoming messages and file transfer offers.

```
ducko interactive
```

### `history <jid>`

View message history from the local database. With `--server`, connects to fetch from the XMPP server.

| Option | Description |
|---|---|
| `--limit <n>` | Maximum number of messages (default: 20) |
| `--before <date>` | Show messages before this ISO 8601 date (pagination) |
| `--search <query>` | Filter messages by keyword (case-insensitive) |
| `--server` | Fetch from server when local history is empty (requires connection) |

```
ducko history alice@example.com
ducko history alice@example.com --limit 5
ducko history alice@example.com --before 2026-03-01T00:00:00Z
ducko history alice@example.com --output json --limit 10
ducko history alice@example.com --server
```

### `account list`

List all configured accounts. Supports `--output` format.

```
ducko account list
ducko account list --output json
```

### `account add <jid> [--password <password>] [--host <host>] [--port <port>] [--no-connect]`

Add a new XMPP account. By default it connects to verify credentials and saves the password. Password is prompted interactively if `--password` is omitted. `--host`/`--port` override the connection endpoint (a bare `--port` without `--host` is rejected). With `--no-connect` the account is persisted *without* connecting or verifying credentials — offline/manual setup; the password is still saved.

```
ducko account add alice@example.com
ducko account add alice@example.com --password secret
ducko account add alice@example.com --password secret --host 127.0.0.1 --port 5222 --no-connect
```

### `account delete <jid>`

Delete an XMPP account by JID. Disconnects if connected, removes the account from the local database, and deletes stored credentials.

```
ducko account delete alice@example.com
```

### `roster list`

List contacts grouped by roster group, with presence indicators. Waits for the initial presence sweep before displaying.

```
ducko roster list
ducko roster list --output json
ducko roster list --account <uuid>
```

Plain output shows `[+]` available, `[~]` away/xa, `[-]` dnd, `[ ]` offline. ANSI uses colored dots. JSON outputs one line per contact/group header.

### `roster add <jid> [--name <name>] [--group <group>]`

Add a contact to the roster (roster set + subscribe).

```
ducko roster add alice@example.com
ducko roster add alice@example.com --name "Alice" --group "Friends"
```

### `roster remove <jid>`

Remove a contact from the roster (roster remove).

```
ducko roster remove alice@example.com
```

### `profile`

View own vCard profile.

```
ducko profile
ducko profile --output json
```

### `presence [status] [message]`

Get or set presence status. Without arguments, shows current presence. With a status argument, sets presence.

Valid statuses: `available`, `away`, `xa`, `dnd`, `offline`.

```
ducko presence                    # show current
ducko presence away "brb"         # set away with message
ducko presence available          # set available
ducko presence --output json      # JSON output
```

### `bookmarks list`

List server-side PEP bookmarks.

```
ducko bookmarks list
ducko bookmarks list --output json
```

### `bookmarks add <jid> [--name <name>] [--nickname <nick>] [--autojoin] [--password <pw>]`

Add a bookmark for a room. Publishes to PEP with XEP-0223 persistent storage options.

```
ducko bookmarks add chat@conference.example.com --name "Main Chat" --autojoin
ducko bookmarks add chat@conference.example.com --nickname alice --autojoin
```

### `bookmarks remove <jid>`

Remove a bookmark. Retracts the PEP item.

```
ducko bookmarks remove chat@conference.example.com
```

### `avatar get <jid> [--save <path>]`

Fetch and save a contact's avatar. Tries PEP (XEP-0084) first, falls back to vCard (XEP-0054). Saves to `<jid>.png` by default.

```
ducko avatar get alice@example.com
ducko avatar get alice@example.com --save alice.jpg
```

### `avatar set <path>`

Publish own avatar from an image file (PNG recommended). Publishes via PEP and updates vCard if server lacks XEP-0398 conversion.

```
ducko avatar set photo.png
```

### `account register --server <domain> --username <user> --password <pw> [--email <email>]`

Register a new account on a server via XEP-0077 In-Band Registration. Creates the account on the remote server, then saves it locally.

```
ducko account register --server example.com --username alice --password secret
ducko account register --server example.com --username alice --password secret --email alice@mail.com
```

### `account check-registration --server <domain> [--host <host>] [--port <port>]`

Fetch and display a server's XEP-0077 registration form without registering. Useful for inspecting required fields or CAPTCHAs before calling `account register`.

```
ducko account check-registration --server example.com
```

### `account unregister <jid> [--include-history]`

Unregister an account from its server via XEP-0077 and remove it locally. With `--include-history`, also deletes stored chat transcripts for the account.

```
ducko account unregister alice@example.com
ducko account unregister alice@example.com --include-history
```

### `server-info`

Show server contact information (XEP-0157) via disco#info.

```
ducko server-info
ducko server-info --output json
```

### `room list [--service <jid>] [--search <keyword>]`

Discover available rooms on a MUC service. Auto-discovers the server's MUC service if `--service` is omitted. Use `--search` / `-q` to search via XEP-0433 Extended Channel Search.

```
ducko room list
ducko room list --service conference.example.com
ducko room list --search "test"
ducko room list -q "general"
```

### `room join <jid> [--nickname <nick>]`

Join a room and monitor incoming messages. Stays connected until `quit` or stdin EOF. Supports `send <message>` to send to the room.

```
ducko room join chat@conference.example.com
ducko room join chat@conference.example.com --nickname alice
```

### `room members <jid> [--nickname <nick>]`

Show room occupants grouped by affiliation. Joins the room temporarily to retrieve the occupant list.

```
ducko room members chat@conference.example.com
```

### `room send <jid> <body> [--nickname <nick>]`

Send a single message to a room. Joins the room, sends the message, then leaves and disconnects.

```
ducko room send chat@conference.example.com "Hello everyone"
```

### `omemo fingerprint`

Display own OMEMO device fingerprint (the local device's identity key).

```
ducko omemo fingerprint
ducko omemo fingerprint --output json
```

### `omemo devices <jid>`

List a contact's OMEMO devices with trust status.

```
ducko omemo devices alice@example.com
ducko omemo devices alice@example.com --output json
```

### `omemo trust <jid> <device-id>`

Trust an OMEMO device. Marks the device as trusted for future encrypted sessions.

```
ducko omemo trust alice@example.com 12345
```

### `omemo untrust <jid> <device-id>`

Untrust an OMEMO device. Marks the device as untrusted, preventing encrypted sessions with it.

```
ducko omemo untrust alice@example.com 12345
```

### `logs show [--lines <n>]`

Print recent entries from `~/Library/Application Support/<app-dir>/Logs/ducko.log`. Default: 50 lines.

```
ducko logs show
ducko logs show --lines 200
```

### `logs export <destination>`

Copy all log files (current + rotated archives) to a directory.

```
ducko logs export ~/Desktop/ducko-logs
```

### `logs path`

Print the absolute path to the log directory.

### `import adium [--path <dir>] [--dry-run]`

Import chat history from Adium logs. Auto-discovers Adium's default logs directory if `--path` is omitted. With `--dry-run`, scans and reports discovered accounts/contacts/files without writing transcripts.

```
ducko import adium
ducko import adium --path ~/Library/Application\ Support/Adium\ 2.0/Users/Default/Logs --dry-run
```

## Output Formats

### Plain

```
[2026-02-27T10:00:00Z] <- alice@example.com: Hello
[2026-02-27T10:00:05Z] -> alice@example.com: Hi there [delivered]
[2026-02-27T10:00:10Z] <- alice@example.com: corrected text [edited]
[2026-02-27T10:00:15Z] <- alice@example.com: Secret message [encrypted]
```

`<-` = incoming, `->` = outgoing. Markers: `[delivered]` for delivery receipts, `[edited]` for corrected messages, `[encrypted]` for OMEMO-encrypted messages, `[error: ...]` for errors.

### ANSI

Same as plain with color codes (green incoming, cyan outgoing, red errors, dim timestamps). Delivery shown as green checkmark, edited as dim `[edited]`, encrypted shown as lock icon. Default in terminal.

### JSON

```json
{"body":"Hello","direction":"incoming","from":"alice@example.com","timestamp":"2026-02-27T10:00:00Z","type":"message"}
```

Optional keys: `"delivered":"true"`, `"edited":"true"`, `"encrypted":"true"`, `"error":"..."`. Keys are sorted alphabetically.

## Examples

```bash
# Send a message (password from Keychain)
ducko send alice@example.com "Hello"

# Send with JSON output
ducko send --output json alice@example.com "Hello" | jq .

# View recent history
ducko history alice@example.com --limit 10

# Start interactive session
ducko interactive

# Use a specific account
ducko --account 12345678-1234-1234-1234-123456789abc send bob@example.com "Hey"
```

---
name: ducko-cli
description: Operate the Ducko XMPP CLI tool. Use when asked to send XMPP messages, start an interactive XMPP session, list accounts, check roster, view history, manage presence, or test the CLI. Covers running commands, authentication, output formats, and all subcommands.
---

# Ducko CLI

## Quick Start

```
ducko <subcommand> [options]
ducko --help
```

Default subcommand is `interactive` (REPL mode).

## Authentication

Password is required for all commands that connect to XMPP. Two-tier fallback (first match wins):

| Tier | Method | Usage |
|---|---|---|
| 1 | Keychain | Saved automatically on connect in DuckoApp |
| 2 | Interactive prompt | Reads from `/dev/tty` when stdin is a TTY |

Accounts can be created via `ducko account add <jid>` or in DuckoApp (GUI). The CLI shares the same SwiftData database and macOS Keychain.

## Global Options

| Option | Description |
|---|---|
| `--output plain\|ansi\|json` | Output format. Defaults to ANSI in terminal, plain when piped. |
| `--account <uuid>` | Select account by UUID. Uses first account if omitted. |

## Subcommands

### `send <jid> <body>`

Send a one-off message, then disconnect.

```
ducko send alice@example.com "Hello"
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
- `/topic [room] [text]` — view or set room topic
- `/rooms [service]` — discover available rooms on MUC service
- `/approve <jid>` — approve subscription request
- `/deny <jid>` — deny subscription request
- `help` — show available commands
- `quit` / `exit` — disconnect and exit

Real-time indicators in interactive mode:
- Typing indicators from contacts are displayed as they arrive
- Delivery receipts and message corrections appear in the event stream
- Terminal bell rings on incoming messages and room messages

```
ducko interactive
```

### `history <jid>`

View message history for a conversation. Connects, fetches messages, then disconnects.

| Option | Description |
|---|---|
| `--limit <n>` | Maximum number of messages (default: 20) |
| `--before <date>` | Show messages before this ISO 8601 date (pagination) |

```
ducko history alice@example.com
ducko history alice@example.com --limit 5
ducko history alice@example.com --before 2026-03-01T00:00:00Z
ducko history alice@example.com --output json --limit 10
```

### `account list`

List all configured accounts. Supports `--output` format.

```
ducko account list
ducko account list --output json
```

### `account add <jid>`

Add a new XMPP account. Prompts for password, connects to verify credentials, saves password to Keychain, then disconnects.

```
ducko account add alice@example.com
```

### `roster list`

List contacts grouped by roster group, with presence indicators. Connects, waits for roster and initial presence, then displays.

```
ducko roster list
ducko roster list --output json
ducko roster list --account <uuid>
```

Plain output shows `[+]` available, `[~]` away/xa, `[-]` dnd, `[ ]` offline. ANSI uses colored dots. JSON outputs one line per contact/group header.

### `presence [status] [message]`

Get or set presence status. Without arguments, shows current presence. With a status argument, sets presence.

Valid statuses: `available`, `away`, `xa`, `dnd`, `offline`.

```
ducko presence                    # show current
ducko presence away "brb"         # set away with message
ducko presence available          # set available
ducko presence --output json      # JSON output
```

### `room list [--service <jid>]`

Discover available rooms on a MUC service. Auto-discovers the server's MUC service if `--service` is omitted.

```
ducko room list
ducko room list --service conference.example.com
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

### Stubs (not yet implemented)

| Subcommand | Description |
|---|---|
| `account delete <jid>` | Delete an account |

## Output Formats

### Plain

```
[2026-02-27T10:00:00Z] <- alice@example.com: Hello
[2026-02-27T10:00:05Z] -> alice@example.com: Hi there [delivered]
[2026-02-27T10:00:10Z] <- alice@example.com: corrected text [edited]
```

`<-` = incoming, `->` = outgoing. Markers: `[delivered]` for delivery receipts, `[edited]` for corrected messages, `[error: ...]` for errors.

### ANSI

Same as plain with color codes (green incoming, cyan outgoing, red errors, dim timestamps). Delivery shown as green checkmark, edited as dim `[edited]`. Default in terminal.

### JSON

```json
{"body":"Hello","direction":"incoming","from":"alice@example.com","timestamp":"2026-02-27T10:00:00Z","type":"message"}
```

Optional keys: `"delivered":"true"`, `"edited":"true"`, `"error":"..."`. Keys are sorted alphabetically. Use `--output json` when piping to `jq` or processing programmatically.

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

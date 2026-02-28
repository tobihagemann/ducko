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

- `send <jid> <message>` — send a message
- `/roster` — show contacts grouped with presence indicators
- `/status [status] [message]` — get or set presence status
- `/who` — show online contacts only
- `help` — show available commands
- `quit` / `exit` — disconnect and exit

```
ducko interactive
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

### Stubs (not yet implemented)

| Subcommand | Description |
|---|---|
| `history <jid>` | View message history |
| `room join <jid>` | Join a MUC room |
| `room leave <jid>` | Leave a MUC room |
| `room list` | List joined rooms |
| `account delete <jid>` | Delete an account |

## Output Formats

### Plain

```
[2026-02-27T10:00:00Z] <- alice@example.com: Hello
[2026-02-27T10:00:05Z] -> alice@example.com: Hi there
```

`<-` = incoming, `->` = outgoing.

### ANSI

Same as plain with color codes (green incoming, cyan outgoing, red errors). Default in terminal.

### JSON

```json
{"body":"Hello","direction":"incoming","from":"alice@example.com","timestamp":"2026-02-27T10:00:00Z","type":"message"}
```

Keys are sorted alphabetically. Use `--output json` when piping to `jq` or processing programmatically.

## Examples

```bash
# Send a message (password from Keychain)
ducko send alice@example.com "Hello"

# Send with JSON output
ducko send --output json alice@example.com "Hello" | jq .

# Start interactive session
ducko interactive

# Use a specific account
ducko --account 12345678-1234-1234-1234-123456789abc send bob@example.com "Hey"
```

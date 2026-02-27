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

Password is required for all commands that connect to XMPP.

| Method | Usage |
|---|---|
| Environment variable | `DUCKO_PASSWORD=secret ducko send ...` |
| Interactive prompt | Reads from `/dev/tty` when stdin is a TTY |

Accounts are created in DuckoApp (GUI). The CLI shares the same SwiftData database.

## Global Options

| Option | Description |
|---|---|
| `--output plain\|ansi\|json` | Output format. Defaults to ANSI in terminal, plain when piped. |
| `--account <uuid>` | Select account by UUID. Uses first account if omitted. |

## Subcommands

### `send <jid> <body>`

Send a one-off message, then disconnect.

```
DUCKO_PASSWORD=secret ducko send alice@example.com "Hello"
```

### `interactive` (default)

REPL mode. Connects once, then accepts commands on stdin:

- `send <jid> <message>` — send a message
- `help` — show available commands
- `quit` / `exit` — disconnect and exit

```
DUCKO_PASSWORD=secret ducko interactive
```

### Stubs (not yet implemented)

| Subcommand | Description |
|---|---|
| `roster list` | List contacts |
| `presence` | Get or set presence status |
| `history <jid>` | View message history |
| `room join <jid>` | Join a MUC room |
| `room leave <jid>` | Leave a MUC room |
| `room list` | List joined rooms |
| `account list` | List configured accounts |

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
# Send a message
DUCKO_PASSWORD=secret ducko send alice@example.com "Hello"

# Send with JSON output
DUCKO_PASSWORD=secret ducko send --output json alice@example.com "Hello" | jq .

# Start interactive session
DUCKO_PASSWORD=secret ducko interactive

# Use a specific account
DUCKO_PASSWORD=secret ducko --account 12345678-1234-1234-1234-123456789abc send bob@example.com "Hey"
```

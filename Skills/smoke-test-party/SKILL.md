---
name: smoke-test-party
description: "Multi-account CLI smoke test using an agent team. Each XMPP test account gets its own agent that runs CLI commands via DUCKO_PROFILE isolation. Use when asked to \"smoke test party\", \"multi-account smoke test\", \"test with alice and bob\", or \"team smoke test\"."
---

# Smoke Test Party

Multi-account smoke test using an agent team. Each XMPP account runs as a separate agent via `DUCKO_PROFILE` isolation.

## Step 1: Run `/smoke-test` and `/ducko-cli`

Run the `/smoke-test` skill first. Use its output to determine scope, approach, and baseline test results for a single account. Then run `/ducko-cli` to load the CLI command reference.

If `/smoke-test` reveals build failures or fundamental issues, stop — fix those first.

## Step 2: Determine Accounts

Identify available XMPP test accounts. Check auto memory for stored credentials, or ask the user. Each account needs a JID, password, and a `DUCKO_PROFILE` name for storage isolation.

The team lead uses the default profile (no env prefix). Each teammate gets a named profile:

| Agent | Profile Env |
|-------|-------------|
| team-lead (you) | *(default, no prefix)* |
| teammate-1 | `DUCKO_PROFILE=<name>` |
| teammate-2 | `DUCKO_PROFILE=<name>` |

Verify each profile has an account configured via `[DUCKO_PROFILE=<name>] .build/debug/DuckoCLI account list`. If not, add accounts with `account add <jid> --password <pw>`.

## Step 3: Create Team and Tasks

Use `TeamCreate` to create a team (e.g., `smoke-party`). Design test phases based on the `/smoke-test` results and cross-account interaction opportunities:

- **Setup phase** — each account verifies identity, sets presence
- **Cross-account phases** — roster management, direct messaging, MUC rooms, etc.
- **Advanced features** — bookmarks, OMEMO, server-info, history
- **Cleanup phase** — remove test roster entries, reset presence

Create tasks with `TaskCreate` and set up dependencies with `TaskUpdate` so phases run in order.

## Step 4: Spawn Teammates

Spawn agents with the Agent tool using `team_name` and `mode: "bypassPermissions"`. Each agent's prompt must include:

1. Instruction to run `/ducko-cli` to load the CLI command reference
2. Their account identity and `DUCKO_PROFILE` prefix
3. `dangerouslyDisableSandbox: true` for all Bash commands (raw TCP/DNS needed)
4. CoreData noise filter: `2>&1 | grep -v "^CoreData:"`
5. Workflow: check TaskList → claim tasks → execute → report → check TaskList
6. Use `room send` not `room join` (which blocks)

## Step 5: Coordinate

As team lead, run your own account's commands directly while teammates work in parallel. For each phase:

1. Run your part of the phase
2. Wait for teammate reports
3. Mark phase task as completed to unblock the next phase
4. Send messages to teammates to notify them of unblocked tasks
5. Nudge idle teammates if they don't pick up tasks

## Step 6: Report and Shutdown

After all phases complete:

1. Compile results from all accounts into a summary table
2. Note any cross-account observations (message delivery, subscription requests, etc.)
3. Send shutdown requests to all teammates
4. Present the final report

## Rules

- Never modify code. Read-only verification.
- All network CLI commands need `dangerouslyDisableSandbox: true` (sandbox blocks raw TCP/DNS).
- Always clean up: remove roster entries and reset presence in the final phase.
- If a teammate goes idle, nudge them with a direct `SendMessage` — they may need explicit task instructions.
- If a teammate fails to respond after two nudges, continue with remaining agents and note the gap in the report.

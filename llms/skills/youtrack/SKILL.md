---
name: youtrack
description: Work with YouTrack beyond what the MCP server covers — Agile Boards and sprint membership, large comments, file attachments, and raw REST calls. Use alongside the YouTrack MCP tools, which remain the default for creating, updating, searching, reading and linking issues.
---

# YouTrack

Two tools, one instance. Pick by the job.

**Use the YouTrack MCP tools for** projects, issue field schemas, creating and updating issues, searching, reading, and linking. They are typed, they validate, and they are the default.

**Use `scripts/youtrack.sh` for** the things MCP does not do or does badly:

| Job | Why not MCP |
|---|---|
| Agile Boards, sprint membership | No MCP tool exposes them |
| Comments over a few kilobytes | `add_issue_comment` times out and can post nothing |
| File attachments | No MCP endpoint exists at all |
| Any other REST endpoint | Commands API, batch operations, deletes |

Do not rebuild issue creation, search or linking in the script. Two ways to do one thing is how they drift apart.

## Commands

```text
youtrack.sh boards [--project KEY] [--name TEXT] [--json]
youtrack.sh sprints --board NAME_OR_ID [--name TEXT] [--include-archived] [--json]
youtrack.sh add --board NAME_OR_ID --sprint NAME_OR_ID [--dry-run] ISSUE_ID...
youtrack.sh comment ISSUE_ID (--file PATH | --stdin | --text TEXT)
youtrack.sh attach ISSUE_ID --file PATH
youtrack.sh api METHOD PATH [--data-file PATH | --data-stdin | --data JSON]
```

Names first match case-insensitively and exactly, then by substring. IDs such as `147-6` and `148-62` match directly. The script stops on a missing or ambiguous board or sprint name, and refuses issues whose project is not attached to the board.

## Typical use

Find the board and sprint, create the issue through MCP, then add it:

```bash
scripts/youtrack.sh boards --project ARTC
scripts/youtrack.sh sprints --board 147-6
scripts/youtrack.sh add --board 147-6 --sprint "Sprint 24" ARTC-1234
```

Re-running `add` reports `ALREADY` instead of duplicating the card. Use `--dry-run` first in an unfamiliar instance.

Post a long document without it passing through the model's context:

```bash
scripts/youtrack.sh comment ARTC-1234 --file docs/plans/design.md
git log --oneline -20 | scripts/youtrack.sh comment ARTC-1234 --stdin
```

Attach the file itself, rather than pasting its text:

```bash
scripts/youtrack.sh attach ARTC-1234 --file docs/plans/design.md
```

Reach an endpoint with no wrapper:

```bash
scripts/youtrack.sh api GET '/api/issues/ARTC-1234?fields=id,summary,description'
scripts/youtrack.sh api POST /api/issues/ARTC-1234 --data '{"description":"new text"}'
scripts/youtrack.sh api DELETE /api/issues/ARTC-1234/comments/4-979
```

`api` sends the body only when you pass one, checks that it parses as JSON first, and requires the path to start with a slash.

## Comment or attachment

Attach a file when it is a document: a plan, a dump, a screenshot, a CSV, test output. It stays downloadable with its formatting intact and does not stretch the comment thread.

Comment when the content is discussion, or when it should be readable inline without a download. A long plan usually wants both: a short comment saying what it is, and the file attached.

## Authentication and safety

- The script reads `YOUTRACK_BASE_URL` (the instance origin) and `YOUTRACK_AUTHORIZATION` (the full header value, for example `Bearer <token>`) from the environment, and errors if either is empty.
- Run `scripts/setup.sh` once. It creates `~/.config/llm-skills/youtrack-agile.env` and sources it from your shell profile. Then edit that file and replace the token placeholder. Re-running is safe.
- **The token never becomes a command argument.** The script writes the Authorization header into a private curl config file with 600 permissions and removes it on exit, so the token does not appear in the process list.
- Keep the token out of this skill and out of any repository. Never read or print that env file, never enable shell tracing, never use verbose curl output.
- `--file` and `--stdin` stream the payload from disk to curl. Large content never becomes an argument, and it never has to pass through the model's context.
- Network sandbox approval may be required for direct REST calls.

## Destructive calls

`api` will happily send DELETE and PUT. It has no confirmation step. Check the issue id and the path before running one, and prefer a GET first to confirm the target exists and is what you expect.

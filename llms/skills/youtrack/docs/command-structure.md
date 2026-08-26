# YouTrack command structure

## Purpose

The helper will use a resource-first command structure.
This structure will make command names predictable as the helper grows.

Use this pattern:

```text
youtrack.sh RESOURCE [SUBRESOURCE] OPERATION [IDENTIFIERS] [OPTIONS]
```

Put the operation after the resource.
Use one subresource when it belongs to the first resource.
Do not copy every level from a REST path.
Use options when another resource only supplies context.

## Resource names

Use plural resource names.
Use the same name for the same resource in all commands.

Examples include `issues`, `comments`, `attachments`, `projects`, `boards`, and `sprints`.

## Operations

Use each operation with one meaning.

| Operation | Meaning |
| --- | --- |
| `get` | Return one identified resource. |
| `list` | Return a collection under a known resource. |
| `search` | Run a YouTrack query. |
| `create` | Create a new resource. |
| `update` | Change an existing resource. |
| `delete` | Delete an existing resource. |
| `add` | Add an existing resource to a collection. |
| `remove` | Remove an existing resource from a collection. |

A `get` command requires the resource identifier.
A `list` command does not imply one result.

## Examples

```bash
youtrack.sh issues get ARTC-1478
youtrack.sh issues search --query 'project: ARTC State: Open'
youtrack.sh issues create --project ARTC --summary 'Example'
youtrack.sh issues update ARTC-1478 --state 'In Progress'

youtrack.sh issues comments list ARTC-1478
youtrack.sh issues comments get ARTC-1478 COMMENT_ID
youtrack.sh issues comments create ARTC-1478 --file notes.md

youtrack.sh issues attachments create ARTC-1478 --file report.csv
youtrack.sh issues links create ARTC-1478 ARTC-1200 --type 'depends on'

youtrack.sh sprints issues add --board 147-6 --sprint 148-61 ARTC-1478
```

## Output

Commands will print concise text by default.
Commands will accept `--json` when structured output is useful.
JSON output will have a stable documented shape.

A collection command will fetch all pages by default.
The command will buffer pages before it prints output.
An API failure will not produce a successful partial result.

Large write payloads will use `--file` or `--stdin`.
This rule keeps large content out of process arguments.

## Errors

Invalid command structures will fail before an API request.
Missing identifiers and unknown options will produce specific errors.
API failures will return a nonzero status.
Commands will not hide malformed YouTrack responses.

## Raw API access

The `api` command will remain an escape path for unsupported endpoints.
A repeated raw API workflow should become a native command.
Native commands will provide validation, pagination, and stable output.

## Command changes

New command groups will be additive during the first implementation work.
Existing commands will keep their current behavior until their replacements exist.

Do not add a compatibility alias without a known external caller.
An alias accepts an old command form and forwards it to the new handler.
Aliases add parser paths, tests, documentation, and removal work.

When no external caller exists, update the helper and its skill documentation together.
Remove the old command form in that same change.
